import AppKit
import Combine

// MARK: - One overlay per protected screen

final class OverlayWindow {
    let window: NSWindow
    let displayID: CGDirectDisplayID
    let screenRef: NSScreen
    private var pendingShow: DispatchWorkItem?

    init(screen: NSScreen, style: DimStyle) {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        self.displayID = (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
        self.screenRef = screen

        let view: NSView
        switch style {
        case .blur:
            let v = NSVisualEffectView(frame: screen.frame)
            v.material = .fullScreenUI
            v.blendingMode = .behindWindow
            v.state = .active
            view = v
        case .black, .white:
            let v = NSView(frame: screen.frame)
            v.wantsLayer = true
            v.layer?.backgroundColor = (style == .white ? NSColor.white : NSColor.black).cgColor
            view = v
        }

        let w = NSWindow(contentRect: screen.frame,
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

    func setVisible(_ visible: Bool, opacity: CGFloat, duration: Double) {
        pendingShow?.cancel(); pendingShow = nil
        let target: CGFloat = visible ? opacity : 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = target
        }
    }

    func scheduleShow(after delay: TimeInterval,
                      opacity: CGFloat,
                      duration: Double,
                      condition: @escaping () -> Bool) {
        pendingShow?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, condition() else { return }
            self.setVisible(true, opacity: opacity, duration: duration)
        }
        pendingShow = work
        if delay <= 0 {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
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

    init(screen: NSScreen, style: DimStyle) {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        self.displayID = (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
        self.screenRef = screen

        // Computed per display so notched / scaled displays stay accurate.
        let measured = screen.frame.maxY - screen.visibleFrame.maxY
        let h = max(28, measured + 2)
        self.height = h

        let frame = NSRect(x: screen.frame.minX,
                           y: screen.frame.maxY - h,
                           width: screen.frame.width,
                           height: h)
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

    init() {
        mediaWatcher.start()
        rebuild()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.rebuild() }

        protectionObserver = NotificationCenter.default.addObserver(
            forName: .protectionChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuild() }

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

    private func showTopBars() {
        guard !topBars.isEmpty else { return }
        let cursorID = cursorDisplayID()
        for bar in topBars {
            let revealing = (bar.displayID == cursorID) && isCursorInTopStrip(displayID: bar.displayID)
            // Reveal fast (so menus feel snappy), hide a touch slower.
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
        if s.pauseOnMedia && mediaWatcher.mediaPlaying {
            hideAll(duration: dur)
            // While media is playing the user probably wants the menu bar
            // visible too (clock, sound, etc.), so the cover steps out.
            hideTopBars()
            updateState(.mediaPaused)
            return
        }
        if s.blackoutWhenIdle && mediaWatcher.idleSeconds > s.idleSeconds {
            showAll(opacity: opacity, duration: dur)
            showTopBars()
            accrueProtectedTime()
            updateState(.idleBlackout)
            return
        }

        // Cursor follow
        let cursorID = cursorDisplayID()
        var anyDimmed = false
        for w in overlays {
            if w.displayID == cursorID {
                w.cancelPending()
                w.setVisible(false, opacity: opacity, duration: dur)
            } else {
                if w.alphaValue > 0.5 { anyDimmed = true }
                if w.alphaValue < opacity - 0.01 {
                    let delay = s.leaveDelay
                    w.scheduleShow(after: delay, opacity: opacity, duration: dur) { [weak self, weak w] in
                        guard let self = self, let w = w else { return false }
                        return self.cursorDisplayID() != w.displayID
                    }
                }
            }
        }
        showTopBars()
        if anyDimmed { accrueProtectedTime() }
        updateState(.active(protectedCount: protectedCount))
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
