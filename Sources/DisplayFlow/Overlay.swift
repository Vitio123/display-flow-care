import AppKit
import Combine

// MARK: - Private CGS API: pin a window to every Space, including full-screen
//
// `NSWindow.collectionBehavior` (`.canJoinAllSpaces`,
// `.canJoinAllApplications`) is supposed to handle this case but on macOS
// 13–15 it doesn't reliably attach to full-screen Spaces created by *other*
// applications. The private CGSAddWindowsToSpaces call is the well-known
// workaround — same one used by Bartender, MeetingBar, etc. — and is stable
// across recent macOS versions. We only use it for app-internal layout, no
// App Store concern.

@_silgen_name("CGSMainConnectionID")
fileprivate func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopySpaces")
fileprivate func CGSCopySpaces(_ cid: Int32, _ mask: Int) -> Unmanaged<CFArray>?

@_silgen_name("CGSAddWindowsToSpaces")
fileprivate func CGSAddWindowsToSpaces(_ cid: Int32, _ wids: CFArray, _ sids: CFArray)

/// Mask 7 = current + others + user — covers every Space type including the
/// dedicated full-screen ones. (Bits: 1=current, 2=others, 4=user.)
fileprivate let CGSAllSpacesMask = 7

fileprivate func pinWindowToAllSpaces(_ window: NSWindow) {
    guard window.windowNumber > 0 else { return }
    let cid = CGSMainConnectionID()
    guard let spacesRef = CGSCopySpaces(cid, CGSAllSpacesMask) else { return }
    let spaces = spacesRef.takeRetainedValue()
    let wids = [CGWindowID(window.windowNumber)] as CFArray
    CGSAddWindowsToSpaces(cid, wids, spaces)
}

// MARK: - One overlay per protected screen

final class OverlayWindow {
    let window: NSWindow
    let displayID: CGDirectDisplayID
    let screenRef: NSScreen
    /// Slightly larger than `screen.frame` so a small pixel-shift offset
    /// doesn't expose the screen edge.
    let baseFrame: NSRect
    private var pendingShow: DispatchWorkItem?
    /// Desired visibility (intent), set immediately when caller asks. Used
    /// instead of `alphaValue` to drive scheduling, because `alphaValue`
    /// lags behind during the fade animation.
    private(set) var isVisible: Bool = false
    var hasPendingShow: Bool { pendingShow != nil }

    init(screen: NSScreen, style: DimStyle) {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        self.displayID = (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
        self.screenRef = screen
        self.baseFrame = screen.frame.insetBy(dx: -4, dy: -4)

        let view: NSView
        switch style {
        case .blur:
            let v = NSVisualEffectView(frame: NSRect(origin: .zero, size: baseFrame.size))
            v.material = .fullScreenUI
            v.blendingMode = .behindWindow
            v.state = .active
            view = v
        case .black, .white:
            let v = NSView(frame: NSRect(origin: .zero, size: baseFrame.size))
            v.wantsLayer = true
            v.layer?.backgroundColor = (style == .white ? NSColor.white : NSColor.black).cgColor
            view = v
        }

        let w = NSWindow(contentRect: baseFrame,
                         styleMask: .borderless,
                         backing: .buffered,
                         defer: false,
                         screen: screen)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .stationary, .ignoresCycle]
        w.contentView = view
        w.alphaValue = 0
        w.orderFrontRegardless()
        // Force the window into every existing Space — public collection
        // behavior alone misses other apps' full-screen Spaces.
        pinWindowToAllSpaces(w)
        self.window = w
    }

    var alphaValue: CGFloat { window.alphaValue }

    func close() { window.orderOut(nil) }

    /// Apply a (dx, dy) pixel offset relative to the inflated base frame.
    /// Keeps the overlay covering the full screen because base is 4px larger.
    func applyOffset(_ offset: CGSize) {
        var f = baseFrame
        f.origin.x += offset.width
        f.origin.y += offset.height
        window.setFrame(f, display: false)
    }

