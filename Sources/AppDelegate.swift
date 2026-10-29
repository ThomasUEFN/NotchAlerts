import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var lockMonitor: LockMonitor?
    private var batteryMonitor: BatteryMonitor?
    private var audioMonitor: AudioMonitor?
    private var networkMonitor: NetworkMonitor?
    private var accessoryMonitor: AccessoryMonitor?
    private var driveMonitor: DriveMonitor?
    private var displayMonitor: DisplayMonitor?
    private var airDropMonitor: AirDropMonitor?
    private var privacyIndicator: PrivacyIndicator?
    private var magicAccessoryMonitor: MagicAccessoryMonitor?
    private var screenshotMonitor: ScreenshotMonitor?
    private var focusMonitor: FocusMonitor?
    private var isPlayingDemo = false
    /// Keeps macOS from App-Napping this background app (which delays timers
    /// and makes animations stutter).
    private var activity: NSObjectProtocol?

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Shows notch alerts the moment something happens")
        Settings.register()
        SystemQuiet.start()
        BoringNotchWatcher.shared.start()
        MusicWatcher.shared.start()

        let center = AlertCenter.shared
        let post: (NotchAlert) -> Void = { center.post($0) }

        let lock = LockMonitor()
        lock.onLock = { center.screenLocked() }
        lock.onUnlock = { center.screenUnlocked() }
        lock.start()
        lockMonitor = lock

        let battery = BatteryMonitor()
        battery.onAlert = post
        battery.start()
        batteryMonitor = battery

        let audio = AudioMonitor()
        audio.onAlert = post
        audio.onUpdate = { center.update($0) }
        audio.start()
        audioMonitor = audio

        let network = NetworkMonitor()
        network.onAlert = post
        network.start()
        networkMonitor = network

        let accessories = AccessoryMonitor()
        accessories.onAlert = post
        accessories.start()
        accessoryMonitor = accessories

        let drives = DriveMonitor()
        drives.onAlert = post
        drives.onMount = { [weak accessories] in accessories?.driveMounted() }
        drives.start()
        driveMonitor = drives

        let displays = DisplayMonitor()
        displays.onAlert = post
        displays.start()
        displayMonitor = displays

        let airDrop = AirDropMonitor()
        airDrop.onAlert = post
        if Settings.isOn(.airdrop) { airDrop.start() }
        airDropMonitor = airDrop

        let magic = MagicAccessoryMonitor()
        magic.onAlert = post
        magic.start()
        magicAccessoryMonitor = magic

        let screenshots = ScreenshotMonitor()
        screenshots.onAlert = post
        if Settings.isOn(.screenshots) { screenshots.start() }
        screenshotMonitor = screenshots

        let focus = FocusMonitor()
        focus.onAlert = post
        focus.start()
        focusMonitor = focus

        let indicator = PrivacyIndicator()
        indicator.start()
        privacyIndicator = indicator

        setUpStatusItem()

        // First launch: show off every alert once.
        if !Settings.isOn(.didPlayWelcomeDemo) {
            Settings.set(.didPlayWelcomeDemo, true)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                self?.playDemo()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MusicWatcher.shared.stop()
    }

    /// Opening the app again (e.g. from Applications) brings back a hidden menu bar icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Settings.set(.hideMenuBarIcon, false)
        statusItem?.isVisible = true
        return false
    }

    /// notchalerts://show?title=…&subtitle=…&symbol=…&color=…&duration=…
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let alert = URLCommand.alert(from: url) { AlertCenter.shared.post(alert) }
        }
        // Opening a link activates the app; hand focus straight back.
        if NSApp.isActive { NSApp.hide(nil) }
    }

    private func playDemo() {
        guard !isPlayingDemo else { return }
        isPlayingDemo = true
        AlertCenter.shared.playDemo { [weak self] in
            self?.privacyIndicator?.demo()
            self?.isPlayingDemo = false
        }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let symbol = SymbolPicker.first(["rectangle.topthird.inset.filled", "bell.badge"], fallback: "bell")
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "NotchAlerts")
        image?.isTemplate = true
        item.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.isVisible = !Settings.isOn(.hideMenuBarIcon)
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let title = NSMenuItem(title: "NotchAlerts", action: nil, keyEquivalent: "")
        title.attributedTitle = NSAttributedString(string: "NotchAlerts",
                                                   attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        menu.addItem(title)
        menu.addItem(boringNotchItem())
        menu.addItem(.separator())

        menu.addItem(submenu("Alerts", alertsMenu()))
        menu.addItem(submenu("Fit to Notch", fitMenu()))
        menu.addItem(toggle("Grow From boringNotch's Music Art & Bars", .matchMusicWidth))

        menu.addItem(.separator())
        menu.addItem(action("Play Demo", #selector(demoClicked)))
        let previews = NSMenuItem(title: "Preview", action: nil, keyEquivalent: "")
        previews.submenu = previewMenu()
        menu.addItem(previews)
        menu.addItem(action("Copy Shortcuts Link Example", #selector(copyShortcutExample)))

        menu.addItem(.separator())
        let login = action("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(action("Hide Menu Bar Icon", #selector(hideMenuBarIcon)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit NotchAlerts", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func alertsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem.sectionHeader(title: "Power & Security"))
        menu.addItem(toggle("Lock & Unlock", .lock))
        menu.addItem(toggle("Low Battery (20%, 10%, 5%)", .lowBattery))
        menu.addItem(toggle("Charging — boringNotch shows this too", .charging))
        menu.addItem(toggle("Sound Muted / Unmuted", .sound))

        menu.addItem(NSMenuItem.sectionHeader(title: "Connections"))
        menu.addItem(toggle("AirPods & Headphones", .headphones))
        let battery = toggle("Show AirPods Battery", .headphoneBattery)
        battery.indentationLevel = 1
        menu.addItem(battery)
        menu.addItem(toggle("Magic Mouse, Keyboard & Trackpad", .magicAccessories))
        menu.addItem(toggle("iPhone & iPad", .appleDevices))
        menu.addItem(toggle("AirPlay", .airplay))
        menu.addItem(toggle("USB Accessories", .accessories))
        menu.addItem(toggle("Drives", .drives))
        menu.addItem(toggle("Displays", .displays))
        menu.addItem(toggle("AirDrop Received", .airdrop))
        menu.addItem(toggle("Screenshots", .screenshots))

        menu.addItem(NSMenuItem.sectionHeader(title: "Network & Privacy"))
        menu.addItem(toggle("Wi‑Fi On / Off", .wifi))
        menu.addItem(toggle("Internet Lost / Restored", .network))
        menu.addItem(toggle("Camera & Mic Dots", .privacyDots))
        if focusMonitor?.hasAccess == true {
            menu.addItem(toggle("Focus On / Off", .focus))
        } else {
            menu.addItem(action("Focus — Allow Full Disk Access…", #selector(openFullDiskAccess)))
        }
        return menu
    }

    private func fitMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(action("Taller by 1 Pixel", #selector(nudgeTaller)))
        menu.addItem(action("Shorter by 1 Pixel", #selector(nudgeShorter)))
        let nudge = Settings.heightNudge
        if nudge != 0 {
            menu.addItem(action("Reset (now \(nudge > 0 ? "+" : "")\(nudge) px)", #selector(resetNudge)))
        }
        menu.addItem(.separator())
        menu.addItem(toggle("Use Menu Bar Height", .matchMenuBarHeight))
        return menu
    }

    private func boringNotchItem() -> NSMenuItem {
        if BoringNotchWatcher.shared.isRunning {
            return NSMenuItem(title: "boringNotch is running ✓", action: nil, keyEquivalent: "")
        }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: BoringNotchWatcher.bundleID) != nil {
            return action("Open boringNotch", #selector(openBoringNotch))
        }
        return NSMenuItem(title: "boringNotch isn't installed", action: nil, keyEquivalent: "")
    }

    private func previewMenu() -> NSMenu {
        let menu = NSMenu()
        let items: [(String, String)] = [
            ("Lock & Unlock", "lock"), ("Low Battery", "lowBattery"), ("Charging", "charging"),
            ("Muted", "sound"), ("AirPods Connected", "headphones"), ("AirPlay", "airplay"),
            ("USB Accessory", "accessory"), ("Drive Connected", "drive"), ("Drive Ejected", "eject"),
            ("Display Connected", "display"), ("AirDrop Received", "airdrop"), ("Wi‑Fi Off", "wifi"),
            ("No Internet", "network"), ("Back Online", "online"), ("Shortcut Alert", "custom"),
            ("Magic Mouse Connected", "magic"), ("Magic Keyboard Low Battery", "magicLow"),
            ("iPhone Connected", "iphone"), ("Screenshot", "screenshot"), ("Focus On", "focus"),
            ("Camera & Mic Dots", "dots"),
        ]
        for (title, id) in items {
            let item = action(title, #selector(previewClicked(_:)))
            item.representedObject = id
            menu.addItem(item)
        }
        return menu
    }

    private func toggle(_ title: String, _ key: Settings.Key) -> NSMenuItem {
        let item = action(title, #selector(toggleClicked(_:)))
        item.representedObject = key.rawValue
        item.state = Settings.isOn(key) ? .on : .off
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: Menu actions

    @objc private func toggleClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = Settings.Key(rawValue: raw) else { return }
        let on = !Settings.isOn(key)
        Settings.set(key, on)
        switch key {
        case .airdrop:
            if on { airDropMonitor?.start() } else { airDropMonitor?.stop() }
        case .headphoneBattery:
            if on { BluetoothBattery.requestAccess() }
        case .privacyDots, .matchMusicWidth:
            privacyIndicator?.poll()
        case .screenshots:
            if on { screenshotMonitor?.start() } else { screenshotMonitor?.stop() }
        case .matchMenuBarHeight:
            fitChanged()
        default:
            break
        }
    }

    @objc private func previewClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let center = AlertCenter.shared
        let percent = BatteryMonitor.read()?.percent
        switch id {
        case "lock": center.previewLock()
        case "lowBattery": center.post(.lowBattery(min(percent ?? 20, 20)))
        case "charging": center.post(.charging(percent ?? 64))
        case "sound": center.post(.sound(muted: true))
        case "headphones": center.post(AudioMonitor.sampleHeadphones())
        case "airplay": center.post(.airplay(name: "Living Room"))
        case "accessory": center.post(.accessory(name: "USB-C Hub"))
        case "drive": center.post(.drive(name: "Backup Drive", ejected: false, network: false))
        case "eject": center.post(.drive(name: "Backup Drive", ejected: true, network: false))
        case "display": center.post(.display(name: "Studio Display", connected: true))
        case "airdrop": center.post(.airdrop(title: "IMG_2048.HEIC"))
        case "wifi": center.post(.wifi(on: false))
        case "network": center.post(.network(online: false))
        case "online": center.post(.network(online: true))
        case "custom":
            center.post(.custom(title: "Shortcut Ran", subtitle: nil, symbol: "checkmark.circle.fill",
                                tint: .green, duration: 3))
        case "dots": privacyIndicator?.demo()
        case "magic":
            let real = MagicAccessoryMonitor.accessories().first
            center.post(.magicAccessory(name: real?.name ?? "Magic Mouse", percent: real?.percent ?? 76, low: false))
        case "magicLow": center.post(.magicAccessory(name: "Magic Keyboard", percent: 9, low: true))
        case "iphone": center.post(.appleDevice(name: "iPhone"))
        case "screenshot": center.post(.screenshot(file: nil, recording: false, thumbnail: nil))
        case "focus": center.post(.focus(name: "Do Not Disturb", symbol: "moon.fill", tint: .purple, on: true))
        default: break
        }
    }

    @objc private func demoClicked() { playDemo() }

    // MARK: Fit to Notch

    @objc private func nudgeTaller() {
        Settings.heightNudge += 1
        fitChanged()
    }

    @objc private func nudgeShorter() {
        Settings.heightNudge -= 1
        fitChanged()
    }

    @objc private func resetNudge() {
        Settings.heightNudge = 0
        fitChanged()
    }

    /// Shows a sample so you can see the new fit right away.
    private func fitChanged() {
        privacyIndicator?.poll()
        AlertCenter.shared.showFitSample()
    }

    @objc private func openFullDiskAccess() {
        NSWorkspace.shared.open(Pane.fullDiskAccess)
        let alert = NSAlert()
        alert.messageText = "Allow Full Disk Access for Focus alerts"
        alert.informativeText = "Turn on NotchAlerts in the list (click + and pick it from Applications if it isn't there), then quit and reopen NotchAlerts. You'll need to do this again after rebuilding the app."
        NSApp.activate()
        alert.runModal()
    }

    @objc private func copyShortcutExample() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(URLCommand.example, forType: .string)
    }

    @objc private func openBoringNotch() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: BoringNotchWatcher.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("NotchAlerts: launch at login failed: \(error.localizedDescription)")
        }
    }

    @objc private func hideMenuBarIcon() {
        Settings.set(.hideMenuBarIcon, true)
        statusItem?.isVisible = false
        let alert = NSAlert()
        alert.messageText = "Menu bar icon hidden"
        alert.informativeText = "NotchAlerts keeps running. Open it again from your Applications folder to bring the icon back."
        NSApp.activate()
        alert.runModal()
    }
}

// MARK: - notchalerts:// links (for Shortcuts and scripts)

enum URLCommand {
    static let example = "notchalerts://show?title=Shortcut%20Ran&symbol=checkmark.circle.fill&color=green"

    static func alert(from url: URL) -> NotchAlert? {
        guard url.scheme?.lowercased() == "notchalerts" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name.lowercased() == name }?.value
        }

        let title = value("title") ?? value("text") ?? "Done"
        var symbol = "checkmark.circle.fill"
        if let requested = value("symbol") ?? value("icon"), SymbolPicker.exists(requested) {
            symbol = requested
        }
        let tint = Tint(rawValue: value("color")?.lowercased() ?? "") ?? .green
        var duration: TimeInterval = 3
        if let text = value("duration"), let seconds = Double(text) {
            duration = min(max(seconds, 1), 15)
        }
        let opens = value("url").flatMap { URL(string: $0) }
        return .custom(title: title, subtitle: value("subtitle"), symbol: symbol, tint: tint,
                       duration: duration, opens: opens)
    }
}
