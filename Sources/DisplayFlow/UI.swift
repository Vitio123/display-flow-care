import AppKit
import SwiftUI
import Combine

// MARK: - Menu bar

final class MenuBarController: NSObject {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let controller: OverlayController
    private var prefs: PreferencesWindowController?
    private var cancellables = Set<AnyCancellable>()

    init(controller: OverlayController) {
        self.controller = controller
        super.init()
        rebuild()

        Settings.shared.$enabled.dropFirst()
            .sink { [weak self] _ in self?.rebuild() }.store(in: &cancellables)
        Settings.shared.$manualRest.dropFirst()
            .sink { [weak self] _ in self?.rebuild() }.store(in: &cancellables)
        Settings.shared.$language.dropFirst()
            .sink { [weak self] _ in self?.rebuild() }.store(in: &cancellables)
        controller.$state.dropFirst()
            .sink { [weak self] _ in self?.rebuild() }.store(in: &cancellables)
    }

    private func rebuild() {
        let s = Settings.shared

        // Custom icon for the active baseline (the most-seen state). Other
        // states get a more communicative SF Symbol so the bar telegraphs
        // why we're paused.
        let icon: NSImage?
        switch controller.state {
        case .disabled:     icon = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: "Display Flow")
        case .hibernating:  icon = NSImage(systemSymbolName: "powerplug.fill", accessibilityDescription: "Display Flow")
        case .noDisplays:   icon = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Display Flow")
        case .manualRest:   icon = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: "Display Flow")
        case .scheduled:    icon = NSImage(systemSymbolName: "clock.fill", accessibilityDescription: "Display Flow")
        case .mediaPaused:  icon = NSImage(systemSymbolName: "play.rectangle.fill", accessibilityDescription: "Display Flow")
        case .idleBlackout: icon = NSImage(systemSymbolName: "bed.double.fill", accessibilityDescription: "Display Flow")
        case .active:       icon = MenuBarController.brandIcon()
        }
        statusItem.button?.image = icon

        let menu = NSMenu()

        let header = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: s.enabled ? s.t(.menuPause) : s.t(.menuResume),
                                action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let rest = NSMenuItem(title: s.manualRest ? s.t(.wakeDisplays) : s.t(.restDisplaysNow),
                              action: #selector(toggleRest), keyEquivalent: "r")
        rest.target = self
        menu.addItem(rest)

        menu.addItem(.separator())

        let prefsItem = NSMenuItem(title: s.t(.menuPreferences),
                                   action: #selector(showPrefs), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: s.t(.menuQuit),
                                action: #selector(NSApp.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func statusText() -> String {
        let s = Settings.shared
        switch controller.state {
        case .disabled:                  return s.t(.statusPaused)
        case .hibernating:
            switch controller.hibernationReason {
            case .noExternalDisplay:    return "\(s.t(.statusHibernating)) — \(s.t(.subHibernateNoExternal))"
            case .manualBatterySaver:   return "\(s.t(.statusHibernating)) — \(s.t(.subHibernateBatterySaver))"
            case .lowBattery:           return "\(s.t(.statusHibernating)) — \(s.t(.subHibernateLowBattery))"
            }
        case .noDisplays:                return s.t(.statusNoDisplaysShort)
        case .manualRest:                return s.t(.statusManualRest)
        case .scheduled:                 return s.t(.statusScheduled)
        case .mediaPaused:               return s.t(.statusMediaPaused)
        case .idleBlackout:              return s.t(.statusIdleBlackout)
        case .active(let n):
            if n == 1 { return s.t(.statusActiveOne) }
            return String(format: s.t(.statusActiveMany), n)
        }
    }

    @objc private func toggleEnabled() { Settings.shared.enabled.toggle() }
    @objc private func toggleRest()    { Settings.shared.manualRest.toggle() }
    @objc private func showPrefs()     { showPreferences() }

    /// Used by the AppDelegate when the user clicks the Dock icon.
    func showPreferences() {
        if prefs == nil {
            prefs = PreferencesWindowController(controller: controller)
        }
        prefs?.show()
    }

    /// Custom monochrome menu-bar icon — a stylized monitor with a small
    /// crescent moon inside (sleep / dim). Drawn as a template image so the
    /// system tints it correctly for light, dark, and inverted menu bars.
    static func brandIcon() -> NSImage {
        let size = NSSize(width: 19, height: 19)
        let image = NSImage(size: size, flipped: false) { _ in
            // Display body
            let dRect = NSRect(x: 1.5, y: 5, width: 16, height: 10)
            let body = NSBezierPath(roundedRect: dRect, xRadius: 1.8, yRadius: 1.8)
            body.lineWidth = 1.4
            NSColor.black.setStroke()
            body.stroke()

            // Stand neck
            let neck = NSBezierPath()
            neck.move(to: NSPoint(x: 7,    y: 5))
            neck.line(to: NSPoint(x: 6.5,  y: 2.5))
            neck.line(to: NSPoint(x: 12.5, y: 2.5))
            neck.line(to: NSPoint(x: 12,   y: 5))
            neck.lineWidth = 1.4
            neck.lineCapStyle = .round
            neck.lineJoinStyle = .round
            neck.stroke()

            // Stand base
            let base = NSBezierPath()
            base.move(to: NSPoint(x: 5,  y: 1.7))
            base.line(to: NSPoint(x: 14, y: 1.7))
            base.lineWidth = 1.4
            base.lineCapStyle = .round
            base.stroke()

            // Crescent moon inside (sleep cue) — boolean of two circles via
            // the even-odd winding rule.
            let r: CGFloat = 2.5
            let cx: CGFloat = 11.5
            let cy: CGFloat = 10
            let outer = NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            let cut   = NSBezierPath(ovalIn: NSRect(x: cx - r + 1.4, y: cy - r, width: r * 2, height: r * 2))
            outer.append(cut)
            outer.windingRule = .evenOdd
            NSColor.black.setFill()
            outer.fill()

            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - Preferences window

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    init(controller: OverlayController) {
        let view = PreferencesView()
            .environmentObject(Settings.shared)
            .environmentObject(controller.mediaWatcher)
            .environmentObject(controller)
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        win.title = "Display Flow"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.setContentSize(NSSize(width: 500, height: 760))
        super.init(window: win)
        win.center()
        win.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        // Activation policy is `.regular` for the whole lifetime now (the
        // app shows in the Dock), so we just bring the window forward.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - SwiftUI

struct PreferencesView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var media: MediaWatcher
    @EnvironmentObject var controller: OverlayController

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    statusCard
                    section(settings.t(.sectionDisplays)) { displaysContent }
                    section(settings.t(.sectionAppearance)) { appearanceContent }
                    section(settings.t(.sectionCare)) { careContent }
                    section(settings.t(.sectionPower)) { powerContent }
                    section(settings.t(.sectionSchedule)) { scheduleContent }
                    section(settings.t(.sectionLanguage)) { languageContent }
                    footer
                }
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 18)
            }

            // Sticky footer bar with the Apply / Done button. Sits flush with
            // the window edge with a hairline divider so the scroll content
            // visually tucks behind it.
            VStack(spacing: 0) {
                Divider().opacity(0.5)
                HStack {
                    Spacer()
                    Button(action: closeWindow) {
                        Text(settings.t(.applyAndClose))
                            .fontWeight(.semibold)
                            .frame(minWidth: 80)
                    }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
            }
            .background(.ultraThinMaterial)
        }
        .frame(minWidth: 520, idealWidth: 520, minHeight: 620, idealHeight: 780)
        .background(
            LinearGradient(
                colors: [Color(NSColor.windowBackgroundColor),
                         Color(NSColor.windowBackgroundColor).opacity(0.95)],
                startPoint: .top, endPoint: .bottom)
        )
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: settings.enabled)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: settings.blackoutWhenIdle)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: settings.scheduleEnabled)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: settings.manualRest)
        .animation(.easeInOut(duration: 0.3), value: controller.state)
    }

    private func closeWindow() {
        // Settings already apply live, so this just dismisses the window.
        NSApplication.shared.keyWindow?.performClose(nil)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(
                        colors: settings.enabled
                            ? [Color(red: 0.55, green: 0.30, blue: 0.95), Color(red: 0.20, green: 0.55, blue: 0.95)]
                            : [Color.gray.opacity(0.5), Color.gray.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
                Image(systemName: "display.2")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 56, height: 56)
            .shadow(color: settings.enabled ? .blue.opacity(0.25) : .clear, radius: 10, y: 4)
            .scaleEffect(settings.enabled ? 1.0 : 0.97)

            VStack(alignment: .leading, spacing: 2) {
                Text("Display Flow")
                    .font(.system(size: 20, weight: .bold))
                Text(settings.t(.appSubtitle))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: $settings.enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.large)
        }
    }

    // MARK: Status card

    private var statusCard: some View {
        let v = statusVisuals
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(v.color.opacity(0.15))
                Image(systemName: v.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(v.color)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(v.text)
                    .font(.system(size: 13, weight: .semibold))
                if let sub = v.subtitle {
                    Text(sub).font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(v.color.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(v.color.opacity(0.25), lineWidth: 1)
                )
        )
        .id(v.text)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .move(edge: .top)),
            removal: .opacity))
    }

    private struct StatusVisuals {
        let text: String
        let subtitle: String?
        let symbol: String
        let color: Color
    }

    private var statusVisuals: StatusVisuals {
        switch controller.state {
        case .disabled:
            return .init(text: settings.t(.statusPaused),
                         subtitle: settings.t(.subPaused),
                         symbol: "pause.circle.fill", color: .orange)
        case .hibernating:
            let sub: String
            switch controller.hibernationReason {
            case .noExternalDisplay:  sub = settings.t(.subHibernateNoExternal)
            case .manualBatterySaver: sub = settings.t(.subHibernateBatterySaver)
            case .lowBattery:         sub = settings.t(.subHibernateLowBattery)
            }
            return .init(text: settings.t(.statusHibernating),
                         subtitle: sub,
                         symbol: "powerplug.fill", color: .gray)
        case .noDisplays:
            return .init(text: settings.t(.statusIdle),
                         subtitle: settings.t(.subNoDisplays),
                         symbol: "exclamationmark.triangle.fill", color: .yellow)
        case .manualRest:
            return .init(text: settings.t(.statusManualRest),
                         subtitle: settings.t(.subManualRest),
                         symbol: "moon.stars.fill", color: .indigo)
        case .scheduled:
            return .init(text: settings.t(.statusScheduled),
                         subtitle: settings.t(.subScheduled),
                         symbol: "clock.fill", color: .indigo)
        case .mediaPaused:
            return .init(text: settings.t(.statusMediaPaused),
                         subtitle: settings.t(.subMediaPaused),
                         symbol: "play.rectangle.fill", color: .green)
        case .idleBlackout:
            return .init(text: settings.t(.statusIdleBlackout),
                         subtitle: settings.t(.subIdleBlackout),
                         symbol: "bed.double.fill", color: .indigo)
        case .active(let n):
            let txt = (n == 1)
                ? settings.t(.statusActiveOne)
                : String(format: settings.t(.statusActiveMany), n)
            return .init(text: txt,
                         subtitle: settings.t(.subActive),
                         symbol: "checkmark.seal.fill", color: n == 0 ? .secondary : .green)
        }
    }

    // MARK: Section frame

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(.secondary)
            content()
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .shadow(color: .black.opacity(0.04), radius: 4, y: 1)
                )
        }
    }

    // MARK: Displays

    private var displaysContent: some View {
        VStack(spacing: 0) {
            if settings.screens.isEmpty {
                Text(settings.t(.noDisplaysDetected))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(settings.screens.enumerated()), id: \.element.id) { idx, screen in
                    DisplayRow(screen: screen)
                    if idx != settings.screens.count - 1 {
                        Divider().opacity(0.4).padding(.vertical, 6)
                    }
                }
            }
        }
    }

    // MARK: Appearance + live preview

    private var appearanceContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(settings.t(.style)).frame(width: 100, alignment: .leading)
                Picker("", selection: $settings.style) {
                    Text(settings.t(.styleBlack)).tag(DimStyle.black)
                    Text(settings.t(.styleWhite)).tag(DimStyle.white)
                    Text(settings.t(.styleBlur)).tag(DimStyle.blur)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            LivePreview()
                .frame(height: 88)

            LabeledSlider(label: settings.t(.opacity),
                          value: $settings.opacity, range: 0.4...1.0,
                          format: { "\(Int($0 * 100))%" })
            LabeledSlider(label: settings.t(.fadeSpeed),
                          value: $settings.fadeDuration, range: 0.0...1.5,
                          format: { $0 < 0.05 ? self.settings.t(.fadeInstant) : String(format: "%.2fs", $0) })
            LabeledSlider(label: settings.t(.leaveDelay),
                          value: $settings.leaveDelay, range: 0...3,
                          format: { $0 < 0.05 ? self.settings.t(.leaveNone) : String(format: "%.1fs", $0) })
        }
    }

    // MARK: Care

    private var careContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $settings.pauseOnMedia) {
                careRow(symbol: "play.rectangle.fill",
                        title: settings.t(.carePauseMediaTitle),
                        subtitle: settings.t(.carePauseMediaSubtitle))
            }
            .toggleStyle(.switch)

            Divider().opacity(0.4)

            Toggle(isOn: $settings.pixelShift) {
                careRow(symbol: "arrow.up.and.down.and.arrow.left.and.right",
                        title: settings.t(.carePixelShiftTitle),
                        subtitle: settings.t(.carePixelShiftSubtitle))
            }
            .toggleStyle(.switch)

            Divider().opacity(0.4)

            Toggle(isOn: $settings.blackoutWhenIdle) {
                careRow(symbol: "bed.double.fill",
                        title: settings.t(.careBlackoutIdleTitle),
                        subtitle: settings.t(.careBlackoutIdleSubtitle))
            }
            .toggleStyle(.switch)

            if settings.blackoutWhenIdle {
                HStack {
                    Text(settings.t(.idleThreshold))
                        .frame(width: 110, alignment: .leading)
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                    Picker("", selection: $settings.idleSeconds) {
                        Text(settings.t(.minute_1)).tag(60.0)
                        Text(settings.t(.minutes_2)).tag(120.0)
                        Text(settings.t(.minutes_5)).tag(300.0)
                        Text(settings.t(.minutes_10)).tag(600.0)
                        Text(settings.t(.minutes_30)).tag(1800.0)
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    Spacer()
                }
                .padding(.leading, 30)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider().opacity(0.4)

            Button(action: { withAnimation { settings.manualRest.toggle() } }) {
                HStack(spacing: 8) {
                    Image(systemName: settings.manualRest ? "sun.max.fill" : "moon.stars.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text(settings.manualRest ? settings.t(.wakeDisplays) : settings.t(.restDisplaysNow))
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(settings.manualRest ? .blue : .indigo)
        }
    }

    // MARK: Power

    private var powerContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: Binding(
                get: { settings.launchAtLoginEnabled },
                set: { _ = settings.setLaunchAtLogin($0) }
            )) {
                careRow(symbol: "power",
                        title: settings.t(.careLaunchAtLoginTitle),
                        subtitle: settings.t(.careLaunchAtLoginSubtitle))
            }
            .toggleStyle(.switch)

            Divider().opacity(0.4)

            Toggle(isOn: $settings.batterySaverMode) {
                careRow(symbol: "leaf.fill",
                        title: settings.t(.careBatterySaverTitle),
                        subtitle: settings.t(.careBatterySaverSubtitle))
            }
            .toggleStyle(.switch)

            Divider().opacity(0.4)

            Toggle(isOn: $settings.autoBatterySaverWhenLow) {
                careRow(symbol: "battery.25",
                        title: settings.t(.careAutoBatterySaverTitle),
                        subtitle: settings.t(.careAutoBatterySaverSubtitle))
            }
            .toggleStyle(.switch)

            Divider().opacity(0.4)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text(settings.t(.powerNoExternalNote))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: Schedule

    private var scheduleContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $settings.scheduleEnabled) {
                careRow(symbol: "clock.fill",
                        title: settings.t(.scheduleTitle),
                        subtitle: settings.t(.scheduleSubtitle))
            }
            .toggleStyle(.switch)

            if settings.scheduleEnabled {
                HStack(spacing: 10) {
                    Text(settings.t(.scheduleFrom)).foregroundColor(.secondary).font(.system(size: 12))
                    DatePicker("", selection: $settings.scheduleStart,
                               displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Text(settings.t(.scheduleTo)).foregroundColor(.secondary).font(.system(size: 12))
                    DatePicker("", selection: $settings.scheduleEnd,
                               displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Spacer()
                }
                .padding(.leading, 30)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: Language

    private var languageContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(selection: $settings.language) {
                ForEach(AppLanguage.allCases) { lang in
                    HStack(spacing: 8) {
                        Text(lang.flag)
                        Text(lang.nativeName)
                    }
                    .tag(lang)
                }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 240)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(String(format: settings.t(.totalProtected),
                        formatDuration(settings.totalProtectedSeconds)))
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text("v0.4").font(.caption).foregroundColor(.secondary.opacity(0.6))
        }
        .padding(.top, 4)
    }

    // MARK: Helpers

    private func careRow(symbol: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.accentColor)
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        if h > 0 { return String(format: settings.t(.unitHourMin), h, m) }
        if m > 0 { return String(format: settings.t(.unitMin), m) }
        return String(format: settings.t(.unitSec), s)
    }
}