    func setVisible(_ visible: Bool, opacity: CGFloat, duration: Double) {
        pendingShow?.cancel(); pendingShow = nil
        let wasVisible = isVisible
        isVisible = visible
        // Becoming visible: re-attach to whatever Space is currently shown
        // on this display. Required for full-screen Spaces — even with
        // `.canJoinAllApplications`, the system sometimes leaves the window
        // bound to the previous Space until we kick it.
        if visible && !wasVisible {
            window.orderFrontRegardless()
        }
        let target: CGFloat = visible ? opacity : 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = target
        }
    }

    /// Schedule a deferred show after `delay` seconds. If a show is already
    /// pending, this is a no-op — that's what makes the leave-delay actually
    /// stick when `tick()` runs at 30 Hz.
    func scheduleShow(after delay: TimeInterval,
                      opacity: CGFloat,
                      duration: Double,
                      condition: @escaping () -> Bool) {
        guard pendingShow == nil else { return }
        if delay <= 0 {
            if condition() {
                setVisible(true, opacity: opacity, duration: duration)
            }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingShow = nil
            if condition() {
                self.setVisible(true, opacity: opacity, duration: duration)
            }
        }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancelPending() {
        pendingShow?.cancel()
        pendingShow = nil
    }
}

// MARK: - Menu-bar cover

/// A short opaque strip pinned to the very top of a protected display, sized
/// to the actual menu bar height. Hides the macOS menu bar to prevent icon
/// burn-in on OLED, and gracefully fades when the cursor moves into the top
/// strip so the user can still use the menus.
final class TopBarWindow {
    let window: NSWindow
    let displayID: CGDirectDisplayID
    let screenRef: NSScreen

    /// Height of the menu bar strip on this display.
    let height: CGFloat
    /// Inflated frame so a small pixel-shift offset never exposes the menu
    /// bar at the edges.
    let baseFrame: NSRect
    /// Track desired visibility so tick() can skip redundant animation
    /// requests instead of re-running NSAnimationContext every frame.
    private(set) var isVisible: Bool = false

    init(screen: NSScreen, style: DimStyle) {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        self.displayID = (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
        self.screenRef = screen

        // Computed per display so notched / scaled displays stay accurate.
        let measured = screen.frame.maxY - screen.visibleFrame.maxY
        let h = max(28, measured + 2)
        self.height = h

        // Inflate horizontally and vertically so ±1px shifts never reveal
        // the menu bar pixels at the borders. We extend up (off-screen, gets
        // clipped) and down (covers a hair more user content).
        let frame = NSRect(x: screen.frame.minX - 4,
                           y: screen.frame.maxY - h - 4,
                           width: screen.frame.width + 8,
                           height: h + 8)
        self.baseFrame = frame
        let view: NSView
        switch style {
        case .blur:
            let v = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
            v.material = .fullScreenUI
            v.blendingMode = .behindWindow
            v.state = .active
            view = v
        case .black, .white:
            let v = NSView(frame: NSRect(origin: .zero, size: frame.size))
            v.wantsLayer = true
            v.layer?.backgroundColor = (style == .white ? NSColor.white : NSColor.black).cgColor
            view = v
        }

        let w = NSWindow(contentRect: frame,
                         styleMask: .borderless,
                         backing: .buffered,
                         defer: false,
                         screen: screen)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .stationary, .ignoresCycle]
        w.contentView = view
        w.alphaValue = 0
        w.orderFrontRegardless()
        pinWindowToAllSpaces(w)
        self.window = w
    }

    var alphaValue: CGFloat { window.alphaValue }

    func close() { window.orderOut(nil) }

    func applyOffset(_ offset: CGSize) {
        var f = baseFrame
        f.origin.x += offset.width
        f.origin.y += offset.height
        window.setFrame(f, display: false)
    }

    func setVisible(_ visible: Bool, opacity: CGFloat = 1.0, duration: Double) {
        // Idempotent — same desired state, don't kick off another animation.
        if visible == isVisible { return }
        isVisible = visible
        let target: CGFloat = visible ? opacity : 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = target
        }
    }
}

