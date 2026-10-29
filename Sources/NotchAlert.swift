import AppKit
import SwiftUI

enum Tint: String, Equatable {
    case white, gray, red, orange, yellow, green, blue, purple, pink

    var color: Color {
        switch self {
        case .white: return .white
        case .gray: return Color(white: 0.62)
        case .red: return Color(nsColor: .systemRed)
        case .orange: return Color(nsColor: .systemOrange)
        case .yellow: return Color(nsColor: .systemYellow)
        case .green: return Color(nsColor: .systemGreen)
        case .blue: return Color(nsColor: .systemBlue)
        case .purple: return Color(nsColor: .systemPurple)
        case .pink: return Color(nsColor: .systemPink)
        }
    }
}

struct BatteryLevel: Equatable {
    var label: String
    var percent: Int
}

struct NotchAlert: Equatable {
    enum Kind: Equatable {
        case lock, lowBattery, charging, sound, headphones, airplay, accessory,
             drive, display, airdrop, wifi, network, custom,
             magicAccessory, appleDevice, screenshot, focus
    }

    enum Layout: Equatable {
        /// Notch-height pill: text on the left wing, icon / value on the right
        /// wing — the same shape as boringNotch's charging alert.
        case compact(text: String, symbol: String?, tint: Tint, value: String?, battery: Double?)
        /// A taller card that drops below the notch (device name + details).
        case card(symbol: String, tint: Tint, title: String, subtitle: String,
                  subtitleTint: Tint, levels: [BatteryLevel])
    }

    var kind: Kind
    var layout: Layout
    /// Seconds the alert stays expanded.
    var duration: TimeInterval = 3
    /// Queued alerts older than this are dropped (e.g. if boringNotch stayed open).
    var maxAge: TimeInterval = 20
    /// What clicking the alert does (nil = not clickable).
    var action: AlertAction? = nil
    /// Image shown instead of the symbol in a card (screenshots).
    var thumbnail: NSImage? = nil

    var title: String {
        switch layout {
        case let .compact(text, _, _, _, _): return text
        case let .card(_, _, title, _, _, _): return title
        }
    }

    var hasBatteryLevels: Bool {
        if case let .card(_, _, _, _, _, levels) = layout { return !levels.isEmpty }
        return false
    }

    /// Same alert, but clicking it opens `url`.
    func opening(_ url: URL) -> NotchAlert {
        var copy = self
        copy.action = .open(url)
        return copy
    }

    var isCard: Bool {
        if case .card = layout { return true }
        return false
    }

    /// Width of each side wing of a compact alert.
    var compactWing: CGFloat {
        guard case let .compact(text, symbol, _, value, battery) = layout else { return 0 }
        let left = TextMeasure.width(text)
        var right: CGFloat = 0
        if symbol != nil { right += 18 }
        if let value { right += (right > 0 ? 6 : 0) + TextMeasure.width(value) }
        if battery != nil { right += (right > 0 ? 6 : 0) + Metrics.batteryWidth }
        return min(max(left, right, 60), 220)
    }
}

// MARK: - Click actions

enum AlertAction: Equatable {
    case open(URL)      // a file, folder, app or System Settings page
    case reveal(URL)    // select it in Finder
    case unmute
}

/// System Settings pages.
enum Pane {
    static let battery = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!
    static let sound = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!
    static let bluetooth = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!
    static let displays = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!
    static let wifi = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!
    static let network = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!
    static let focus = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")!
    static let fullDiskAccess = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    static let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
}

// MARK: - The alerts

extension NotchAlert {
    static func lock(unlocked: Bool) -> NotchAlert {
        NotchAlert(kind: .lock,
                   layout: .compact(text: unlocked ? "Unlocked" : "Locked",
                                    symbol: unlocked ? "lock.open.fill" : "lock.fill",
                                    tint: .white, value: nil, battery: nil),
                   duration: 2.5, maxAge: 5)
    }

