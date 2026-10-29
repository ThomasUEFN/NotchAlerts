import AppKit

/// On/off switches for each alert, stored in UserDefaults.
enum Settings {
    enum Key: String, CaseIterable {
        case lock = "alerts.lock"
        case lowBattery = "alerts.lowBattery"
        case charging = "alerts.charging"
        case sound = "alerts.sound"
        case headphones = "alerts.headphones"
        case headphoneBattery = "alerts.headphoneBattery"
        case airplay = "alerts.airplay"
        case accessories = "alerts.accessories"
        case drives = "alerts.drives"
        case displays = "alerts.displays"
        case airdrop = "alerts.airdrop"
        case wifi = "alerts.wifi"
        case network = "alerts.network"
        case privacyDots = "alerts.privacyDots"
        case matchMusicWidth = "boringNotch.matchMusicWidth"
        case matchMenuBarHeight = "fit.matchMenuBarHeight"
        case magicAccessories = "alerts.magicAccessories"
        case appleDevices = "alerts.appleDevices"
        case screenshots = "alerts.screenshots"
        case focus = "alerts.focus"
        case hideMenuBarIcon = "ui.hideMenuBarIcon"
        case didPlayWelcomeDemo = "ui.didPlayWelcomeDemo"

        var defaultValue: Bool {
            switch self {
            // boringNotch already shows its own charging alert, so ours starts off.
            case .charging, .hideMenuBarIcon, .didPlayWelcomeDemo, .matchMenuBarHeight: return false
            default: return true
            }
        }
    }

    static func register() {
        var defaults: [String: Any] = [:]
        for key in Key.allCases { defaults[key.rawValue] = key.defaultValue }
        UserDefaults.standard.register(defaults: defaults)
    }

    static func isOn(_ key: Key) -> Bool { UserDefaults.standard.bool(forKey: key.rawValue) }

    /// Fine-tunes the notch height, in screen pixels (Fit menu).
    static var heightNudge: Int {
        get { UserDefaults.standard.integer(forKey: "fit.heightNudge") }
        set { UserDefaults.standard.set(newValue, forKey: "fit.heightNudge") }
    }
    static func set(_ key: Key, _ value: Bool) { UserDefaults.standard.set(value, forKey: key.rawValue) }
}

/// Sleep, wake and display wake make USB devices, displays and the network
/// flicker on and off. Monitors stay quiet for a moment around those events
/// so you don't get a burst of fake "connected" alerts.
@MainActor
enum SystemQuiet {
    private static var isDark = false
    private static var quietUntil = Date().addingTimeInterval(6) // ignore start-up noise
    private static var tokens: [NSObjectProtocol] = []

    static var isQuiet: Bool { isDark || Date() < quietUntil }

    static func start() {
        let center = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, dark: Bool, quietFor seconds: TimeInterval) {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    SystemQuiet.isDark = dark
                    SystemQuiet.quietUntil = max(SystemQuiet.quietUntil, Date().addingTimeInterval(seconds))
                }
            })
        }
        on(NSWorkspace.willSleepNotification, dark: true, quietFor: 0)
        on(NSWorkspace.didWakeNotification, dark: false, quietFor: 15)
        on(NSWorkspace.screensDidSleepNotification, dark: true, quietFor: 0)
        on(NSWorkspace.screensDidWakeNotification, dark: false, quietFor: 10)
    }
}
