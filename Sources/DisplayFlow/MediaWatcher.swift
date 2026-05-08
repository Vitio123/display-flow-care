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
    private(set) var pollInterval: TimeInterval = 2.0

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Adjusts the polling cadence — used to slow down in low-power mode.
    func setPollInterval(_ seconds: TimeInterval) {
        guard seconds != pollInterval else { return }
        pollInterval = seconds
        if timer != nil { start() }
    }

    private func poll() {
        // Decouple the two signals:
        //  - mediaPlaying = "any process holds a display-sleep assertion".
        //    Used to skip idle blackout while *something* is playing, even
        //    if we can't say where.
        //  - displaysWithMedia = a conservative per-display attribution.
        //    Only contains displays we're confident about; an ambiguous PID
        //    (windows on multiple displays) contributes nothing, so the
        //    cursor-follow loop is free to dim the protected display.
        let pids = Self.videoHoldingPIDs()
        let displays = Self.queryDisplaysWithMedia(pids: pids)
        let idle = Self.systemIdleSeconds()
        let any = !pids.isEmpty
        if displaysWithMedia != displays { displaysWithMedia = displays }
        if mediaPlaying != any { mediaPlaying = any }
        idleSeconds = idle
    }

    /// PIDs of GUI apps (regular activation policy) that hold an active
    /// display-sleep assertion. Filtering to GUI apps keeps background
    /// daemons that hold long-lived assertions (audio routers, system
    /// services) from being mistaken for media.
    static func videoHoldingPIDs() -> Set<pid_t> {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
              let byProcess = dict?.takeRetainedValue() as? [Int: NSArray]
        else { return [] }

        // Only consider apps that show in the Dock — that's where actual
        // playable media lives. Hidden helpers and daemons get filtered out.
        let guiPids: Set<pid_t> = Set(NSWorkspace.shared.runningApplications.compactMap { app in
            app.activationPolicy == .regular ? app.processIdentifier : nil
        })

        var pids = Set<pid_t>()
        for (pid, raw) in byProcess {
            let p = pid_t(pid)
            guard guiPids.contains(p) else { continue }
            guard let assertions = raw as? [[String: Any]] else { continue }
            for a in assertions {
                let level = (a["AssertLevel"] as? Int) ?? 0
                guard level > 0 else { continue }
                let type = (a["AssertType"] as? String) ?? ""
                if type == "PreventUserIdleDisplaySleep" || type == "NoDisplaySleepAssertion" {
                    pids.insert(p)
                    break
                }
            }
        }
        return pids
    }

    /// Cross-references video-holding PIDs against the on-screen window list.
    /// **Conservative**: only attribute to a display when ALL of the PID's
    /// real windows live on that display. If a PID straddles multiple
    /// displays we can't tell which has the video without inspecting page
    /// content, so we attribute to none. The cursor-follow loop then dims
    /// the protected display normally — better default than incorrectly
    /// pausing it.
    static func queryDisplaysWithMedia() -> Set<CGDirectDisplayID> {
        queryDisplaysWithMedia(pids: videoHoldingPIDs())
    }

    static func queryDisplaysWithMedia(pids: Set<pid_t>) -> Set<CGDirectDisplayID> {
        if pids.isEmpty { return [] }

        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        let displayBounds: [(CGDirectDisplayID, CGRect)] = NSScreen.screens.compactMap { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let did = (screen.deviceDescription[key] as? NSNumber)?.uint32Value
            else { return nil }
            return (did, CGDisplayBounds(did))
        }

        func displayContaining(_ rect: CGRect) -> CGDirectDisplayID? {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            for (did, dRect) in displayBounds where dRect.contains(center) {
                return did
            }
            return nil
        }

        // Group qualifying windows by PID.
        var windowsByPid: [pid_t: [CGRect]] = [:]
        for w in windows {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  pids.contains(pid),
                  let bounds = w[kCGWindowBounds as String] as? [String: NSNumber]
            else { continue }
            let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
            if layer != 0 { continue }
            if let alpha = w[kCGWindowAlpha as String] as? Double, alpha < 0.5 { continue }
            let x = bounds["X"]?.doubleValue ?? 0
            let y = bounds["Y"]?.doubleValue ?? 0
            let width = bounds["Width"]?.doubleValue ?? 0
            let height = bounds["Height"]?.doubleValue ?? 0
            // PIP windows can be ~320×180, full app windows much bigger.
            if width < 200 || height < 150 { continue }
            windowsByPid[pid, default: []].append(
                CGRect(x: x, y: y, width: width, height: height))
        }

        var result = Set<CGDirectDisplayID>()
        for (_, rects) in windowsByPid {
            var touched = Set<CGDirectDisplayID>()
            for r in rects {
                if let did = displayContaining(r) { touched.insert(did) }
            }
            // Only commit when unambiguous: all the PID's windows are on a
            // single display. If the PID has windows on both screens we
            // can't tell which one has the video, so we stay out of the
            // cursor-follow loop's way and let it dim normally.
            if touched.count == 1 {
                result.formUnion(touched)
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
