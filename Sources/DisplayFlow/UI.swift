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
        controller.$state.dropFirst()
            .sink { [weak self] _ in self?.rebuild() }.store(in: &cancellables)
    }

    private func rebuild() {
        let s = Settings.shared

        let symbol: String
        switch controller.state {
        case .disabled:     symbol = "moon.zzz"
        case .noDisplays:   symbol = "exclamationmark.triangle"
        case .manualRest:   symbol = "moon.fill"
        case .scheduled:    symbol = "clock.fill"
        case .mediaPaused:  symbol = "play.rectangle.fill"
        case .idleBlackout: symbol = "bed.double.fill"
        case .active:       symbol = "rectangle.on.rectangle"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol,
                                           accessibilityDescription: "Display Flow")

        let menu = NSMenu()

        let header = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: s.enabled ? "Pause Display Flow" : "Resume Display Flow",
                                action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let rest = NSMenuItem(title: s.manualRest ? "Wake Displays" : "Rest Displays Now",
                              action: #selector(toggleRest), keyEquivalent: "r")
        rest.target = self
        menu.addItem(rest)

        menu.addItem(.separator())

        let prefsItem = NSMenuItem(title: "Preferences…",
                                   action: #selector(showPrefs), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Display Flow",
                                action: #selector(NSApp.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func statusText() -> String {
        switch controller.state {
        case .disabled:                  return "Paused"
        case .noDisplays:                return "No displays selected"
        case .manualRest:                return "Resting displays"
        case .scheduled:                 return "Resting on schedule"
        case .mediaPaused:               return "Paused — media is playing"
        case .idleBlackout:              return "Blackout — system idle"
        case .active(let n):
            return n == 1 ? "Protecting 1 display" : "Protecting \(n) displays"
        }
    }

    @objc private func toggleEnabled() { Settings.shared.enabled.toggle() }
    @objc private func toggleRest()    { Settings.shared.manualRest.toggle() }
    @objc private func showPrefs() {
        if prefs == nil {
            prefs = PreferencesWindowController(controller: controller)
        }
        prefs?.show()
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
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - SwiftUI

struct PreferencesView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var media: MediaWatcher
    @EnvironmentObject var controller: OverlayController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                statusCard
                section("Displays") { displaysContent }
                section("Appearance") { appearanceContent }
                section("Care") { careContent }
                section("Schedule") { scheduleContent }
                footer
            }
            .padding(28)
        }
        .frame(minWidth: 500, idealWidth: 500, minHeight: 600, idealHeight: 760)
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
                Text("Burn-in protection for your monitor")
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
            return .init(text: "Paused",
                         subtitle: "Display Flow is off",
                         symbol: "pause.circle.fill", color: .orange)
        case .noDisplays:
            return .init(text: "No displays selected for protection",
                         subtitle: "Toggle a display below to start",
                         symbol: "exclamationmark.triangle.fill", color: .yellow)
        case .manualRest:
            return .init(text: "Resting displays",
                         subtitle: "Click Wake Displays to resume",
                         symbol: "moon.stars.fill", color: .indigo)
        case .scheduled:
            return .init(text: "Resting on schedule",
                         subtitle: "Auto-rest window is active",
                         symbol: "clock.fill", color: .indigo)
        case .mediaPaused:
            return .init(text: "Paused — media is playing",
                         subtitle: "Will resume when playback stops",
                         symbol: "play.rectangle.fill", color: .green)
        case .idleBlackout:
            return .init(text: "Blackout — system is idle",
                         subtitle: "Wakes on any input",
                         symbol: "bed.double.fill", color: .indigo)
        case .active(let n):
            let txt = n == 1 ? "Active — protecting 1 display"
                             : "Active — protecting \(n) displays"
            return .init(text: txt,
                         subtitle: "Move your cursor between screens",
                         symbol: "checkmark.seal.fill", color: .green)
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
                Text("No displays detected.")
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
                Text("Style").frame(width: 100, alignment: .leading)
                Picker("", selection: $settings.style) {
                    ForEach(DimStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            LivePreview()
                .frame(height: 88)

            LabeledSlider(label: "Opacity",
                          value: $settings.opacity, range: 0.4...1.0,
                          format: { "\(Int($0 * 100))%" })
            LabeledSlider(label: "Fade speed",
                          value: $settings.fadeDuration, range: 0.0...1.5,
                          format: { $0 < 0.05 ? "Instant" : String(format: "%.2fs", $0) })
            LabeledSlider(label: "Leave delay",
                          value: $settings.leaveDelay, range: 0...3,
                          format: { $0 < 0.05 ? "None" : String(format: "%.1fs", $0) })
        }
    }

    // MARK: Care

    private var careContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $settings.pauseOnMedia) {
                careRow(symbol: "play.rectangle.fill",
                        title: "Pause when media is playing",
                        subtitle: "Detects video, voice calls (Discord, FaceTime), music, and full-screen apps.")
            }
            .toggleStyle(.switch)

            Divider().opacity(0.4)

            Toggle(isOn: $settings.blackoutWhenIdle) {
                careRow(symbol: "bed.double.fill",
                        title: "Blackout protected displays when idle",
                        subtitle: "After a period of no input, fully cover protected displays.")
            }
            .toggleStyle(.switch)

            if settings.blackoutWhenIdle {
                HStack {
                    Text("Idle threshold")
                        .frame(width: 110, alignment: .leading)
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                    Picker("", selection: $settings.idleSeconds) {
                        Text("1 minute").tag(60.0)
                        Text("2 minutes").tag(120.0)
                        Text("5 minutes").tag(300.0)
                        Text("10 minutes").tag(600.0)
                        Text("30 minutes").tag(1800.0)
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
                    Text(settings.manualRest ? "Wake Displays" : "Rest Displays Now")
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

    // MARK: Schedule

    private var scheduleContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $settings.scheduleEnabled) {
                careRow(symbol: "clock.fill",
                        title: "Auto-rest on schedule",
                        subtitle: "Force-rest protected displays during set hours.")
            }
            .toggleStyle(.switch)

            if settings.scheduleEnabled {
                HStack(spacing: 10) {
                    Text("From").foregroundColor(.secondary).font(.system(size: 12))
                    DatePicker("", selection: $settings.scheduleStart,
                               displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Text("to").foregroundColor(.secondary).font(.system(size: 12))
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

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text("Total time protected: \(formatDuration(settings.totalProtectedSeconds))")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text("v0.3").font(.caption).foregroundColor(.secondary.opacity(0.6))
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
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
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
                        Text("EXTERNAL")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.6)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.blue.opacity(0.18)))
                            .foregroundColor(.blue)
                    }
                }
                Text("\(Int(screen.frame.width))×\(Int(screen.frame.height))" +
                     (settings.isProtected(screen.id) ? " · Protected" : " · Not protected"))
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
            // Mock content underneath
            LinearGradient(colors: [
                Color(red: 0.95, green: 0.35, blue: 0.55),
                Color(red: 0.30, green: 0.45, blue: 0.95),
                Color(red: 0.20, green: 0.80, blue: 0.85)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)

            HStack(spacing: 6) {
                Image(systemName: "macwindow")
                Text("Your screen")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white.opacity(0.85))

            // The dim overlay preview
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
