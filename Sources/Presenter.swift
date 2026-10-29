import AppKit
import SwiftUI

enum Anim {
    static let expand = Animation.spring(response: 0.4, dampingFraction: 0.76)
    static let collapse = Animation.spring(response: 0.32, dampingFraction: 0.92)
    static let quickCollapse = Animation.easeOut(duration: 0.16)
    static let morph = Animation.spring(response: 0.34, dampingFraction: 0.82)
    /// Content fades in just after the shape starts growing, and out quickly.
    static let contentIn = Animation.easeOut(duration: 0.22).delay(0.08)
    static let contentOut = Animation.easeOut(duration: 0.1)
}

/// Lets the first click on an alert work even though the panel never becomes key.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A click-through, transparent panel pinned to the top of the screen,
/// one level above boringNotch's own window (.mainMenu + 3).
final class NotchPanel: NSPanel {
    static let size = NSSize(width: 760, height: 240)

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask,
                  backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true   // hovering still reaches boringNotch underneath
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        acceptsMouseMovedEvents = true
    }

    convenience init(levelAboveMenu: Int) {
        self.init(contentRect: NSRect(origin: .zero, size: NotchPanel.size),
                  styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + levelAboveMenu)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Allow sitting over the menu bar / notch area.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func place(on geometry: NotchGeometry) {
        let size = NotchPanel.size
        setFrame(NSRect(x: geometry.notchMidX - size.width / 2,
                        y: geometry.screenFrame.maxY - size.height,
                        width: size.width, height: size.height),
                 display: false)
    }
}

@MainActor
final class AlertState: ObservableObject {
    @Published var alert: NotchAlert = .lock(unlocked: false)
    @Published var collapsedWidth: CGFloat = 197
    @Published var isShown = false
    @Published var isHovered = false
    /// Set by AlertCenter; called when a clickable alert is clicked.
    var onTap: (() -> Void)?
    @Published var isExpanded = false
    @Published var notchWidth: CGFloat = 185
    @Published var notchHeight: CGFloat = 32
    @Published var hasNotch = true

    func apply(_ geometry: NotchGeometry) {
        if notchWidth != geometry.notchWidth { notchWidth = geometry.notchWidth }
        if notchHeight != geometry.notchHeight { notchHeight = geometry.notchHeight }
        if hasNotch != geometry.hasNotch { hasNotch = geometry.hasNotch }
        let width = Metrics.collapsedWidth(notchWidth: geometry.notchWidth, notchHeight: geometry.notchHeight,
                                           music: MusicWatcher.shared.matchesMusicWidth)
        if collapsedWidth != width { collapsedWidth = width }
    }
}

@MainActor
final class IndicatorState: ObservableObject {
    @Published var camera = false
    @Published var microphone = false
    @Published var collapsedWidth: CGFloat = 197
    @Published var isShown = false
    @Published var isExpanded = false
    @Published var notchWidth: CGFloat = 185
    @Published var notchHeight: CGFloat = 32
    @Published var hasNotch = true

    func apply(_ geometry: NotchGeometry) {
        if notchWidth != geometry.notchWidth { notchWidth = geometry.notchWidth }
        if notchHeight != geometry.notchHeight { notchHeight = geometry.notchHeight }
        if hasNotch != geometry.hasNotch { hasNotch = geometry.hasNotch }
        let width = Metrics.collapsedWidth(notchWidth: geometry.notchWidth, notchHeight: geometry.notchHeight,
                                           music: MusicWatcher.shared.matchesMusicWidth)
        if collapsedWidth != width { collapsedWidth = width }
    }
}

/// Owns one alert window and animates alerts in and out of the notch.
///
/// The window stays on screen (transparent and click-through) between
/// alerts, so an alert starts animating on the very next frame instead of
/// waiting for a window to be created and composited.
@MainActor
final class AlertPresenter {
    let state: AlertState
    let showsOnLockScreen: Bool
    private let panel: NotchPanel
    private var hasRendered = false
    private var task: Task<Void, Never>?
    private var geometry: NotchGeometry?

    private(set) var isVisible = false
    /// Called after an alert has fully collapsed back into the notch.
    var onHidden: (() -> Void)?

    var isExpanded: Bool { isVisible && state.isExpanded }

