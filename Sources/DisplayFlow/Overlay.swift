import AppKit
import Combine

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
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.contentView = view
        w.alphaValue = 0
        w.orderFrontRegardless()
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
        isVisible = visible
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
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.contentView = view
        w.alphaValue = 0
        w.orderFrontRegardless()
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
    case noDisplays                 // no protected displays selected
    case manualRest                 // user pressed Rest Now
    case scheduled                  // schedule window active
    case mediaPaused                // video / call playing → overlay hidden
    case idleBlackout               // system idle → overlay forced
    case active(protectedCount: Int)
}

// MARK: - Controller

final class OverlayController: ObservableObject {
    let mediaWatcher = MediaWatcher()

    private var overlays: [OverlayWindow] = []
    private var topBars: [TopBarWindow] = []
    private var timer: Timer?
    private let settings = Settings.shared
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var protectionObserver: NSObjectProtocol?

    @Published private(set) var protectedCount: Int = 0
    @Published private(set) var state: OverlayState = .active(protectedCount: 0)

    /// Battery for stats: only commit to UserDefaults every ~5s to avoid churn.
    private var unsavedSeconds: Double = 0
    private var lastSaved: Date = .distantPast

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

    // Mission-Control / space-switch handling. Several signals are combined:
    //   - `activeSpaceDidChangeNotification` for real space switches
    //   - cursor warp (large jump in one tick) for system cursor teleports
    //   - `NSWindow.didChangeOcclusionStateNotification` — when our overlay
    //     gets covered by a system UI like Mission Control
    // When any fires we run a "graceful pulse": fade overlays out smoothly,
    // hold while MC is up, fade back in smoothly. The cursor-follow loop is
    // also frozen during the pulse so it can't fight the animation.
    private var lastCursorPos: NSPoint = NSEvent.mouseLocation
    private var freezeUntil: Date = .distantPast
    private var pulseRestoreItem: DispatchWorkItem?
    private var spaceObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?
    private let pulseFadeSeconds: Double = 0.5
    private let pulseHoldSeconds: Double = 1.0

    init() {
        mediaWatcher.start()
        rebuild()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.rebuild() }

        protectionObserver = NotificationCenter.default.addObserver(
            forName: .protectionChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuild() }

        // Real space switches (Ctrl+Left/Right, swipe, click in Mission
        // Control) come through here — run the graceful pulse so the
        // overlay fades smoothly instead of snapping.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.beginGracefulPulse()
        }

        // When Mission Control draws its grid above us our overlay's
        // occlusion state flips to "not visible" — that's the cleanest
        // signal we get for "MC just opened". Fires also when MC closes
        // and our window becomes visible again.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil, queue: .main
        ) { [weak self] notif in
            guard let window = notif.object as? NSWindow,
                  let self = self,
                  self.overlays.contains(where: { $0.window == window })
            else { return }
            if !window.occlusionState.contains(.visible) {
                self.beginGracefulPulse()
            }
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

        timer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func rebuild() {
        overlays.forEach { $0.close() }
        topBars.forEach { $0.close() }

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

    /// Start a graceful pulse: fade overlays out, hold ~1s while Mission
    /// Control / space animation is happening, then fade back in. Bypasses
    /// the cursor-follow loop so it can't fight the animation.
    private func beginGracefulPulse() {
        let totalSeconds = pulseFadeSeconds + pulseHoldSeconds + pulseFadeSeconds
        let now = Date()
        // Don't restart a pulse that's already running unless it's almost done.
        if now < freezeUntil.addingTimeInterval(-pulseFadeSeconds) { return }
        freezeUntil = now.addingTimeInterval(totalSeconds)

        // Fade currently-visible overlays out smoothly.
        let opacity = CGFloat(settings.opacity)
        for w in overlays where w.isVisible || w.hasPendingShow {
            w.setVisible(false, opacity: opacity, duration: pulseFadeSeconds)
        }
        for bar in topBars {
            bar.setVisible(false, duration: pulseFadeSeconds)
        }

        // After the hold, restore based on current cursor / state. Cancel any
        // previous restore item so back-to-back triggers don't fight.
        pulseRestoreItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pulseRestoreItem = nil
            // tick() will pick up where it left off — just nudge the freeze
            // out so cursor-follow can run again on the next tick.
            self.freezeUntil = .distantPast
        }
        pulseRestoreItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + pulseFadeSeconds + pulseHoldSeconds,
            execute: work)
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
        pixelShiftTick()

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
        if s.blackoutWhenIdle && mediaWatcher.idleSeconds > s.idleSeconds {
            showAll(opacity: opacity, duration: dur)
            showTopBars()
            accrueProtectedTime()
            updateState(.idleBlackout)
            return
        }

        // Cursor warp detection — system cursor teleports during Mission
        // Control / app switcher / etc.
        let now = Date()
        let m = NSEvent.mouseLocation
        let dx = m.x - lastCursorPos.x
        let dy = m.y - lastCursorPos.y
        if (dx * dx + dy * dy).squareRoot() > 600 {
            beginGracefulPulse()
        }
        lastCursorPos = m

        // Frozen: pulse animation is running (fade-out → hold → fade-in).
        if now < freezeUntil {
            if overlays.contains(where: { $0.isVisible }) {
                accrueProtectedTime()
            }
            updateState(.active(protectedCount: protectedCount))
            return
        }

        // Per-display media + cursor follow.
        let cursorID = cursorDisplayID()
        let mediaDisplays = s.pauseOnMedia ? mediaWatcher.displaysWithMedia : []
        var anyDimmed = false
        var mediaOnAnyProtected = false
        var mediaPausedDisplays = Set<CGDirectDisplayID>()

        for w in overlays {
            let mediaHere = mediaDisplays.contains(w.displayID)
            if mediaHere {
                mediaOnAnyProtected = true
                mediaPausedDisplays.insert(w.displayID)
                // Hide because video is on THIS display.
                if w.isVisible || w.hasPendingShow {
                    w.setVisible(false, opacity: opacity, duration: dur)
                }
                continue
            }

            if w.displayID == cursorID {
                if w.isVisible || w.hasPendingShow {
                    w.setVisible(false, opacity: opacity, duration: dur)
                }
            } else {
                if w.isVisible { anyDimmed = true }
                if !w.isVisible && !w.hasPendingShow {
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
        }
        // Top bars: hide on displays where video is playing, normal cursor
        // logic everywhere else.
        showTopBars(forceHidden: mediaPausedDisplays)
        if anyDimmed { accrueProtectedTime() }

        // Status only goes "media paused" if video is on a *protected* display.
        // Video on the laptop (unprotected) leaves us in `.active`.
        if mediaOnAnyProtected && mediaPausedDisplays.count == overlays.count {
            updateState(.mediaPaused)
        } else {
            updateState(.active(protectedCount: protectedCount))
        }
    }

    private func accrueProtectedTime() {
        unsavedSeconds += 1.0/30.0
        if Date().timeIntervalSince(lastSaved) > 5 {
            settings.totalProtectedSeconds += unsavedSeconds
            unsavedSeconds = 0
            lastSaved = Date()
        }
    }
}
