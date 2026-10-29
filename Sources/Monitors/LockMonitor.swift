import AppKit

/// Mac locked / unlocked (covers Touch ID, password and Apple Watch unlocks).
@MainActor
final class LockMonitor: NSObject {
    var onLock: (() -> Void)?
    var onUnlock: (() -> Void)?

    func start() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(screenLocked),
                           name: NSNotification.Name("com.apple.screenIsLocked"),
                           object: nil, suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(screenUnlocked),
                           name: NSNotification.Name("com.apple.screenIsUnlocked"),
                           object: nil, suspensionBehavior: .deliverImmediately)
    }

    @objc private func screenLocked() { onLock?() }
    @objc private func screenUnlocked() { onUnlock?() }
}
