import AppKit
import ImageIO

/// "Screenshot saved", with a thumbnail. Watches the folder screenshots are
/// saved to (Desktop unless you changed it) and checks new files for the
/// screen-capture tag macOS adds. macOS asks once for access to that folder.
///
/// Note: with the floating thumbnail turned on (the default), macOS only
/// writes the file after that thumbnail slides away, so the alert follows it.
@MainActor
final class ScreenshotMonitor {
    var onAlert: ((NotchAlert) -> Void)?

    private var folder: URL
    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []

    init() {
        folder = Self.screenshotFolder()
    }

    func start() {
        guard source == nil else { return }
        folder = Self.screenshotFolder()
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

    /// Where macOS saves screenshots (System Settings → Screenshot options).
    static func screenshotFolder() -> URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    private func items() -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: folder.path)
    }

    private func folderChanged() {
        guard let list = items() else { return }
        let current = Set(list)
        let added = current.subtracting(known)
        known = current
        // macOS writes a hidden temp file first, then renames it.
        for name in added where !name.hasPrefix(".") {
            let file = folder.appendingPathComponent(name)
            guard Self.isScreenCapture(file.path) else { continue }
            let isRecording = ["mov", "mp4"].contains(file.pathExtension.lowercased())
            guard Settings.isOn(.screenshots) else { continue }
            if isRecording {
                onAlert?(.screenshot(file: file, recording: true, thumbnail: nil))
                continue
            }
            // Make the thumbnail off the main thread so animations stay smooth.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let thumbnail = ScreenshotMonitor.thumbnail(for: file)
                Task { @MainActor in
                    self?.onAlert?(.screenshot(file: file, recording: false, thumbnail: thumbnail))
                }
            }
        }
    }

    nonisolated static func isScreenCapture(_ path: String) -> Bool {
        getxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
    }

    nonisolated static func thumbnail(for file: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