// MARK: - Display row with hover

private struct DisplayRow: View {
    let screen: ScreenInfo
    @EnvironmentObject var settings: Settings
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(
                        colors: screen.isBuiltin
                            ? [Color.gray.opacity(0.18), Color.gray.opacity(0.10)]
                            : [Color.blue.opacity(0.20), Color.purple.opacity(0.15)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: screen.isBuiltin ? "laptopcomputer" : "display")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(screen.isBuiltin ? .secondary : .blue)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(screen.name).font(.system(size: 13, weight: .semibold))
                    if !screen.isBuiltin {
                        Text(settings.t(.badgeExternal))
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.6)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.blue.opacity(0.18)))
                            .foregroundColor(.blue)
                    }
                }
                Text("\(Int(screen.frame.width))×\(Int(screen.frame.height)) · " +
                     (settings.isProtected(screen.id) ? settings.t(.displayProtected) : settings.t(.displayNotProtected)))
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { settings.isProtected(screen.id) },
                set: { settings.setProtected($0, for: screen.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.04) : Color.clear)
        )
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }
}

// MARK: - Live style preview

private struct LivePreview: View {
    @EnvironmentObject var settings: Settings

    var body: some View {
        ZStack {
            LinearGradient(colors: [
                Color(red: 0.95, green: 0.35, blue: 0.55),
                Color(red: 0.30, green: 0.45, blue: 0.95),
                Color(red: 0.20, green: 0.80, blue: 0.85)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)

            HStack(spacing: 6) {
                Image(systemName: "macwindow")
                Text(settings.t(.previewLabel))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white.opacity(0.85))

            Group {
                switch settings.style {
                case .black:
                    Color.black.opacity(settings.opacity)
                case .white:
                    Color.white.opacity(settings.opacity)
                case .blur:
                    Rectangle().fill(.ultraThinMaterial)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: settings.style)
            .animation(.easeInOut(duration: 0.15), value: settings.opacity)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - Slider with value badge

private struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        HStack {
            Text(label).frame(width: 100, alignment: .leading)
            Slider(value: $value, in: range)
            Text(format(value))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .trailing)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.06))
                )
        }
    }
}
