import Foundation
import IOKit.ps

/// Low battery at 20%, 10% and 5% (like iPhone), plus "charger connected".
@MainActor
final class BatteryMonitor {
    var onAlert: ((NotchAlert) -> Void)?

    private let thresholds = [20, 10, 5]
    private var lastThreshold: Int?
    private var wasOnAC: Bool?
    private var wasLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var source: CFRunLoopSource?
    private var lowPowerToken: NSObjectProtocol?

    struct Reading {
        var percent: Int
        var onAC: Bool
    }

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.check() }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = source
        }

        // boringNotch pops up its battery view when Low Power Mode changes.
        lowPowerToken = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lowPowerModeChanged() }
        }
        check()
    }

    private func lowPowerModeChanged() {
        let now = ProcessInfo.processInfo.isLowPowerModeEnabled
        if now != wasLowPower { BoringNotchWatcher.shared.powerSourceChanged() }
        wasLowPower = now
    }

    func check() {
        guard let reading = Self.read() else { return }
        let previousAC = wasOnAC
        wasOnAC = reading.onAC

        if let previousAC, previousAC != reading.onAC, !Settings.isOn(.charging) {
            // boringNotch shows its own plugged-in / unplugged alert right now.
            BoringNotchWatcher.shared.powerSourceChanged()
        }

        if reading.onAC {
            lastThreshold = nil
            if previousAC == false, Settings.isOn(.charging) {
                onAlert?(.charging(reading.percent))
            }
            return
        }

        guard let crossed = thresholds.filter({ reading.percent <= $0 }).min() else { return }
        if lastThreshold == nil || crossed < lastThreshold! {
            lastThreshold = crossed
            if Settings.isOn(.lowBattery) { onAlert?(.lowBattery(reading.percent)) }
        }
    }

    /// Internal battery level and power source, or nil on Macs without a battery.
    static func read() -> Reading? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() else { return nil }
        for source in list as Array {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let state = description[kIOPSPowerSourceStateKey] as? String
            let percent = Int((Double(current) / Double(max) * 100).rounded())
            return Reading(percent: percent, onAC: state == kIOPSACPowerValue)
        }
        return nil
    }
}
