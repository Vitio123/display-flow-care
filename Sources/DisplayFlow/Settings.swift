import AppKit
import Combine
import CoreGraphics
import ServiceManagement

// MARK: - Public types

enum DimStyle: String, CaseIterable, Identifiable {
    case black, white, blur
    var id: String { rawValue }
    var label: String {
        switch self {
        case .black: return "Black"
        case .white: return "White"
        case .blur:  return "Blur"
        }
    }
}

struct ScreenInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let isBuiltin: Bool

    static func current() -> [ScreenInfo] {
        NSScreen.screens.map { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            let did = (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
            let raw = screen.localizedName
            let name = raw.isEmpty ? "Display \(did)" : raw
            return ScreenInfo(id: did,
                              name: name,
                              frame: screen.frame,
                              isBuiltin: CGDisplayIsBuiltin(did) != 0)
        }
    }
}

extension Notification.Name {
    static let protectionChanged = Notification.Name("displayflow.protectionChanged")
}

// MARK: - Settings

final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard
    private var screensObserver: NSObjectProtocol?

    @Published var enabled: Bool          { didSet { d.set(enabled, forKey: "enabled") } }
    @Published var style: DimStyle        { didSet { d.set(style.rawValue, forKey: "style") } }
    @Published var opacity: Double        { didSet { d.set(opacity, forKey: "opacity") } }
    @Published var fadeDuration: Double   { didSet { d.set(fadeDuration, forKey: "fadeDuration") } }
    @Published var leaveDelay: Double     { didSet { d.set(leaveDelay, forKey: "leaveDelay") } }
    @Published var pauseOnMedia: Bool     { didSet { d.set(pauseOnMedia, forKey: "pauseOnMedia") } }
    @Published var hideTopBar: Bool       { didSet { d.set(hideTopBar, forKey: "hideTopBar") } }
    @Published var pixelShift: Bool       { didSet { d.set(pixelShift, forKey: "pixelShift") } }
    @Published var batterySaverMode: Bool { didSet { d.set(batterySaverMode, forKey: "batterySaverMode") } }
    @Published var autoBatterySaverWhenLow: Bool { didSet { d.set(autoBatterySaverWhenLow, forKey: "autoBatterySaverWhenLow") } }
    @Published var language: AppLanguage  { didSet { d.set(language.rawValue, forKey: "language") } }
    @Published var pauseOnFullscreen: Bool { didSet { d.set(pauseOnFullscreen, forKey: "pauseOnFullscreen") } }
    @Published var blackoutWhenIdle: Bool { didSet { d.set(blackoutWhenIdle, forKey: "blackoutWhenIdle") } }
    @Published var idleSeconds: Double    { didSet { d.set(idleSeconds, forKey: "idleSeconds") } }

    @Published var scheduleEnabled: Bool  { didSet { d.set(scheduleEnabled, forKey: "scheduleEnabled") } }
    @Published var scheduleStart: Date    { didSet { d.set(scheduleStart.timeIntervalSince1970, forKey: "scheduleStart") } }
    @Published var scheduleEnd: Date      { didSet { d.set(scheduleEnd.timeIntervalSince1970, forKey: "scheduleEnd") } }

    @Published var manualRest: Bool = false
    @Published var totalProtectedSeconds: Double { didSet { d.set(totalProtectedSeconds, forKey: "totalProtectedSeconds") } }

    /// Live list of attached displays.
    @Published var screens: [ScreenInfo] = ScreenInfo.current()

    private init() {
        self.enabled            = d.object(forKey: "enabled")            as? Bool   ?? true
        self.style              = DimStyle(rawValue: d.string(forKey: "style") ?? "") ?? .black
        self.opacity            = d.object(forKey: "opacity")            as? Double ?? 1.0
        self.fadeDuration       = d.object(forKey: "fadeDuration")       as? Double ?? 0.35
        self.leaveDelay         = d.object(forKey: "leaveDelay")         as? Double ?? 0.0
        self.pauseOnMedia       = d.object(forKey: "pauseOnMedia")       as? Bool   ?? true
        self.hideTopBar         = d.object(forKey: "hideTopBar")         as? Bool   ?? true
        self.pixelShift         = d.object(forKey: "pixelShift")         as? Bool   ?? true
        self.batterySaverMode   = d.object(forKey: "batterySaverMode")   as? Bool   ?? false
        self.autoBatterySaverWhenLow = d.object(forKey: "autoBatterySaverWhenLow") as? Bool ?? false
        if let saved = d.string(forKey: "language"), let lang = AppLanguage(rawValue: saved) {
            self.language = lang
        } else {
            self.language = AppLanguage.systemDefault
        }
        self.pauseOnFullscreen  = d.object(forKey: "pauseOnFullscreen")  as? Bool   ?? true
        self.blackoutWhenIdle   = d.object(forKey: "blackoutWhenIdle")   as? Bool   ?? false
        self.idleSeconds        = d.object(forKey: "idleSeconds")        as? Double ?? 300

        self.scheduleEnabled    = d.bool(forKey: "scheduleEnabled")
        let cal = Calendar.current
        let dStart = cal.date(bySettingHour: 22, minute: 0, second: 0, of: Date()) ?? Date()
        let dEnd   = cal.date(bySettingHour: 7,  minute: 0, second: 0, of: Date()) ?? Date()
        if let t = d.object(forKey: "scheduleStart") as? Double {
            self.scheduleStart = Date(timeIntervalSince1970: t)
        } else { self.scheduleStart = dStart }
        if let t = d.object(forKey: "scheduleEnd") as? Double {
            self.scheduleEnd = Date(timeIntervalSince1970: t)
        } else { self.scheduleEnd = dEnd }

        self.totalProtectedSeconds = d.object(forKey: "totalProtectedSeconds") as? Double ?? 0

        screensObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.screens = ScreenInfo.current()
        }
    }

    /// Default: protect external (non-builtin) displays only.
    func isProtected(_ id: CGDirectDisplayID) -> Bool {
        if let v = d.object(forKey: "protect_\(id)") as? Bool { return v }
        return CGDisplayIsBuiltin(id) == 0
    }

    func setProtected(_ flag: Bool, for id: CGDirectDisplayID) {
        d.set(flag, forKey: "protect_\(id)")
        objectWillChange.send()
        NotificationCenter.default.post(name: .protectionChanged, object: nil)
    }

    /// Localized string for the current language, with optional printf args.
    func t(_ key: LocKey) -> String {
        return translate(key, language: language)
    }

    /// Returns true if "now" falls inside the configured schedule window
    /// (handles overnight ranges like 22:00 → 07:00).
    func isInScheduleWindow(now: Date = Date()) -> Bool {
        let cal = Calendar.current
        let s = cal.dateComponents([.hour, .minute], from: scheduleStart)
        let e = cal.dateComponents([.hour, .minute], from: scheduleEnd)
        let n = cal.dateComponents([.hour, .minute], from: now)
        let sm = (s.hour ?? 0) * 60 + (s.minute ?? 0)
        let em = (e.hour ?? 0) * 60 + (e.minute ?? 0)
        let nm = (n.hour ?? 0) * 60 + (n.minute ?? 0)
        if sm == em { return false }
        if sm < em  { return nm >= sm && nm < em }
        return nm >= sm || nm < em        // overnight
    }

    // MARK: - Launch at login (SMAppService)

    /// Live read of the system's login-item registration. macOS may flip this
    /// outside our app via System Settings → General → Login Items, so we
    /// always poll instead of caching.
    var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Register/unregister the main app as a login item. macOS shows the
    /// user a notification ("'Display Flow' added to Login Items") and
    /// they can manage it from System Settings. If the user has previously
    /// denied it, `register()` throws `.notAuthorized` — we surface it.
    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> Error? {
        let svc = SMAppService.mainApp
        do {
            switch (enabled, svc.status) {
            case (true, .enabled), (false, .notRegistered), (false, .notFound):
                break  // already in desired state
            case (true, _):
                try svc.register()
            case (false, _):
                try svc.unregister()
            }
            objectWillChange.send()
            return nil
        } catch {
            objectWillChange.send()
            return error
        }
    }
}
