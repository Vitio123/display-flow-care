import Foundation
import IOKit
import IOKit.pwr_mgt

/// Polls two signals:
///  1. IOKit power assertions ("PreventUserIdleDisplaySleep" /
///     "NoDisplaySleepAssertion"). These are the canonical "there is video on
///     screen" signal on macOS — video players, browsers playing video (full
///     screen, picture-in-picture, or in a tab), video calls with the camera
///     on, and full-screen apps all create them. Audio-only apps (Spotify,
///     Discord voice without video) do NOT create these, so when nothing is
///     visibly playing the overlay is free to dim normally.
///  2. HIDIdleTime from IOHIDSystem — seconds since last keyboard/mouse input,
///     used by the "blackout when idle" care setting.
final class MediaWatcher: ObservableObject {
    @Published private(set) var mediaPlaying: Bool = false
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
        let media = Self.queryMediaAssertions()
        let idle = Self.systemIdleSeconds()
        if media != mediaPlaying { mediaPlaying = media }
        idleSeconds = idle
    }

    static func queryMediaAssertions() -> Bool {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
              let dict = status?.takeRetainedValue() as? [String: Int] else {
            return false
        }
        let preventDisplaySleep = (dict["PreventUserIdleDisplaySleep"] ?? 0) > 0
        let noDisplaySleep      = (dict["NoDisplaySleepAssertion"] ?? 0) > 0
        return preventDisplaySleep || noDisplaySleep
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
