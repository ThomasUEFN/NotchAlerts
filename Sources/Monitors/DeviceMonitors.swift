import AppKit
import DiskArbitration
import IOKit

// MARK: - USB accessories

/// A USB accessory was plugged in. Plugging in a dock fires one alert for the
/// whole batch, and USB drives get the drive alert instead of this one.
@MainActor
final class AccessoryMonitor {
    var onAlert: ((NotchAlert) -> Void)?

    private var port: IONotificationPortRef?
    private var iterator: io_iterator_t = 0
    private var batch: [String] = []
    private var batchTask: Task<Void, Never>?
    private var lastDriveMount = Date.distantPast

    func start() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            guard let context else { return }
            let monitor = Unmanaged<AccessoryMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.drain(iterator, announce: true) }
        }
        let result = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification,
                                                      IOServiceMatching("IOUSBHostDevice"),
                                                      callback, context, &iterator)
        // Devices already plugged in at launch: consume silently (this also arms the notification).
        if result == KERN_SUCCESS { drain(iterator, announce: false) }
    }

    /// A drive mounted; it gets its own alert, so drop the matching USB one.
    func driveMounted() {
        lastDriveMount = Date()
        if batch.count <= 1 {
            batch.removeAll()
            batchTask?.cancel()
        }
    }

    private func drain(_ iterator: io_iterator_t, announce: Bool) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard announce, !SystemQuiet.isQuiet, !Self.isHub(service) else { continue }
            let name = Self.name(of: service) ?? "USB Accessory"
            if Self.isAppleMobileDevice(service, name: name) {
                if Settings.isOn(.appleDevices) { onAlert?(.appleDevice(name: name)) }
                continue
            }
            guard Settings.isOn(.accessories) else { continue }
            batch.append(name)
        }
        if announce, !batch.isEmpty { scheduleBatch() }
    }

    private func scheduleBatch() {
        batchTask?.cancel()
        batchTask = Task { [weak self] in
            // Wait for the rest of a dock's devices, and for a drive to mount.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            let names = self.batch
            self.batch.removeAll()
            guard let first = names.first else { return }
            if names.count == 1, Date().timeIntervalSince(self.lastDriveMount) < 8 { return }
            let title = names.count == 1 ? first : "\(first) + \(names.count - 1) more"
            self.onAlert?(.accessory(name: title))
        }
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func name(of service: io_service_t) -> String? {
        for key in ["USB Product Name", "kUSBProductString", "Product Name"] {
            if let value = property(service, key) as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func isHub(_ service: io_service_t) -> Bool {
        (property(service, "bDeviceClass") as? Int) == 9
    }

    /// Apple's USB vendor ID is 0x05AC; iPhones and iPads name themselves.
    private static func isAppleMobileDevice(_ service: io_service_t, name: String) -> Bool {
        let vendor = property(service, "idVendor") as? Int
        let lower = name.lowercased()
        return vendor == 0x05AC && (lower.contains("iphone") || lower.contains("ipad"))
    }
}

// MARK: - Magic Mouse / Keyboard / Trackpad

/// Apple Bluetooth accessories connecting, and their battery running low
/// (20%, 10%, 5%). Connections are event-driven; battery is checked every
/// 5 minutes, which costs essentially nothing.
@MainActor
final class MagicAccessoryMonitor {
    var onAlert: ((NotchAlert) -> Void)?

    private var port: IONotificationPortRef?
    private var iterator: io_iterator_t = 0
    private var timer: Timer?
    private var lastThreshold: [String: Int] = [:]
    private static let serviceClass = "AppleDeviceManagementHIDEventService"

    struct Accessory {
        let name: String
        let percent: Int
    }

    func start() {
        if let port = IONotificationPortCreate(kIOMainPortDefault) {
            self.port = port
            IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
            let context = Unmanaged.passUnretained(self).toOpaque()
            let callback: IOServiceMatchingCallback = { context, iterator in
                guard let context else { return }
                let monitor = Unmanaged<MagicAccessoryMonitor>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { monitor.drain(iterator, announce: true) }
            }
            let result = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification,
                                                          IOServiceMatching(Self.serviceClass),
                                                          callback, context, &iterator)
            if result == KERN_SUCCESS { drain(iterator, announce: false) }
        }

        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkBatteries() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        checkBatteries()
    }

    private func drain(_ iterator: io_iterator_t, announce: Bool) {
        var names: [String] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if announce, let name = Self.string(service, "Product") { names.append(name) }
        }
        guard announce, Settings.isOn(.magicAccessories), !SystemQuiet.isQuiet else { return }
        for name in Set(names) {
            Task { [weak self] in
                // The battery level shows up a moment after connecting.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let percent = Self.accessories().first { $0.name == name }?.percent
                guard percent != nil || name.lowercased().contains("magic") else { return }
                self?.onAlert?(.magicAccessory(name: name, percent: percent, low: false))
            }
        }
    }

    private func checkBatteries() {
        for accessory in Self.accessories() {
            guard let crossed = [20, 10, 5].filter({ accessory.percent <= $0 }).min() else {
                lastThreshold[accessory.name] = nil   // charged back up
                continue
            }
            if let last = lastThreshold[accessory.name], crossed >= last { continue }
            lastThreshold[accessory.name] = crossed
            if Settings.isOn(.magicAccessories) {
                onAlert?(.magicAccessory(name: accessory.name, percent: accessory.percent, low: true))
            }
        }
    }

    /// Connected accessories that report a battery level.
    static func accessories() -> [Accessory] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(serviceClass), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [Accessory] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let battery = IORegistryEntryCreateCFProperty(service, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)
            if let name = string(service, "Product"),
               let percent = battery?.takeRetainedValue() as? Int,
               (1...100).contains(percent) {
                result.append(Accessory(name: name, percent: percent))
            }
        }
        return result
    }

    private static func string(_ service: io_service_t, _ key: String) -> String? {
        let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}

