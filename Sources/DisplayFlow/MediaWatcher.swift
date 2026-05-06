import Foundation
import IOKit
import IOKit.pwr_mgt
import CoreAudio

/// Polls three signals:
///  1. IOKit power assertions ("PreventUserIdleDisplaySleep" /
///     "NoDisplaySleepAssertion") — video players, video calls with the
///     camera on, full-screen presentations.
///  2. CoreAudio default-output activity — catches the cases the power
///     assertion misses: Discord voice calls, Spotify, FaceTime audio, etc.
///  3. HIDIdleTime from IOHIDSystem — seconds since last keyboard/mouse input,
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
        let media = Self.queryMediaAssertions() || Self.audioOutputActive()
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

    /// True if the default audio output device currently has IO running —
    /// i.e. some process is actively producing sound. Catches Discord voice
    /// calls, Spotify, music apps, etc. that don't bother to hold a display
    /// sleep assertion.
    static func audioOutputActive() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let r1 = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &deviceID)
        guard r1 == noErr, deviceID != 0 else { return false }

        var running = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        addr.mScope    = kAudioObjectPropertyScopeOutput

        let r2 = AudioObjectGetPropertyData(
            deviceID, &addr, 0, nil, &size, &running)
        return r2 == noErr && running != 0
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
