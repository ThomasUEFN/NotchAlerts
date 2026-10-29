import AppKit
import CoreAudio
import IOBluetooth

/// AirPods / Bluetooth headphones connecting, AirPlay output, and mute
/// (the Mac version of the iPhone mute switch). All through CoreAudio, so no
/// permission is needed — except Bluetooth access for AirPods battery levels.
@MainActor
final class AudioMonitor {
    var onAlert: ((NotchAlert) -> Void)?
    /// Replaces an alert that's already showing (battery levels arriving late).
    var onUpdate: ((NotchAlert) -> Void)?

    private var knownBluetooth: Set<AudioObjectID> = []
    private var lastHeadphoneAlert: [String: Date] = [:]
    private var outputDevice: AudioObjectID = 0
    private var muted: Bool?
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    func start() {
        knownBluetooth = Set(AudioDevices.bluetoothOutputs().map(\.id))

        listen(AudioDevices.systemObject, AudioDevices.address(kAudioHardwarePropertyDevices)) { [weak self] in
            self?.devicesChanged()
        }
        listen(AudioDevices.systemObject, AudioDevices.address(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
            self?.hookOutputDevice(announce: true)
        }
        hookOutputDevice(announce: false)

        if Settings.isOn(.headphoneBattery) { BluetoothBattery.requestAccess() }
    }

    /// Adds a CoreAudio listener that runs `handler` on the main thread.
    @discardableResult
    private func listen(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress,
                        handler: @escaping () -> Void) -> AudioObjectPropertyListenerBlock? {
        var address = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { handler() }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr else { return nil }
        return block
    }

    // MARK: Headphones

    private func devicesChanged() {
        let current = AudioDevices.bluetoothOutputs()
        let added = current.filter { !knownBluetooth.contains($0.id) }
        knownBluetooth = Set(current.map(\.id))
        for device in added { headphonesConnected(device) }
    }

    private func headphonesConnected(_ device: AudioDevices.Device) {
        guard Settings.isOn(.headphones) else { return }
        if let last = lastHeadphoneAlert[device.name], Date().timeIntervalSince(last) < 20 { return }
        lastHeadphoneAlert[device.name] = Date()

        // Show right away; AirPods report battery a moment later, so fill it in when it arrives.
        let alert = Self.headphoneAlert(for: device)
        onAlert?(alert)
        guard Settings.isOn(.headphoneBattery), !alert.hasBatteryLevels else { return }
        Task { [weak self] in
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 600_000_000)
                let levels = BluetoothBattery.levels(name: device.name, uid: device.uid)
                if !levels.isEmpty {
                    self?.onUpdate?(.headphones(name: device.name,
                                                symbol: SymbolPicker.headphones(for: device.name),
                                                levels: levels))
                    return
                }
            }
        }
    }

    static func headphoneAlert(for device: AudioDevices.Device) -> NotchAlert {
        let levels = Settings.isOn(.headphoneBattery)
            ? BluetoothBattery.levels(name: device.name, uid: device.uid)
            : []
        return .headphones(name: device.name, symbol: SymbolPicker.headphones(for: device.name), levels: levels)
    }

    /// Uses your real headphones if they're connected, otherwise sample AirPods Pro.
    static func sampleHeadphones() -> NotchAlert {
        if let device = AudioDevices.bluetoothOutputs().first {
            let real = headphoneAlert(for: device)
            if real.hasBatteryLevels { return real }
        }
        return .headphones(name: "AirPods Pro", symbol: SymbolPicker.headphones(for: "AirPods Pro"),
                           levels: [BatteryLevel(label: "Buds", percent: 82),
                                    BatteryLevel(label: "Case", percent: 64)])
    }

    // MARK: Output device: AirPlay, mute, volume

    private func hookOutputDevice(announce: Bool) {
        for (object, address, block) in deviceListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
        }
        deviceListeners.removeAll()

        guard let id = AudioDevices.defaultOutputDevice() else {
            outputDevice = 0
            return
        }
        let changed = id != outputDevice
        outputDevice = id
        muted = AudioDevices.isMuted(id)

        let muteAddress = AudioDevices.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        if let block = listen(id, muteAddress, handler: { [weak self] in self?.muteChanged() }) {
            deviceListeners.append((id, muteAddress, block))
        }
        // Volume keys: boringNotch may show its volume HUD, so hold new alerts briefly.
        for element in [kAudioObjectPropertyElementMain, 1] as [AudioObjectPropertyElement] {
            let volumeAddress = AudioDevices.address(kAudioDevicePropertyVolumeScalar,
                                                     kAudioDevicePropertyScopeOutput, element: element)
            if let block = listen(id, volumeAddress, handler: { BoringNotchWatcher.shared.volumeChanged() }) {
                deviceListeners.append((id, volumeAddress, block))
            }
        }

        if announce, changed, Settings.isOn(.airplay),
           let device = AudioDevices.device(id),
           device.transport == UInt32(kAudioDeviceTransportTypeAirPlay) {
            onAlert?(.airplay(name: device.name))
        }
    }

    private func muteChanged() {
        guard let now = AudioDevices.isMuted(outputDevice), now != muted else { return }
        muted = now
        if Settings.isOn(.sound) { onAlert?(.sound(muted: now)) }
    }
}