// MARK: - Drives

/// External and network drives mounting / ejecting. Disk images (.dmg) are ignored.
@MainActor
final class DriveMonitor: NSObject {
    var onAlert: ((NotchAlert) -> Void)?
    var onMount: (() -> Void)?

    private var known: Set<String> = []
    private let session = DASessionCreate(kCFAllocatorDefault)

    func start() {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                             options: [.skipHiddenVolumes]) ?? []
        for url in volumes where classify(url) != nil { known.insert(url.path) }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(didMount(_:)), name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(self, selector: #selector(didUnmount(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
    }

    @objc private func didMount(_ note: Notification) {
        guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
              let isNetwork = classify(url) else { return }
        known.insert(url.path)
        onMount?()
        guard Settings.isOn(.drives), !SystemQuiet.isQuiet else { return }
        onAlert?(.drive(name: volumeName(note, url), ejected: false, network: isNetwork, url: url))
    }

    @objc private func didUnmount(_ note: Notification) {
        guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
              known.remove(url.path) != nil,
              Settings.isOn(.drives), !SystemQuiet.isQuiet else { return }
        onAlert?(.drive(name: volumeName(note, url), ejected: true, network: false))
    }

    private func volumeName(_ note: Notification, _ url: URL) -> String {
        note.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] as? String ?? url.lastPathComponent
    }

    /// nil = not worth an alert (internal disk, disk image, system volume);
    /// otherwise whether it's a network drive.
    private func classify(_ url: URL) -> Bool? {
        let path = url.path
        guard path.hasPrefix("/Volumes/") else { return nil }
        let name = url.lastPathComponent
        if name.hasPrefix(".") || name.hasPrefix("com.apple") { return nil }

        let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey])
        if values?.volumeIsRootFileSystem == true { return nil }
        if values?.volumeIsLocal == false { return true }
        if values?.volumeIsInternal == true { return nil }
        if isDiskImage(url) { return nil }
        return false
    }

    private func isDiskImage(_ url: URL) -> Bool {
        guard let session,
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any] else { return false }
        let model = description[kDADiskDescriptionDeviceModelKey as String] as? String ?? ""
        let transport = description[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? ""
        return model.contains("Disk Image") || transport.contains("Disk Image") || transport.contains("Virtual Interface")
    }
}

// MARK: - Displays

/// External displays (including AirPlay displays) connecting / disconnecting.
@MainActor
final class DisplayMonitor: NSObject {
    var onAlert: ((NotchAlert) -> Void)?
    private var known: [CGDirectDisplayID: String] = [:]

    func start() {
        known = Self.externalDisplays()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screensChanged() {
        let current = Self.externalDisplays()
        let added = current.filter { known[$0.key] == nil }
        let removed = known.filter { current[$0.key] == nil }
        known = current
        guard Settings.isOn(.displays), !SystemQuiet.isQuiet else { return }
        for name in added.values { onAlert?(.display(name: name, connected: true)) }
        for name in removed.values { onAlert?(.display(name: name, connected: false)) }
    }

    private static func externalDisplays() -> [CGDirectDisplayID: String] {
        var result: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            if CGDisplayIsBuiltin(id) == 0 { result[id] = screen.localizedName }
        }
        return result
    }
}
