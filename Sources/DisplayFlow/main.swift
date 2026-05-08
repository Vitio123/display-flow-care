import Cocoa

final class AppController {
    static let shared = AppController()
    let overlay: OverlayController
    let menuBar: MenuBarController

    private init() {
        let c = OverlayController()
        self.overlay = c
        self.menuBar = MenuBarController(controller: c)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        // Regular activation policy: app shows in the Dock and is launchable
        // from Spotlight / Launchpad. The menu-bar status item stays visible.
        NSApp.setActivationPolicy(.regular)
        _ = AppController.shared
    }

    /// Closing the Preferences window doesn't quit the app — Display Flow is
    /// still running in the menu bar / hibernating, doing its job.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Click the Dock icon → bring Preferences forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            AppController.shared.menuBar.showPreferences()
        }
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