    static func lowBattery(_ percent: Int) -> NotchAlert {
        NotchAlert(kind: .lowBattery,
                   layout: .compact(text: "Low Battery", symbol: nil, tint: .red,
                                    value: "\(percent)%", battery: Double(percent) / 100),
                   duration: 4, maxAge: 600, action: .open(Pane.battery))
    }

    static func charging(_ percent: Int) -> NotchAlert {
        NotchAlert(kind: .charging,
                   layout: .compact(text: "Charging", symbol: nil, tint: .green,
                                    value: "\(percent)%", battery: Double(percent) / 100),
                   duration: 3, maxAge: 10, action: .open(Pane.battery))
    }

    /// The Mac version of the iPhone mute switch. Click "Muted" to unmute.
    static func sound(muted: Bool) -> NotchAlert {
        NotchAlert(kind: .sound,
                   layout: .compact(text: muted ? "Muted" : "Sound On",
                                    symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                    tint: muted ? .red : .white, value: nil, battery: nil),
                   duration: muted ? 3 : 2, maxAge: 5, action: muted ? .unmute : .open(Pane.sound))
    }

    static func headphones(name: String, symbol: String, levels: [BatteryLevel]) -> NotchAlert {
        NotchAlert(kind: .headphones,
                   layout: .card(symbol: symbol, tint: .white, title: name, subtitle: "Connected",
                                 subtitleTint: .green, levels: levels),
                   duration: 4, maxAge: 20, action: .open(Pane.bluetooth))
    }

    static func airplay(name: String) -> NotchAlert {
        NotchAlert(kind: .airplay,
                   layout: .card(symbol: SymbolPicker.first(["airplay.audio", "airplayaudio"], fallback: "hifispeaker.fill"),
                                 tint: .blue, title: name, subtitle: "Playing via AirPlay",
                                 subtitleTint: .blue, levels: []),
                   duration: 3.5, maxAge: 15, action: .open(Pane.sound))
    }

    static func accessory(name: String) -> NotchAlert {
        NotchAlert(kind: .accessory,
                   layout: .card(symbol: SymbolPicker.first(["cable.connector"], fallback: "powerplug.fill"),
                                 tint: .white, title: name, subtitle: "Accessory connected",
                                 subtitleTint: .green, levels: []),
                   duration: 3, maxAge: 15)
    }

    /// Click a connected drive to open it in Finder.
    static func drive(name: String, ejected: Bool, network: Bool, url: URL? = nil) -> NotchAlert {
        let symbol = network ? "server.rack" : (ejected ? "externaldrive" : "externaldrive.fill")
        let subtitle = ejected ? "Ejected — safe to disconnect" : (network ? "Network drive connected" : "Drive connected")
        return NotchAlert(kind: .drive,
                          layout: .card(symbol: SymbolPicker.first([symbol], fallback: "externaldrive.fill"),
                                        tint: .white, title: name, subtitle: subtitle,
                                        subtitleTint: ejected ? .gray : .green, levels: []),
                          duration: 3, maxAge: 15,
                          action: ejected ? nil : url.map { AlertAction.open($0) })
    }

    static func display(name: String, connected: Bool) -> NotchAlert {
        NotchAlert(kind: .display,
                   layout: .card(symbol: SymbolPicker.first(["display"], fallback: "desktopcomputer"),
                                 tint: .white, title: name,
                                 subtitle: connected ? "Display connected" : "Display disconnected",
                                 subtitleTint: connected ? .green : .gray, levels: []),
                   duration: 3, maxAge: 15, action: connected ? .open(Pane.displays) : nil)
    }

    /// Click to show the file in Finder.
    static func airdrop(title: String, file: URL? = nil) -> NotchAlert {
        NotchAlert(kind: .airdrop,
                   layout: .card(symbol: SymbolPicker.first(["airdrop"], fallback: "arrow.down.circle.fill"),
                                 tint: .blue, title: title, subtitle: "Received via AirDrop",
                                 subtitleTint: .blue, levels: []),
                   duration: 4, maxAge: 30, action: file.map { AlertAction.reveal($0) })
    }

