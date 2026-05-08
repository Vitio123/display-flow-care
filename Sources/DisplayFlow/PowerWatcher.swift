import Foundation
import AppKit
import CoreGraphics
import IOKit.ps

/// Lightweight battery + external-display monitor used to drive hibernation.
///
/// - Battery is polled every 30 s. Cheap, and we only need to react when the
///   level crosses the threshold.
/// - External-display state updates from `didChangeScreenParametersNotification`
///   (event-driven, no polling).
final class PowerWatcher: ObservableObject {
    @Published private(set) var batteryPercent: Int = 100
    /// True when the Mac is running on its battery (not plugged into AC).
    /// On desktop Macs without a battery this stays `false`.
    @Published private(set) var isOnBattery: Bool = false
    @Published private(set) var hasExternalDisplay: Bool = false

    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private(set) var pollInterval: TimeInterval = 30.0

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollBattery()
        }
        pollBattery()
        updateExternalDisplay()

        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                self?.updateExternalDisplay()
            }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
    }

    func setPollInterval(_ seconds: TimeInterval) {
        guard seconds != pollInterval else { return }
        pollInterval = seconds
        if timer != nil { start() }
    }

    /// Force an immediate refresh — used after wake from sleep.
    func pollNow() {
        pollBattery()
        updateExternalDisplay()
    }

    private func pollBattery() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            // No power sources reported — desktop Mac, no battery.
            if batteryPercent != 100 { batteryPercent = 100 }
            if isOnBattery { isOnBattery = false }
            return
        }

        for source in sources {
            guard let descRaw = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue(),
                  let desc = descRaw as? [String: Any] else { continue }
            guard let cap = desc[kIOPSCurrentCapacityKey as String] as? Int,
                  let max = desc[kIOPSMaxCapacityKey as String] as? Int,
                  max > 0 else { continue }

            let pct = Int(round(Double(cap) / Double(max) * 100.0))
            let state = desc[kIOPSPowerSourceStateKey as String] as? String
            let onBattery = (state == kIOPSBatteryPowerValue as String)

            if pct != batteryPercent { batteryPercent = pct }
            if onBattery != isOnBattery { isOnBattery = onBattery }
            return
        }
        // Power sources list was empty — same fallback.
        if batteryPercent != 100 { batteryPercent = 100 }
        if isOnBattery { isOnBattery = false }
    }

    private func updateExternalDisplay() {
        let has = NSScreen.screens.contains { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let did = (screen.deviceDescription[key] as? NSNumber)?.uint32Value
            else { return false }
            return CGDisplayIsBuiltin(did) == 0
        }
        if has != hasExternalDisplay { hasExternalDisplay = has }
    }
}
