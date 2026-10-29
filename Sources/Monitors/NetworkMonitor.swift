import CoreWLAN
import Foundation
import Network

/// Wi‑Fi turned on/off (the Mac's airplane mode) and internet lost/restored
/// (the Mac's "No Data" alert).
@MainActor
final class NetworkMonitor {
    var onAlert: ((NotchAlert) -> Void)?

    private let pathMonitor: NWPathMonitor
    private var wifiObserver: WiFiPowerObserver?
    private var isOnline: Bool?
    private var wifiOn: Bool?
    private var lastWiFiChange = Date.distantPast
    private var offlineTask: Task<Void, Never>?
    private var announcedOffline = false

    init() {
        pathMonitor = NWPathMonitor()
    }

    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            MainActor.assumeIsolated { self?.pathChanged(online: online) }
        }
        pathMonitor.start(queue: .main)

        wifiOn = CWWiFiClient.shared().interface()?.powerOn()
        let observer = WiFiPowerObserver { [weak self] in
            Task { @MainActor in self?.wifiPowerChanged() }
        }
        observer.start()
        wifiObserver = observer
    }

    private func wifiPowerChanged() {
        guard let on = CWWiFiClient.shared().interface()?.powerOn(), on != wifiOn else { return }
        wifiOn = on
        lastWiFiChange = Date()
        if Settings.isOn(.wifi) { onAlert?(.wifi(on: on)) }
    }

    private func pathChanged(online: Bool) {
        // The first update is just the current state.
        guard let previous = isOnline else {
            isOnline = online
            return
        }
        guard previous != online else { return }
        isOnline = online
        offlineTask?.cancel()

        if !online {
            offlineTask = Task { [weak self] in
                // Ignore short blips (switching networks, waking up).
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard let self, !Task.isCancelled, self.isOnline == false else { return }
                // Turning Wi‑Fi off already showed its own alert; sleep/wake isn't news.
                guard Date().timeIntervalSince(self.lastWiFiChange) > 8, !SystemQuiet.isQuiet else { return }
                self.announcedOffline = true
                if Settings.isOn(.network) { self.onAlert?(.network(online: false)) }
            }
        } else if announcedOffline {
            announcedOffline = false
            if Settings.isOn(.network) { onAlert?(.network(online: true)) }
        }
    }
}

/// CoreWLAN delivers events on a background queue; this forwards them.
final class WiFiPowerObserver: NSObject, CWEventDelegate {
    private let client = CWWiFiClient.shared()
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        super.init()
    }

    func start() {
        client.delegate = self
        try? client.startMonitoringEvent(with: .powerDidChange)
    }

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        onChange()
    }
}