    /// The Mac version of airplane mode.
    static func wifi(on: Bool) -> NotchAlert {
        NotchAlert(kind: .wifi,
                   layout: .compact(text: on ? "Wi‑Fi On" : "Wi‑Fi Off",
                                    symbol: on ? "wifi" : "wifi.slash",
                                    tint: on ? .blue : .orange, value: nil, battery: nil),
                   duration: 2.5, maxAge: 10, action: .open(Pane.wifi))
    }

    /// The Mac version of iPhone's "No Data" alert.
    static func network(online: Bool) -> NotchAlert {
        NotchAlert(kind: .network,
                   layout: .compact(text: online ? "Back Online" : "No Internet",
                                    symbol: SymbolPicker.first([online ? "network" : "network.slash"],
                                                               fallback: online ? "wifi" : "wifi.exclamationmark"),
                                    tint: online ? .green : .orange, value: nil, battery: nil),
                   duration: 3, maxAge: 15, action: .open(Pane.network))
    }

    /// Magic Mouse / Keyboard / Trackpad connected, or running low.
    static func magicAccessory(name: String, percent: Int?, low: Bool) -> NotchAlert {
        NotchAlert(kind: .magicAccessory,
                   layout: .card(symbol: SymbolPicker.magicAccessory(for: name), tint: .white, title: name,
                                 subtitle: low ? "Low Battery" : "Connected",
                                 subtitleTint: low ? .red : .green,
                                 levels: percent.map { [BatteryLevel(label: "Battery", percent: $0)] } ?? []),
                   duration: low ? 4 : 3, maxAge: low ? 600 : 20, action: .open(Pane.bluetooth))
    }

    /// iPhone or iPad plugged in with a cable. Click to open Finder (it shows up in the sidebar).
    static func appleDevice(name: String) -> NotchAlert {
        let isPad = name.lowercased().contains("ipad")
        return NotchAlert(kind: .appleDevice,
                          layout: .card(symbol: SymbolPicker.first([isPad ? "ipad" : "iphone"], fallback: "iphone"),
                                        tint: .white, title: name, subtitle: "Connected",
                                        subtitleTint: .green, levels: []),
                          duration: 3, maxAge: 15, action: .open(Pane.finder))
    }

    /// Click to open the screenshot.
    static func screenshot(file: URL?, recording: Bool, thumbnail: NSImage?) -> NotchAlert {
        NotchAlert(kind: .screenshot,
                   layout: .card(symbol: recording ? "record.circle" : SymbolPicker.first(["camera.viewfinder"], fallback: "photo"),
                                 tint: .white,
                                 title: recording ? "Screen Recording" : "Screenshot",
                                 subtitle: file?.deletingPathExtension().lastPathComponent ?? "Saved",
                                 subtitleTint: .gray, levels: []),
                   duration: 3.5, maxAge: 20, action: file.map { AlertAction.open($0) }, thumbnail: thumbnail)
    }

    static func focus(name: String, symbol: String, tint: Tint, on: Bool) -> NotchAlert {
        NotchAlert(kind: .focus,
                   layout: .compact(text: on ? name : "\(name) Off", symbol: symbol,
                                    tint: on ? tint : .gray, value: nil, battery: nil),
                   duration: 2.5, maxAge: 10, action: .open(Pane.focus))
    }

