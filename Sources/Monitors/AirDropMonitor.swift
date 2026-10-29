import Foundation

/// Files received over AirDrop. AirDrop saves into ~/Downloads and tags each
/// file with a quarantine attribute whose agent is "sharingd"; this watches
/// the folder and checks new files for that tag. macOS asks once for access
/// to Downloads.
@MainActor
final class AirDropMonitor {
    var onAlert: ((NotchAlert) -> Void)?

    private let folder: URL
    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []
    private var batch: [URL] = []
    private var batchTask: Task<Void, Never>?

    private static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial", "tmp"]

    init() {
        folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    func start() {
        guard source == nil else { return }
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        known = Set(items() ?? [])

        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        watcher.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.folderChanged() }
        }
        watcher.setCancelHandler { close(descriptor) }
        watcher.resume()
        source = watcher
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    /// nil until macOS grants access to Downloads.
    private func items() -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: folder.path)
    }

    private func folderChanged() {
        guard let list = items() else { return }
        let current = Set(list)
        let added = current.subtracting(known)
        known = current
        for name in added where !name.hasPrefix(".") {
            let ext = (name as NSString).pathExtension.lowercased()
            if Self.partialExtensions.contains(ext) { continue }
            let path = folder.appendingPathComponent(name).path
            // Skips old files (e.g. the whole folder showing up right after access is granted).
            guard Self.wasJustAdded(path) else { continue }
            Task { [weak self] in
                // The tag can land a moment after the file appears.
                for delay in [0.4, 1.0, 2.5] {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    if Self.isFromAirDrop(path) {
                        self?.received(URL(fileURLWithPath: path))
                        return
                    }
                }
            }
        }
    }

    private func received(_ file: URL) {
        guard Settings.isOn(.airdrop) else { return }
        batch.append(file)
        batchTask?.cancel()
        batchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled, let first = self.batch.first else { return }
            let count = self.batch.count
            self.batch.removeAll()
            // Click: one file → select it in Finder; several → open Downloads.
            if count == 1 {
                self.onAlert?(.airdrop(title: first.lastPathComponent, file: first))
            } else {
                self.onAlert?(NotchAlert.airdrop(title: "\(count) items", file: nil).opening(self.folder))
            }
        }
    }

    /// True if the file landed in the folder in the last two minutes.
    static func wasJustAdded(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let added = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate else { return true }
        return Date().timeIntervalSince(added) < 120
    }

    static func isFromAirDrop(_ path: String) -> Bool {
        let attribute = "com.apple.quarantine"
        let size = getxattr(path, attribute, nil, 0, 0, 0)
        guard size > 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, attribute, &buffer, size, 0, 0)
        guard read > 0 else { return false }
        let value = String(decoding: buffer.prefix(read), as: UTF8.self)
        return value.split(separator: ";").contains { $0 == "sharingd" || $0.localizedCaseInsensitiveContains("airdrop") }
    }
}