    init(showsOnLockScreen: Bool = false) {
        self.showsOnLockScreen = showsOnLockScreen
        state = AlertState()
        panel = NotchPanel(levelAboveMenu: 5)
        let host = FirstClickHostingView(rootView: NotchAlertView(state: state))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: NotchPanel.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    /// Puts the (invisible) window on screen ahead of time.
    func prepare() {
        if let geometry = NotchGeometry.current() {
            panel.place(on: geometry)
            state.apply(geometry)
        }
        panel.orderFrontRegardless()
        hasRendered = true
    }

    /// Shows `alert`. If an alert is already up, morphs into the new one.
    /// `duration == nil` keeps it open until `hide()`.
    func show(_ alert: NotchAlert, on geometry: NotchGeometry, for duration: TimeInterval?) {
        task?.cancel()
        let waitForFirstFrame: Bool

        self.geometry = geometry
        if isVisible {
            waitForFirstFrame = false
            withAnimation(Anim.morph) {
                state.alert = alert
                state.isExpanded = true
            }
        } else {
            panel.place(on: geometry)
            state.apply(geometry)
            state.alert = alert
            state.isExpanded = false
            state.isShown = true
            waitForFirstFrame = !hasRendered
            if !panel.isVisible { panel.orderFrontRegardless() }
            if showsOnLockScreen { LockScreenSpace.shared.add(panel) }
            hasRendered = true
            isVisible = true
            if !waitForFirstFrame {
                // The collapsed notch is already on screen: grow out of it right away.
                withAnimation(Anim.expand) { state.isExpanded = true }
            }
        }

        task = Task { [weak self] in
            if waitForFirstFrame {
                // A brand-new window needs one frame at notch size first.
                try? await Task.sleep(nanoseconds: 16_000_000)
                guard let self, !Task.isCancelled else { return }
                withAnimation(Anim.expand) { self.state.isExpanded = true }
            }
            guard let duration else { return }
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.hide()
        }
    }

    /// Changes what's shown without restarting the timer.
    func update(_ alert: NotchAlert) {
        withAnimation(Anim.morph) { state.alert = alert }
    }

    /// Where the expanded alert is on screen (for clicks and hover).
    func alertFrame() -> CGRect? {
        guard isExpanded, let geometry else { return nil }
        let size = Metrics.size(for: state.alert, expanded: true, notchWidth: state.notchWidth,
                                notchHeight: state.notchHeight, collapsedWidth: state.collapsedWidth)
        return CGRect(x: geometry.notchMidX - size.width / 2, y: geometry.screenFrame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    /// The pointer moved onto / off a clickable alert: catch clicks only while
    /// it's on the alert, and keep the alert open while you're hovering it.
    func setPointerInside(_ inside: Bool) {
        panel.ignoresMouseEvents = !inside
        withAnimation(Anim.morph) { state.isHovered = inside }
        guard isVisible, state.isExpanded else { return }
        task?.cancel()
        if !inside {
            task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, !Task.isCancelled else { return }
                self.hide()
            }
        }
    }

    /// Re-applies the notch size (Fit menu) to an alert that's on screen.
    func refreshGeometry() {
        guard let geometry = NotchGeometry.current() else { return }
        self.geometry = geometry
        panel.place(on: geometry)
        withAnimation(Anim.morph) { state.apply(geometry) }
    }

    /// Collapses back into the notch. `fast` is for getting out of boringNotch's way.
    func hide(fast: Bool = false) {
        task?.cancel()
        guard isVisible else { return }
        panel.ignoresMouseEvents = true
        if state.isHovered { state.isHovered = false }
        if let geometry = NotchGeometry.current() { state.apply(geometry) }
        withAnimation(fast ? Anim.quickCollapse : Anim.collapse) { state.isExpanded = false }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: fast ? 180_000_000 : 380_000_000)
            guard let self, !Task.isCancelled else { return }
            self.state.isShown = false
            self.isVisible = false
            self.onHidden?()
        }
    }

    func hideImmediately() {
        task?.cancel()
        task = nil
        guard isVisible else { return }
        panel.ignoresMouseEvents = true
        state.isHovered = false
        state.isExpanded = false
        state.isShown = false
        isVisible = false
    }

    func close() {
        hideImmediately()
        onHidden = nil
        panel.orderOut(nil)
        panel.close()
    }
}

/// Puts a window into a SkyLight space that sits above the lock screen —
/// the same private-API trick boringNotch uses (via Lakr233/SkyLightWindow)
/// to show the notch while the Mac is locked.
@MainActor
final class LockScreenSpace {
    static let shared = LockScreenSpace()

    private typealias AddWindowsFn = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    private var connection: Int32 = 0
    private var space: Int32 = 0
    private var addWindows: AddWindowsFn?

    private init() {
        typealias MainConnectionFn = @convention(c) () -> Int32
        typealias SpaceCreateFn = @convention(c) (Int32, Int32, Int32) -> Int32
        typealias SetLevelFn = @convention(c) (Int32, Int32, Int32) -> Int32
        typealias ShowSpacesFn = @convention(c) (Int32, CFArray) -> Int32

        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW),
              let mainConnection = dlsym(handle, "SLSMainConnectionID"),
              let spaceCreate = dlsym(handle, "SLSSpaceCreate"),
              let setLevel = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
              let showSpaces = dlsym(handle, "SLSShowSpaces"),
              let add = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces")
        else { return }

        connection = unsafeBitCast(mainConnection, to: MainConnectionFn.self)()
        space = unsafeBitCast(spaceCreate, to: SpaceCreateFn.self)(connection, 1, 0)
        // 400 = kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock (above the lock screen)
        _ = unsafeBitCast(setLevel, to: SetLevelFn.self)(connection, space, 400)
        _ = unsafeBitCast(showSpaces, to: ShowSpacesFn.self)(connection, [space] as CFArray)
        addWindows = unsafeBitCast(add, to: AddWindowsFn.self)
    }

    func add(_ window: NSWindow) {
        guard let addWindows, space != 0, window.windowNumber > 0 else { return }
        _ = addWindows(connection, space, [window.windowNumber] as CFArray, 7)
    }
}