    /// Alerts sent from Shortcuts or scripts through notchalerts:// links.
    static func custom(title: String, subtitle: String?, symbol: String, tint: Tint,
                       duration: TimeInterval, opens url: URL? = nil) -> NotchAlert {
        if let subtitle, !subtitle.isEmpty {
            return NotchAlert(kind: .custom,
                              layout: .card(symbol: symbol, tint: tint, title: title, subtitle: subtitle,
                                            subtitleTint: .gray, levels: []),
                              duration: duration, maxAge: 30, action: url.map { AlertAction.open($0) })
        }
        return NotchAlert(kind: .custom,
                          layout: .compact(text: title, symbol: symbol, tint: tint, value: nil, battery: nil),
                          duration: duration, maxAge: 30, action: url.map { AlertAction.open($0) })
    }
}

// MARK: - Helpers

/// Sizes shared by the alert views and the layout math.
enum Metrics {
    static let topRadius: CGFloat = 6         // boringNotch's closed-notch corner radii
    static let bottomRadius: CGFloat = 14
    static let cardTopRadius: CGFloat = 10
    static let cardBottomRadius: CGFloat = 22
    static let compactInset: CGFloat = 18     // keeps text clear of the curved corners
    static let cardWing: CGFloat = 118
    static let cardRowHeight: CGFloat = 56
    static let batteryWidth: CGFloat = 28
    static let fontSize: CGFloat = 12

    /// Space left empty over the physical notch (same as boringNotch).
    static func gap(_ notchWidth: CGFloat) -> CGFloat { notchWidth + 14 }

    /// Width of boringNotch's closed notch: the bare notch, or wider while its
    /// music live activity shows album art + bars (same math as boringNotch's layout:
    /// two square art/bar slots of notchHeight − 12, 8 pt spacing, 14 pt side padding).
    static func collapsedWidth(notchWidth: CGFloat, notchHeight: CGFloat, music: Bool) -> CGFloat {
        guard music else { return notchWidth + 2 * topRadius }
        return notchWidth + 2 * max(0, notchHeight - 12) + 42
    }

    static func size(for alert: NotchAlert, expanded: Bool, notchWidth: CGFloat, notchHeight: CGFloat,
                     collapsedWidth: CGFloat) -> CGSize {
        guard expanded else {
            // Collapsed = exactly boringNotch's current closed shape, so the alert grows out of it.
            return CGSize(width: collapsedWidth, height: notchHeight)
        }
        switch alert.layout {
        case .compact:
            let width = gap(notchWidth) + 2 * alert.compactWing + 2 * compactInset
            return CGSize(width: max(width, collapsedWidth + 24), height: notchHeight)
        case .card:
            return CGSize(width: max(notchWidth + 2 * cardWing, collapsedWidth + 24), height: notchHeight + cardRowHeight)
        }
    }
}

enum TextMeasure {
    static func width(_ text: String, size: CGFloat = Metrics.fontSize, weight: NSFont.Weight = .semibold) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
    }
}

/// SF Symbol names change between macOS versions; pick the first one that exists.
enum SymbolPicker {
    static func exists(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    static func first(_ candidates: [String], fallback: String) -> String {
        candidates.first(where: exists) ?? fallback
    }

    static func magicAccessory(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("mouse") { return first(["magicmouse.fill", "magicmouse"], fallback: "computermouse.fill") }
        if n.contains("trackpad") { return first(["rectangle.and.hand.point.up.left.fill"], fallback: "hand.point.up.left.fill") }
        if n.contains("keyboard") { return first(["keyboard.fill"], fallback: "keyboard") }
        return first(["keyboard.fill"], fallback: "keyboard")
    }

    static func headphones(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return first(["airpods.max", "airpodsmax"], fallback: "headphones") }
        if n.contains("airpods pro") { return first(["airpods.pro", "airpodspro"], fallback: "headphones") }
        if n.contains("airpods") { return first(["airpods"], fallback: "headphones") }
        if n.contains("beats") { return first(["beats.headphones"], fallback: "headphones") }
        if n.contains("speaker") || n.contains("boom") || n.contains("jbl") || n.contains("homepod") {
            return first(["hifispeaker.fill"], fallback: "headphones")
        }
        return "headphones"
    }
}
