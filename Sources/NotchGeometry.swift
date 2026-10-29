import AppKit

/// Where the notch is, in global screen coordinates (origin bottom-left).
/// Uses the same measurements as boringNotch's closed notch so the two line up.
struct NotchGeometry {
    let screenFrame: CGRect
    let notchMidX: CGFloat
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let hasNotch: Bool

    /// Prefers the built-in display with a notch; otherwise the main display
    /// (where boringNotch draws its fake notch).
    static func current() -> NotchGeometry? {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return nil }

        if let screen = screens.first(where: { $0.safeAreaInsets.top > 0 }),
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            let height = Settings.isOn(.matchMenuBarHeight) && menuBar > 0 ? menuBar : screen.safeAreaInsets.top
            return NotchGeometry(
                screenFrame: screen.frame,
                // boringNotch centers on the screen, so do the same.
                notchMidX: screen.frame.midX,
                notchWidth: screen.frame.width - left.width - right.width,
                notchHeight: fitted(height, on: screen),
                hasNotch: true
            )
        }

        let menuBarHeight = primary.frame.maxY - primary.visibleFrame.maxY
        return NotchGeometry(
            screenFrame: primary.frame,
            notchMidX: primary.frame.midX,
            notchWidth: 185, // boringNotch's default fake-notch width
            notchHeight: fitted(menuBarHeight > 0 ? menuBarHeight : 24, on: primary),
            hasNotch: false
        )
    }

    /// Applies the Fit menu's fine-tuning and snaps to whole screen pixels so
    /// the bottom edge is crisp instead of a blurry half-pixel.
    private static func fitted(_ height: CGFloat, on screen: NSScreen) -> CGFloat {
        let scale = max(screen.backingScaleFactor, 1)
        let pixels = (height * scale).rounded() + CGFloat(Settings.heightNudge)
        return max(pixels, scale * 10) / scale
    }

    /// Hovering here opens boringNotch.
    var hoverZone: CGRect {
        CGRect(x: notchMidX - notchWidth / 2 - 40, y: screenFrame.maxY - notchHeight - 6,
               width: notchWidth + 80, height: notchHeight + 10)
    }

    /// The area boringNotch's open panel covers (640×190 plus a margin).
    var openZone: CGRect {
        CGRect(x: notchMidX - 350, y: screenFrame.maxY - 230, width: 700, height: 240)
    }
}

/// boringNotch has no API that reports whether it's open, so NotchAlerts
/// infers it: boringNotch opens when the pointer rests on the notch and
/// stays open until the pointer leaves its panel. It also flags the moments
/// boringNotch shows its own pop-ups (charging, volume HUD) so alerts don't
/// pile on top of them.
///
/// Event-driven: it only does work when the pointer moves, so it costs
/// nothing while the mouse is still.
@MainActor
final class BoringNotchWatcher {
    static let shared = BoringNotchWatcher()
    nonisolated static let bundleID = "theboringteam.boringnotch"

    private(set) var isRunning = false
    private(set) var isLikelyOpen = false
    /// boringNotch is showing one of its own pop-ups; visible alerts should step aside.
    private var popupUntil = Date.distantPast
    /// Something might make boringNotch pop up; hold new alerts briefly.
    private var holdUntil = Date.distantPast

    private var geometry = NotchGeometry.current()
    private var hoverStart: Date?
    private var dwellTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var mouseMonitor: Any?
    private var tokens: [NSObjectProtocol] = []
    private var observers: [() -> Void] = []
    private var pointerObservers: [() -> Void] = []
    private var lastBusy = false

    /// While the pointer is on a clickable alert, boringNotch can't see it
    /// (our window is on top), so it isn't opening.
    var isPointerOverAlert: () -> Bool = { false }
    private var lastInterrupt = false

    /// Don't start a new alert right now.
    var isBusy: Bool {
        isRunning && (isLikelyOpen || Date() < popupUntil || Date() < holdUntil)
    }

    /// An alert that's already on screen should get out of the way.
    var shouldInterrupt: Bool {
        isRunning && (isLikelyOpen || Date() < popupUntil)
    }

    /// Re-reads the notch size (after the Fit menu changes it).
    func refreshGeometry() {
        geometry = NotchGeometry.current()
    }

    /// `observer` runs whenever boringNotch opens, closes, or starts/stops a pop-up.
    func addObserver(_ observer: @escaping () -> Void) {
        observers.append(observer)
    }

    /// `observer` runs on every pointer move (used for clickable alerts).
    func addPointerObserver(_ observer: @escaping () -> Void) {
        pointerObservers.append(observer)
    }

    func start() {
        refreshRunning()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunning() }
            })
        }
        tokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.geometry = NotchGeometry.current() }
        })
        // Pointer movement anywhere on screen (mouse events need no permission).
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
    }

    /// boringNotch shows a charging / low-power pop-up when the power source changes.
    func powerSourceChanged() {
        popupUntil = max(popupUntil, Date().addingTimeInterval(4))
        notifyIfChanged()
        scheduleExpiryCheck()
    }

    /// boringNotch can replace the volume HUD; don't start alerts right on top of it.
    func volumeChanged() {
        holdUntil = max(holdUntil, Date().addingTimeInterval(0.8))
        notifyIfChanged()
        scheduleExpiryCheck()
    }

    /// Also called by AlertCenter for moves inside NotchAlerts' own window.
    func pointerMoved() {
        pointerObservers.forEach { $0() }
        checkPointer()
    }

    /// Re-evaluates "is boringNotch open?" from where the pointer is.
    /// `notify: false` updates the state without calling observers.
    func checkPointer(notify: Bool = true) {
        guard isRunning, let geometry else {
            isLikelyOpen = false
            hoverStart = nil
            if notify { notifyIfChanged() }
            return
        }
        if isPointerOverAlert() {
            hoverStart = nil
            dwellTask?.cancel()
            return
        }
        let mouse = NSEvent.mouseLocation
        // The common case: pointer nowhere near the notch and nothing open.
        if !isLikelyOpen, hoverStart == nil, !geometry.openZone.contains(mouse) { return }

        if geometry.hoverZone.contains(mouse) {
            if let start = hoverStart {
                // boringNotch opens after ~0.3 s of hovering; just passing over the notch doesn't count.
                if Date().timeIntervalSince(start) >= 0.2 { isLikelyOpen = true }
            } else {
                hoverStart = Date()
                // The pointer may stop moving, so check again once the hover delay has passed.
                dwellTask?.cancel()
                dwellTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    self?.checkPointer()
                }
            }
        } else {
            hoverStart = nil
            dwellTask?.cancel()
            if !geometry.openZone.contains(mouse) { isLikelyOpen = false }
        }
        if notify { notifyIfChanged() }
    }

    private func refreshRunning() {
        isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        if !isRunning {
            isLikelyOpen = false
            hoverStart = nil
        }
        notifyIfChanged()
    }

    /// Tells observers when a pop-up hold runs out.
    private func scheduleExpiryCheck() {
        let wait = max(popupUntil, holdUntil).timeIntervalSinceNow
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000) + 20_000_000)
            guard !Task.isCancelled else { return }
            self?.notifyIfChanged()
        }
    }

    private func notifyIfChanged() {
        let busy = isBusy
        let interrupt = shouldInterrupt
        if busy != lastBusy || interrupt != lastInterrupt {
            lastBusy = busy
            lastInterrupt = interrupt
            observers.forEach { $0() }
        }
    }
}
