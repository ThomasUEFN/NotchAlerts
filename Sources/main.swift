import AppKit

// NotchAlerts — Dynamic Island–style alerts for the MacBook notch, built to sit
// alongside boringNotch. Everything in the app runs on the main thread.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
