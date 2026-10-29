import AppKit
import CoreAudio
import CoreMediaIO
import SwiftUI

/// Green dot while the camera is in use, orange dot while a microphone is,
/// shown in a small extension on the right side of the notch.
@MainActor
final class PrivacyIndicator {
    private let state: IndicatorState
    private let panel: NotchPanel
    private var watcher: MediaWatcher?
    private var hideTask: Task<Void, Never>?
    private var demoUntil = Date.distantPast
    private var cameraInUse = false
    private var microphoneInUse = false
    private var isShown = false

    init() {
        state = IndicatorState()
        panel = NotchPanel(levelAboveMenu: 4) // under alerts, above boringNotch
        let host = NSHostingView(rootView: PrivacyIndicatorView(state: state))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: NotchPanel.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    func start() {
        if let geometry = NotchGeometry.current() {
            panel.place(on: geometry)
            state.apply(geometry)
        }
        panel.orderFrontRegardless() // invisible until a dot is needed

        let watcher = MediaWatcher { [weak self] camera, microphone in
            Task { @MainActor in
                guard let self else { return }
                self.cameraInUse = camera
                self.microphoneInUse = microphone
                self.render()
            }
        }
        watcher.start()
        self.watcher = watcher
        BoringNotchWatcher.shared.addObserver { [weak self] in self?.render() }
        MusicWatcher.shared.addObserver { [weak self] in self?.render() }
    }

    /// Shows both dots for a few seconds (demo / preview).
    func demo() {
        demoUntil = Date().addingTimeInterval(4)
        render()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_200_000_000)
            self?.render()
        }
    }

    /// Re-applies the on/off setting.
    func poll() {
        render()
    }

    private func render() {
        let demo = Date() < demoUntil
        let enabled = Settings.isOn(.privacyDots)
        let camera = demo || (enabled && cameraInUse)
        let microphone = demo || (enabled && microphoneInUse)
        // Step aside while boringNotch is open.
        let shouldShow = (camera || microphone) && !BoringNotchWatcher.shared.shouldInterrupt

        if shouldShow, let geometry = NotchGeometry.current() {
            hideTask?.cancel()
            if !isShown {
                isShown = true
                panel.place(on: geometry)
                state.apply(geometry)
                state.camera = camera
                state.microphone = microphone
                state.isShown = true
                withAnimation(Anim.expand) { state.isExpanded = true }
            } else {
                // Follows boringNotch's music wings appearing / disappearing.
                withAnimation(Anim.morph) {
                    state.apply(geometry)
                    if state.camera != camera { state.camera = camera }
                    if state.microphone != microphone { state.microphone = microphone }
                }
            }
        } else if isShown {
            isShown = false
            withAnimation(Anim.collapse) { state.isExpanded = false }
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 380_000_000)
                guard let self, !Task.isCancelled else { return }
                self.state.isShown = false
            }
        }
    }
}

/// Gets told when any camera or microphone starts or stops (CoreMediaIO and
/// CoreAudio property listeners) instead of checking on a timer. A slow
/// 30-second check backs it up. Everything runs on its own queue.
final class MediaWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "NotchAlerts.media", qos: .utility)
    private let onChange: @Sendable (_ camera: Bool, _ microphone: Bool) -> Void
    private var watchedMicrophones: Set<AudioObjectID> = []
    private var watchedCameras: Set<CMIOObjectID> = []
    private var lastCamera: Bool?
    private var lastMicrophone: Bool?
    private var backupTimer: DispatchSourceTimer?

    init(onChange: @escaping @Sendable (_ camera: Bool, _ microphone: Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        queue.async { [self] in
            // New devices plugged in → watch them too.
            var audioDevices = AudioDevices.address(kAudioHardwarePropertyDevices)
            AudioObjectAddPropertyListenerBlock(AudioDevices.systemObject, &audioDevices, queue) { [weak self] _, _ in
                self?.refresh()
            }
            var cameraDevices = MediaUsage.devicesAddress
            CMIOObjectAddPropertyListenerBlock(MediaUsage.systemObject, &cameraDevices, queue) { [weak self] _, _ in
                self?.refresh()
            }

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
            timer.setEventHandler { [weak self] in self?.refresh() }
            timer.resume()
            backupTimer = timer

            refresh()
        }
    }

    /// Runs on `queue`.
    private func refresh() {
        watchNewDevices()
        let camera = MediaUsage.isCameraInUse()
        let microphone = AudioDevices.isAnyInputRunning()
        guard camera != lastCamera || microphone != lastMicrophone else { return }
        lastCamera = camera
        lastMicrophone = microphone
        onChange(camera, microphone)
    }

    private func watchNewDevices() {
        for id in AudioDevices.allDeviceIDs()
        where !watchedMicrophones.contains(id) && AudioDevices.hasStreams(id, kAudioDevicePropertyScopeInput) {
            var address = AudioDevices.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            let status = AudioObjectAddPropertyListenerBlock(id, &address, queue) { [weak self] _, _ in
                self?.refresh()
            }
            if status == noErr { watchedMicrophones.insert(id) }
        }
        for id in MediaUsage.cameraIDs() where !watchedCameras.contains(id) {
            var address = MediaUsage.runningAddress
            let status = CMIOObjectAddPropertyListenerBlock(id, &address, queue) { [weak self] _, _ in
                self?.refresh()
            }
            if status == noErr { watchedCameras.insert(id) }
        }
    }
}

enum MediaUsage {
    static var systemObject: CMIOObjectID { CMIOObjectID(kCMIOObjectSystemObject) }

    static var devicesAddress: CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(0)) // "main" element
    }

    static var runningAddress: CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
    }

    static func cameraIDs() -> [CMIOObjectID] {
        var addr = devicesAddress
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(systemObject, &addr, 0, nil, size, &used, &devices) == noErr else { return [] }
        return devices
    }

    /// True if any camera is streaming to any app. No permission needed.
    static func isCameraInUse() -> Bool {
        cameraIDs().contains { device in
            var addr = runningAddress
            var running: UInt32 = 0
            var used: UInt32 = 0
            let status = CMIOObjectGetPropertyData(device, &addr, 0, nil,
                                                   UInt32(MemoryLayout<UInt32>.size), &used, &running)
            return status == noErr && running != 0
        }
    }
}