// MARK: - CoreAudio helpers

enum AudioDevices {
    struct Device: Equatable {
        let id: AudioObjectID
        let name: String
        let uid: String
        let transport: UInt32
    }

    static var systemObject: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func allDeviceIDs() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var addr = address(selector, scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func hasStreams(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    static func device(_ id: AudioObjectID) -> Device? {
        guard let name = string(id, kAudioObjectPropertyName) else { return nil }
        return Device(id: id, name: name,
                      uid: string(id, kAudioDevicePropertyDeviceUID) ?? "",
                      transport: uint32(id, kAudioDevicePropertyTransportType) ?? 0)
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        guard let id = uint32(systemObject, kAudioHardwarePropertyDefaultOutputDevice), id != 0 else { return nil }
        return AudioObjectID(id)
    }

    /// Mutes / unmutes the current output (clicking the "Muted" alert).
    static func setMuted(_ muted: Bool) {
        guard let id = defaultOutputDevice() else { return }
        var addr = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    static func isMuted(_ id: AudioObjectID) -> Bool? {
        uint32(id, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput).map { $0 != 0 }
    }

    static func bluetoothOutputs() -> [Device] {
        let bluetooth = [UInt32(kAudioDeviceTransportTypeBluetooth), UInt32(kAudioDeviceTransportTypeBluetoothLE)]
        return allDeviceIDs().compactMap { id in
            guard let info = device(id),
                  bluetooth.contains(info.transport),
                  hasStreams(id, kAudioDevicePropertyScopeOutput) else { return nil }
            return info
        }
    }

    static func isAnyInputRunning() -> Bool {
        allDeviceIDs().contains { id in
            hasStreams(id, kAudioDevicePropertyScopeInput)
                && (uint32(id, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0
        }
    }
}

// MARK: - AirPods battery (IOBluetooth)

enum BluetoothBattery {
    /// Triggers the one-time Bluetooth permission prompt.
    static func requestAccess() {
        _ = IOBluetoothDevice.pairedDevices()
    }

    static func levels(name: String, uid: String) -> [BatteryLevel] {
        guard let device = connectedDevice(name: name, uid: uid) else { return [] }
        let left = percent(device, "batteryPercentLeft")
        let right = percent(device, "batteryPercentRight")
        let single = percent(device, "batteryPercentSingle") ?? percent(device, "batteryPercentCombined")
        let chargingCase = percent(device, "batteryPercentCase")

        var result: [BatteryLevel] = []
        switch (left, right) {
        case let (l?, r?) where abs(l - r) <= 5:
            result.append(BatteryLevel(label: "Buds", percent: min(l, r)))
        case let (l?, r?):
            result.append(BatteryLevel(label: "Left", percent: l))
            result.append(BatteryLevel(label: "Right", percent: r))
        case let (l?, nil):
            result.append(BatteryLevel(label: "Left", percent: l))
        case let (nil, r?):
            result.append(BatteryLevel(label: "Right", percent: r))
        case (nil, nil):
            if let single { result.append(BatteryLevel(label: "Battery", percent: single)) }
        }
        if let chargingCase { result.append(BatteryLevel(label: "Case", percent: chargingCase)) }
        return result
    }

    private static func connectedDevice(name: String, uid: String) -> IOBluetoothDevice? {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return nil }
        // CoreAudio's UID for Bluetooth devices starts with the MAC address.
        let target = hex(uid)
        return paired.first { device in
            guard device.isConnected() else { return false }
            if let address = device.addressString {
                let candidate = hex(address)
                if !candidate.isEmpty, target.hasPrefix(candidate) { return true }
            }
            return device.name == name
        }
    }

    private static func hex(_ text: String) -> String {
        String(text.lowercased().filter { $0.isHexDigit })
    }

    /// AirPods battery levels are undocumented IOBluetoothDevice properties;
    /// read them defensively so a future macOS can't crash the app.
    private static func percent(_ device: IOBluetoothDevice, _ key: String) -> Int? {
        guard device.responds(to: NSSelectorFromString(key)),
              let number = device.value(forKey: key) as? NSNumber else { return nil }
        let value = number.intValue
        return (1...100).contains(value) ? value : nil
    }
}
