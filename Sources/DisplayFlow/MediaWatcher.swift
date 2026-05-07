import Foundation
import AppKit
import IOKit
import IOKit.pwr_mgt
import CoreGraphics

/// Polls power assertions per process plus HID idle time.
/// `displaysWithMedia` is the per-display answer: which physical displays
/// currently host a video-playing window. So a YouTube tab on the laptop
/// won't pause the overlay on an external monitor.
final class MediaWatcher: ObservableObject {
    @Published private(set) var displaysWithMedia: Set<CGDirectDisplayID> = []
    @Published private(set) var mediaPlaying: Bool = false      // any display has media
    /// Not @Published on purpose — it ticks every poll and would thrash SwiftUI.
    private(set) var idleSeconds: Double = 0

    private var timer: Timer?

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let displays = Self.queryDisplaysWithMedia()
        let any = !displays.isEmpty
        let idle = Self.systemIdleSeconds()
        if displaysWithMedia != displays { displaysWithMedia = displays }
        if mediaPlaying != any { mediaPlaying = any }
        idleSeconds = idle
    }

    /// PIDs that hold an active "PreventUserIdleDisplaySleep" or
    /// "NoDisplaySleepAssertion" — the assertions video players, browsers
    /// playing video, and video-call apps create. Audio-only apps don't.
    static func videoHoldingPIDs() -> Set<pid_t> {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
              let byProcess = dict?.takeRetainedValue() as? [Int: NSArray]
        else { return [] }

        var pids = Set<pid_t>()
        for (pid, raw) in byProcess {
            guard let assertions = raw as? [[String: Any]] else { continue }
            for a in assertions {
                let level = (a["AssertLevel"] as? Int) ?? 0
                guard level > 0 else { continue }
                let type = (a["AssertType"] as? String) ?? ""
                if type == "PreventUserIdleDisplaySleep" || type == "NoDisplaySleepAssertion" {
                    pids.insert(pid_t(pid))
                    break
                }
            }
        }
        return pids
    }

    /// Cross-references video-holding PIDs against the on-screen window list
    /// to figure out which physical displays actually host visible video
    /// content. The window's bounds are in CG global space (top-left origin),
    /// same as `CGDisplayBounds(displayID)`, so direct intersection works.
    static func queryDisplaysWithMedia() -> Set<CGDirectDisplayID> {
        let pids = videoHoldingPIDs()
        if pids.isEmpty { return [] }

        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        var result = Set<CGDirectDisplayID>()
        for w in windows {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  pids.contains(pid),
                  let bounds = w[kCGWindowBounds as String] as? [String: NSNumber] else { continue }
            let x = bounds["X"]?.doubleValue ?? 0
            let y = bounds["Y"]?.doubleValue ?? 0
            let width = bounds["Width"]?.doubleValue ?? 0
            let height = bounds["Height"]?.doubleValue ?? 0
            // Filter out tiny utility/system windows
            if width < 100 || height < 100 { continue }
            // Skip windows with very low alpha (likely overlays of our own kind)
            if let alpha = w[kCGWindowAlpha as String] as? Double, alpha < 0.5 { continue }

            let rect = CGRect(x: x, y: y, width: width, height: height)
            for screen in NSScreen.screens {
                let key = NSDeviceDescriptionKey("NSScreenNumber")
                guard let did = (screen.deviceDescription[key] as? NSNumber)?.uint32Value
                else { continue }
                if CGDisplayBounds(did).intersects(rect) {
                    result.insert(did)
                }
            }
        }
        return result
    }

    /// Reads HIDIdleTime from IOHIDSystem; returns seconds since last input.
    static func systemIdleSeconds() -> Double {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault,
                                                IOServiceMatching("IOHIDSystem"))
        guard entry != 0 else { return 0 }
        defer { IOObjectRelease(entry) }
        guard let prop = IORegistryEntryCreateCFProperty(
                entry, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0
              )?.takeRetainedValue() as? NSNumber else {
            return 0
        }
        return prop.doubleValue / 1_000_000_000.0
    }
}
