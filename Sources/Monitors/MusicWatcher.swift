import AppKit

/// Knows when boringNotch is showing its music "live activity" (album art on
/// the left of the notch, bars on the right), so alerts can grow out of that
/// wider shape instead of the bare notch.
///
/// It listens to the same now-playing feed boringNotch uses: the
/// mediaremote-adapter bundled inside boringNotch.app, run in "stream" mode.
/// The adapter only writes when playback changes, so it sits idle otherwise.
@MainActor
final class MusicWatcher {
    static let shared = MusicWatcher()

    /// boringNotch keeps the album art up this long after you pause (its default).
    private static let pauseGrace: UInt64 = 3_000_000_000

    private(set) var isLiveActivityShowing = false
    private var isPlaying = false
    private var adapter: Process?
    private var buffer = Data()
    private var idleTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var observers: [() -> Void] = []
    private var token: NSObjectProtocol?

    /// True when alerts should start from boringNotch's music width.
    var matchesMusicWidth: Bool {
        isLiveActivityShowing && BoringNotchWatcher.shared.isRunning && Settings.isOn(.matchMusicWidth)
    }

    func addObserver(_ observer: @escaping () -> Void) {
        observers.append(observer)
    }

    func start() {
        launch()
        // boringNotch opened (or installed) after us: start listening then.
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == BoringNotchWatcher.bundleID else { return }
            MainActor.assumeIsolated { self?.launch() }
        }
    }

    func stop() {
        retryTask?.cancel()
        adapter?.terminate()
        adapter = nil
    }

    private func launch() {
        guard adapter == nil,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: BoringNotchWatcher.bundleID)
        else { return }
        let script = app.appendingPathComponent("Contents/Resources/mediaremote-adapter.pl")
        let framework = app.appendingPathComponent("Contents/Frameworks/MediaRemoteAdapter.framework")
        guard FileManager.default.fileExists(atPath: script.path),
              FileManager.default.fileExists(atPath: framework.path) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, framework.path, "stream", "--debounce=150"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor in self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.adapterExited() }
        }
        do {
            try process.run()
            adapter = process
        } catch {
            NSLog("NotchAlerts: couldn't start boringNotch's now-playing adapter: \(error.localizedDescription)")
        }
    }

    private func adapterExited() {
        adapter = nil
        buffer.removeAll()
        setPlaying(false)
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            self?.launch()
        }
    }

    /// The adapter writes one JSON object per line.
    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return }
        let isDiff = object["diff"] as? Bool ?? false
        if let playing = payload["playing"] as? Bool {
            setPlaying(playing)
        } else if !isDiff {
            // A full update without "playing" means nothing is playing.
            setPlaying(false)
        }
    }

    private func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        idleTask?.cancel()
        if playing {
            setLiveActivity(true)
        } else {
            idleTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.pauseGrace)
                guard !Task.isCancelled else { return }
                self?.setLiveActivity(false)
            }
        }
    }

    private func setLiveActivity(_ showing: Bool) {
        guard showing != isLiveActivityShowing else { return }
        isLiveActivityShowing = showing
        observers.forEach { $0() }
    }
}
