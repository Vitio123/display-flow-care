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
        NSApp.setActivationPolicy(.accessory)
        _ = AppController.shared
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