// MARK: - Reasons the overlay is showing (single source of truth for the UI)

enum OverlayState: Equatable {
    case disabled                   // master switch off
    case hibernating                // battery saver / no external — fully paused
    case noDisplays                 // no protected displays selected
    case manualRest                 // user pressed Rest Now
    case scheduled                  // schedule window active
    case mediaPaused                // video / call playing → overlay hidden
    case idleBlackout               // system idle → overlay forced
    case active(protectedCount: Int)
}

/// Why the controller is currently hibernating, so the UI can explain itself.
enum HibernationReason: String {
    case noExternalDisplay
    case manualBatterySaver
    case lowBattery
}

// MARK: - Controller

final class OverlayController: ObservableObject {
    let mediaWatcher = MediaWatcher()
    let powerWatcher = PowerWatcher()

    private var overlays: [OverlayWindow] = []
    private var topBars: [TopBarWindow] = []
    private var timer: Timer?
    private let settings = Settings.shared
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var protectionObserver: NSObjectProtocol?

    @Published private(set) var protectedCount: Int = 0
    @Published private(set) var state: OverlayState = .active(protectedCount: 0)

    /// True while we've stopped all polling and torn down windows because
    /// there's no external display to protect — nothing useful to do, may as
    /// well consume zero. Battery-saver toggles drive `lowPower` instead so
    /// the app keeps working, just lighter.
    @Published private(set) var hibernating: Bool = false
    @Published private(set) var hibernationReason: HibernationReason = .noExternalDisplay

    /// Lightweight mode: tick + polls run at a slower cadence and pixel-shift
    /// is paused, but cursor follow and media detection still work. Driven by
    /// the Battery saver toggle and (optionally) the auto-pause-when-low rule.
    @Published private(set) var lowPower: Bool = false

    /// Stat accrual: only commit to UserDefaults every ~5s to avoid churn,
    /// and use real elapsed time so the count is correct regardless of the
    /// timer's tick rate.
    private var unsavedSeconds: Double = 0
    private var lastSaved: Date = .distantPast
    private var lastAccrualAt: Date = Date()

    // Pixel-shift cycle. Walks a 3×3 neighborhood around (0,0) so the overlay
    // boundary lands on slightly different physical pixels each minute.
    private let shiftPattern: [CGSize] = [
        .init(width:  0, height:  0),
        .init(width:  1, height:  0),
        .init(width:  1, height:  1),
        .init(width:  0, height:  1),
        .init(width: -1, height:  1),
        .init(width: -1, height:  0),
        .init(width: -1, height: -1),
        .init(width:  0, height: -1),
        .init(width:  1, height: -1),
    ]
    private var shiftIndex: Int = 0
    private var lastShiftAt: Date = .distantPast
    private let shiftIntervalSeconds: TimeInterval = 60

    // Wake-from-sleep handler. Timers can be paused during system sleep, and
    // various subsystems (CGWindowList, IOPM) need a kick to refresh.
    private var wakeObserver: NSObjectProtocol?

    // Active-space-change observer. Fires when the user switches Spaces or
    // enters/leaves a full-screen app. Even with `.canJoinAllSpaces +
    // .fullScreenAuxiliary` collection behavior, the first transition into a
    // full-screen Space sometimes drops our overlay; re-asserting it with
    // `orderFrontRegardless` forces it back on top.
    private var spaceObserver: NSObjectProtocol?

    init() {
        powerWatcher.start()
        // Decide hibernation up front so we don't spin up everything just to
        // tear it down on the first tick.
        if computeShouldHibernate() {
            hibernating = true
            hibernationReason = computeHibernationReason()
            updateState(.hibernating)
        } else {
            mediaWatcher.start()
            rebuild()
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.rebuild() }

        protectionObserver = NotificationCenter.default.addObserver(
            forName: .protectionChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuild() }

        // Wake-from-sleep: kick the timers and force a state refresh.
        // System sleep pauses our timer and the occlusion / power info, so
        // without this the app ends up "stuck" until the user clicks around.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleWake()
        }

