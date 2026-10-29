import AppKit

/// Queues alerts and shows them one at a time. Waits while boringNotch is
/// open (or showing its own pop-up) and steps aside if it opens mid-alert.
@MainActor
final class AlertCenter {
    static let shared = AlertCenter()

    private struct Pending {
        var alert: NotchAlert
        var date: Date
        var requeued = false
    }

    private let presenter: AlertPresenter
    private var current: Pending?
    private var pending: [Pending] = []
    private var pollTimer: Timer?
    private var drainActions: [() -> Void] = []

    private var isLocked = false
    private var lockPresenter: AlertPresenter?
    private var lockTask: Task<Void, Never>?

    private var isPointerOverAlert = false
    private var localMouseMonitor: Any?

    private init() {
        presenter = AlertPresenter()
        presenter.prepare()
        presenter.onHidden = { [weak self] in
            self?.current = nil
            self?.isPointerOverAlert = false
            self?.pump()
        }
        BoringNotchWatcher.shared.addObserver { [weak self] in
            self?.tick()
        }

        // Clickable alerts: follow the pointer (moves over other apps come from the
        // watcher; moves over our own window come from the local monitor).
        presenter.state.onTap = { [weak self] in self?.alertClicked() }
        BoringNotchWatcher.shared.addPointerObserver { [weak self] in self?.pointerMoved() }
        BoringNotchWatcher.shared.isPointerOverAlert = { [weak self] in self?.isPointerOverAlert ?? false }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }
    }

    // MARK: Clicking

    private func pointerMoved() {
        let over = presenter.isExpanded
            && current?.alert.action != nil
            && (presenter.alertFrame()?.contains(NSEvent.mouseLocation) ?? false)
        guard over != isPointerOverAlert else { return }
        isPointerOverAlert = over
        presenter.setPointerInside(over)
    }

    private func alertClicked() {
        guard let action = current?.alert.action else { return }
        isPointerOverAlert = false
        presenter.hide()
        switch action {
        case let .open(url):
            NSWorkspace.shared.open(url)
        case let .reveal(url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .unmute:
            AudioDevices.setMuted(false)
        }
    }

    /// Fit menu: apply the new size and show a sample to compare against the notch.
    func showFitSample() {
        refreshGeometry()
        guard !presenter.isVisible, pending.isEmpty else { return }
        post(.custom(title: "Fit Check", subtitle: nil,
                     symbol: SymbolPicker.first(["ruler"], fallback: "checkmark"),
                     tint: .white, duration: 4))
    }

    /// Fit menu changed the notch size: update anything on screen.
    func refreshGeometry() {
        BoringNotchWatcher.shared.refreshGeometry()
        if presenter.isVisible { presenter.refreshGeometry() }
    }

    // MARK: Posting

    func post(_ alert: NotchAlert) {
        // For alerts that describe a state (battery %, mute, Wi‑Fi…), the newest one wins.
        if [.lowBattery, .charging, .sound, .wifi, .network].contains(alert.kind) {
            pending.removeAll { $0.alert.kind == alert.kind }
            if presenter.isExpanded, current?.alert.kind == alert.kind,
               !BoringNotchWatcher.shared.shouldInterrupt,
               let geometry = NotchGeometry.current() {
                current = Pending(alert: alert, date: Date())
                presenter.show(alert, on: geometry, for: alert.duration)
                return
            }
        }
        pending.append(Pending(alert: alert, date: Date()))
        pump()
    }

    /// Swaps in a newer version of an alert that's on screen or still queued
    /// (e.g. AirPods battery levels that arrive after the alert started).
    func update(_ alert: NotchAlert) {
        if presenter.isVisible, let shown = current,
           shown.alert.kind == alert.kind, shown.alert.title == alert.title {
            current?.alert = alert
            presenter.update(alert)
        } else if let index = pending.firstIndex(where: { $0.alert.kind == alert.kind && $0.alert.title == alert.title }) {
            pending[index].alert = alert
        }
    }

    /// Plays every alert once, one after another (first launch + "Play Demo").
    func playDemo(then finish: @escaping () -> Void) {
        previewLock()
        let samples: [NotchAlert] = [
            .lowBattery(20),
            .charging(64),
            .sound(muted: true),
            AudioMonitor.sampleHeadphones(),
            .airplay(name: "Living Room"),
            .accessory(name: "USB-C Hub"),
            .drive(name: "Backup Drive", ejected: false, network: false),
            .display(name: "Studio Display", connected: true),
            .airdrop(title: "IMG_2048.HEIC"),
            .magicAccessory(name: "Magic Mouse", percent: 76, low: false),
            .appleDevice(name: "iPhone"),
            .screenshot(file: nil, recording: false, thumbnail: nil),
            .focus(name: "Do Not Disturb", symbol: "moon.fill", tint: .purple, on: true),
            .wifi(on: false),
            .network(online: false),
            .custom(title: "Shortcut Ran", subtitle: nil, symbol: "checkmark.circle.fill",
                    tint: .green, duration: 2.4),
        ]
        for var alert in samples {
            alert.duration = min(alert.duration, 2.4)
            alert.maxAge = 900
            pending.append(Pending(alert: alert, date: Date()))
        }
        drainActions.append(finish)
        pump()
    }

    // MARK: Queue

    private func pump() {
        guard !isLocked, lockPresenter == nil, !presenter.isVisible else { return }
        let now = Date()
        pending.removeAll { now.timeIntervalSince($0.date) > $0.alert.maxAge }

        guard !pending.isEmpty else {
            let actions = drainActions
            drainActions = []
            actions.forEach { $0() }
            updatePolling()
            return
        }
        // boringNotch is open or mid pop-up: keep waiting (the poll timer retries).
        guard !BoringNotchWatcher.shared.isBusy, let geometry = NotchGeometry.current() else {
            updatePolling()
            return
        }
        let next = pending.removeFirst()
        current = next
        presenter.show(next.alert, on: geometry, for: next.alert.duration)
        updatePolling()
    }

    private func tick() {
        // Backup for the pointer events: refresh while an alert is queued or on screen.
        pointerMoved()
        BoringNotchWatcher.shared.checkPointer(notify: false)
        if presenter.isExpanded, !isPointerOverAlert, BoringNotchWatcher.shared.shouldInterrupt {
            // boringNotch just opened: get out of the way and come back afterwards.
            if var interrupted = current, !interrupted.requeued {
                interrupted.requeued = true
                interrupted.date = Date()
                pending.insert(interrupted, at: 0)
            }
            current = nil
            presenter.hide(fast: true)
        } else if !presenter.isVisible {
            pump()
        }
        updatePolling()
    }

    private func updatePolling() {
        let needed = !pending.isEmpty || presenter.isVisible
        if needed, pollTimer == nil {
            // Only runs while an alert is queued or showing.
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        } else if !needed, let timer = pollTimer {
            timer.invalidate()
            pollTimer = nil
        }
    }

    // MARK: Lock & unlock

    func screenLocked() {
        isLocked = true
        lockTask?.cancel()
        if presenter.isVisible {
            if let interrupted = current { pending.insert(interrupted, at: 0) }
            current = nil
            isPointerOverAlert = false
            presenter.hideImmediately()
        }
        guard Settings.isOn(.lock), let geometry = NotchGeometry.current() else { return }
        if let existing = lockPresenter, !existing.showsOnLockScreen {
            existing.close()
            lockPresenter = nil
        }
        let lockAlert = lockPresenter ?? AlertPresenter(showsOnLockScreen: true)
        lockPresenter = lockAlert
        lockAlert.onHidden = nil
        lockAlert.show(.lock(unlocked: false), on: geometry, for: 2.5)
    }

    func screenUnlocked() {
        isLocked = false
        lockTask?.cancel()
        guard Settings.isOn(.lock),
              !BoringNotchWatcher.shared.shouldInterrupt,
              let geometry = NotchGeometry.current() else {
            endLockSequence()
            return
        }
        let lockAlert = lockPresenter ?? AlertPresenter(showsOnLockScreen: true)
        lockPresenter = lockAlert
        playUnlock(on: lockAlert, geometry: geometry)
    }

    /// Lock → unlock animation without actually locking (menu preview + demo).
    func previewLock() {
        guard !isLocked, lockPresenter == nil, let geometry = NotchGeometry.current() else { return }
        if presenter.isVisible {
            if let interrupted = current { pending.insert(interrupted, at: 0) }
            current = nil
            isPointerOverAlert = false
            presenter.hideImmediately()
        }
        let lockAlert = AlertPresenter()
        lockPresenter = lockAlert
        playUnlock(on: lockAlert, geometry: geometry)
    }

    private func playUnlock(on lockAlert: AlertPresenter, geometry: NotchGeometry) {
        lockAlert.onHidden = { [weak self] in self?.endLockSequence() }
        lockAlert.show(.lock(unlocked: false), on: geometry, for: nil)
        lockTask = Task { [weak lockAlert] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard let lockAlert, !Task.isCancelled else { return }
            lockAlert.update(.lock(unlocked: true))   // padlock springs open
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            lockAlert.hide()
        }
    }

    private func endLockSequence() {
        lockTask?.cancel()
        lockTask = nil
        lockPresenter?.close()
        lockPresenter = nil
        pump()
    }
}