        // Re-assert window order when the active Space changes — covers
        // entering / leaving full-screen apps so the overlay still draws
        // over them on the OLED.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.reorderOverlays()
        }

        // Rebuild overlays on style change (NSVisualEffectView vs solid).
        settings.$style
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)

        // Recreate top bars when the toggle flips.
        settings.$hideTopBar
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)

        // Reset offsets when pixel shift is toggled off.
        settings.$pixelShift
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self = self else { return }
                if !enabled {
                    self.shiftIndex = 0
                    self.applyShift(.zero)
                }
            }
            .store(in: &cancellables)

        // Re-evaluate hibernation when battery / display / settings shift.
        Publishers.CombineLatest3(
            powerWatcher.$batteryPercent,
            powerWatcher.$isOnBattery,
            powerWatcher.$hasExternalDisplay
        )
        .dropFirst()
        .sink { [weak self] _, _, _ in self?.evaluateHibernation() }
        .store(in: &cancellables)

        settings.$batterySaverMode
            .dropFirst()
            .sink { [weak self] _ in self?.evaluateHibernation() }
            .store(in: &cancellables)

        settings.$autoBatterySaverWhenLow
            .dropFirst()
            .sink { [weak self] _ in self?.evaluateHibernation() }
            .store(in: &cancellables)

        if !hibernating {
            evaluateLowPower()  // applies poll intervals if user already has it on
            startTickTimer()
        }
    }

    private func startTickTimer() {
        timer?.invalidate()
        // Normal: 15 Hz (~67ms cursor-crossing latency, imperceptible).
        // Low-power: 5 Hz (~200ms latency, still fine for cursor follow).
        // Animations are GPU-driven by CoreAnimation either way.
        let rate = lowPower ? 1.0/5.0 : 1.0/15.0
        timer = Timer.scheduledTimer(withTimeInterval: rate, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func rebuild() {
        overlays.forEach { $0.close() }
        topBars.forEach { $0.close() }
        overlays.removeAll()
        topBars.removeAll()

        // While hibernating we don't recreate any windows.
        if hibernating {
            protectedCount = 0
            return
        }

        let protectedScreens: [NSScreen] = NSScreen.screens.filter { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            let did = (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
            return settings.isProtected(did)
        }
        overlays = protectedScreens.map { OverlayWindow(screen: $0, style: settings.style) }
        topBars  = settings.hideTopBar
            ? protectedScreens.map { TopBarWindow(screen: $0, style: settings.style) }
            : []
        protectedCount = overlays.count
        // Re-apply current shift so freshly created windows don't snap back to (0,0).
        applyShift(shiftPattern[shiftIndex])
    }

    // MARK: - Hibernation & low-power mode

    /// Hibernation = full pause. Reserved for "no external display" — there's
    /// literally nothing to protect, so we close everything and stop polling.
    private func computeShouldHibernate() -> Bool {
        return !powerWatcher.hasExternalDisplay
    }

    private func computeHibernationReason() -> HibernationReason {
        return .noExternalDisplay
    }

    /// Low-power = lighter cadence, but everything still works.
    private func computeShouldLowPower() -> Bool {
        if settings.batterySaverMode { return true }
        if settings.autoBatterySaverWhenLow
            && powerWatcher.isOnBattery
            && powerWatcher.batteryPercent < 50 { return true }
        return false
    }

    private func evaluateHibernation() {
        let should = computeShouldHibernate()
        if should && !hibernating { enterHibernation() }
        else if !should && hibernating { exitHibernation() }
        // Re-evaluate low-power even when hibernation didn't change.
        evaluateLowPower()
    }

    private func evaluateLowPower() {
        let want = !hibernating && computeShouldLowPower()
        if want != lowPower {
            lowPower = want
            mediaWatcher.setPollInterval(want ? 4.0 : 2.0)
            powerWatcher.setPollInterval(want ? 60.0 : 30.0)
            startTickTimer()
        }
    }

    private func enterHibernation() {
        hibernating = true
        hibernationReason = computeHibernationReason()
        timer?.invalidate(); timer = nil
        mediaWatcher.stop()
        overlays.forEach { $0.cancelPending(); $0.close() }
        topBars.forEach { $0.close() }
        overlays.removeAll()
        topBars.removeAll()
        protectedCount = 0
        updateState(.hibernating)
    }

    private func exitHibernation() {
        hibernating = false
        rebuild()
        mediaWatcher.start()
        startTickTimer()
    }

    /// macOS wakes from sleep. Timers may have stalled and our windows could
    /// be in a weird state — refresh everything proactively.
    private func handleWake() {
        powerWatcher.pollNow()
        if hibernating {
            evaluateHibernation()
            return
        }
        // Make sure the per-display windows still match the current screen
        // setup (display reconnection during sleep is a thing) and restart
        // the polls — they're cheap and resilient to redundant calls.
        rebuild()
        mediaWatcher.start()
        startTickTimer()
        reorderOverlays()
    }

    /// Re-pin all overlay + top-bar windows to every Space. Called whenever
    /// the Space layout might have changed — entering / leaving full-screen,
    /// adding a Desktop, waking from sleep — so a brand-new Space (e.g. the
    /// one a freshly-fullscreened app just created) gets our windows too.
    private func reorderOverlays() {
        for w in overlays {
            pinWindowToAllSpaces(w.window)
            w.window.orderFrontRegardless()
        }
        for b in topBars {
            pinWindowToAllSpaces(b.window)
            b.window.orderFrontRegardless()
        }
    }

    /// Apply a pixel offset to all overlay and top-bar windows.
    private func applyShift(_ offset: CGSize) {
        overlays.forEach { $0.applyOffset(offset) }
        topBars.forEach  { $0.applyOffset(offset) }
    }

    /// Advance the pixel-shift cycle if enough time has elapsed.
    private func pixelShiftTick() {
        guard settings.pixelShift else { return }
        let now = Date()
        if now.timeIntervalSince(lastShiftAt) < shiftIntervalSeconds { return }
        lastShiftAt = now
        shiftIndex = (shiftIndex + 1) % shiftPattern.count
        applyShift(shiftPattern[shiftIndex])
    }

    private func isCursorInTopStrip(displayID: CGDirectDisplayID) -> Bool {
        guard let bar = topBars.first(where: { $0.displayID == displayID }) else { return false }
        let m = NSEvent.mouseLocation
        let frame = bar.screenRef.frame
        guard NSMouseInRect(m, frame, false) else { return false }
        // Trigger zone is a touch larger than the bar so the reveal feels
        // generous — once the cursor is within ~2× the bar height of the top.
        return m.y > frame.maxY - max(50, bar.height * 1.5)
    }

    private func showTopBars(forceHidden: Set<CGDirectDisplayID> = []) {
        guard !topBars.isEmpty else { return }
        let cursorID = cursorDisplayID()
        for bar in topBars {
            if forceHidden.contains(bar.displayID) {
                // Video is playing on this display — let the user see the
                // menu bar so they can interact normally.
                bar.setVisible(false, duration: 0.25)
                continue
            }
            let revealing = (bar.displayID == cursorID) && isCursorInTopStrip(displayID: bar.displayID)
            bar.setVisible(!revealing, duration: revealing ? 0.10 : 0.25)
        }
    }

    private func hideTopBars(duration: Double = 0.25) {
        topBars.forEach { $0.setVisible(false, duration: duration) }
    }

    private func cursorDisplayID() -> CGDirectDisplayID? {
        let m = NSEvent.mouseLocation
        guard let s = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) else {
            return nil
        }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (s.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    private func showAll(opacity: CGFloat, duration: Double) {
        overlays.forEach { $0.setVisible(true, opacity: opacity, duration: duration) }
    }
    private func hideAll(duration: Double) {
        overlays.forEach { $0.setVisible(false, opacity: 0, duration: duration) }
    }

    private func updateState(_ new: OverlayState) {
        if state != new { state = new }
    }

    private func tick() {
        if hibernating { return }
        if !lowPower { pixelShiftTick() }   // skip pixel shift in low-power mode

        let s = settings
        let opacity = CGFloat(s.opacity)
        let dur = s.fadeDuration

        // Precedence:
        //  1. master off
        //  2. no protected displays
        //  3. manual rest                (user explicit)
        //  4. schedule window active     (user explicit)
        //  5. media playing pause        (don't dim while watching)
        //  6. idle blackout
        //  7. cursor follow

        guard s.enabled else {
            hideAll(duration: dur)
            hideTopBars()
            updateState(.disabled)
            return
        }
        if overlays.isEmpty {
            hideTopBars()
            updateState(.noDisplays)
            return
        }
        if s.manualRest {
            showAll(opacity: opacity, duration: dur)
            showTopBars()
            accrueProtectedTime()
            updateState(.manualRest)
            return
        }
        if s.scheduleEnabled && s.isInScheduleWindow() {
            showAll(opacity: opacity, duration: dur)
            showTopBars()
            accrueProtectedTime()
            updateState(.scheduled)
            return
        }
        // Idle blackout — but only if nothing is playing. HIDIdleTime measures
        // seconds since the last keyboard/mouse input, so watching a video for
        // 5 minutes without touching anything would otherwise trigger a
        // blackout even though the user is actively watching. If any display
        // has video, the user is engaged and we skip the blackout.
        if s.blackoutWhenIdle
            && mediaWatcher.idleSeconds > s.idleSeconds
            && !mediaWatcher.mediaPlaying {
            showAll(opacity: opacity, duration: dur)
            showTopBars()
            accrueProtectedTime()
            updateState(.idleBlackout)
            return
        }

        // Per-display media + cursor follow.
        let cursorID = cursorDisplayID()
        let mediaDisplays = s.pauseOnMedia ? mediaWatcher.displaysWithMedia : []
        var mediaPausedDisplays = Set<CGDirectDisplayID>()

        for w in overlays {
            if mediaDisplays.contains(w.displayID) {
                mediaPausedDisplays.insert(w.displayID)
                if w.isVisible || w.hasPendingShow {
                    w.setVisible(false, opacity: opacity, duration: dur)
                }
                continue
            }
            if w.displayID == cursorID {
                if w.isVisible || w.hasPendingShow {
                    w.setVisible(false, opacity: opacity, duration: dur)
                }
            } else if !w.isVisible && !w.hasPendingShow {
                let delay = s.leaveDelay
                w.scheduleShow(after: delay, opacity: opacity, duration: dur) { [weak self, weak w] in
                    guard let self = self, let w = w else { return false }
                    if self.settings.pauseOnMedia &&
                       self.mediaWatcher.displaysWithMedia.contains(w.displayID) {
                        return false
                    }
                    return self.cursorDisplayID() != w.displayID
                }
            }
        }

        // Top bars: hide on displays with media, cursor-aware otherwise.
        showTopBars(forceHidden: mediaPausedDisplays)
        if overlays.contains(where: { $0.isVisible }) { accrueProtectedTime() }

        // Status: only flip to "media paused" when *every* protected display
        // is currently held hidden by video. A laptop video leaves us in
        // `.active` because the protected (external) display is dimming
        // normally per the cursor.
        if !mediaPausedDisplays.isEmpty
           && mediaPausedDisplays.count == overlays.count {
            updateState(.mediaPaused)
        } else {
            updateState(.active(protectedCount: protectedCount))
        }
    }

    private func accrueProtectedTime() {
        let now = Date()
        // Use real elapsed time, capped so a long sleep / pause doesn't
        // dump huge numbers in one go.
        let elapsed = min(0.5, now.timeIntervalSince(lastAccrualAt))
        unsavedSeconds += elapsed
        lastAccrualAt = now
        if now.timeIntervalSince(lastSaved) > 5 {
            settings.totalProtectedSeconds += unsavedSeconds
            unsavedSeconds = 0
            lastSaved = now
        }
    }
}
