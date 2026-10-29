import Foundation

/// Focus mode turned on / off (Do Not Disturb, Work, Sleep…).
///
/// macOS has no public API for this, so it reads the Focus database in
/// ~/Library/DoNotDisturb, which needs Full Disk Access. Without it this
/// monitor simply stays off. It reacts to changes in that folder; it never polls.
/// Focus turned on by a schedule may not show up; manual changes do.
@MainActor
final class FocusMonitor {
    var onAlert: ((NotchAlert) -> Void)?
    private(set) var hasAccess = false

    private enum FocusState: Equatable {
        case off
        case on(id: String, name: String, symbol: String, tint: Tint)
    }

    private let folder: URL
    private var source: DispatchSourceFileSystemObject?
    private var last: FocusState?
    private var debounce: Task<Void, Never>?

    private var assertionsFile: URL { folder.appendingPathComponent("Assertions.json") }
    private var modesFile: URL { folder.appendingPathComponent("ModeConfigurations.json") }

    init() {
        folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true)
    }

    func start() {
        guard source == nil else { return }
        last = read()
        hasAccess = last != nil
        guard hasAccess else { return }

        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                                eventMask: [.write, .attrib, .extend],
                                                                queue: .main)
        watcher.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.folderChanged() }
        }
        watcher.setCancelHandler { close(descriptor) }
        watcher.resume()
        source = watcher
    }

    private func folderChanged() {
        // Focus writes several files in a row; read once they've settled.
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled, let now = self.read(), now != self.last else { return }
            let previous = self.last
            self.last = now
            guard Settings.isOn(.focus) else { return }
            switch now {
            case let .on(_, name, symbol, tint):
                self.onAlert?(.focus(name: name, symbol: symbol, tint: tint, on: true))
            case .off:
                if case let .on(_, name, symbol, _)? = previous {
                    self.onAlert?(.focus(name: name, symbol: symbol, tint: .gray, on: false))
                }
            }
        }
    }

    /// nil = couldn't read (no Full Disk Access).
    private func read() -> FocusState? {
        guard let data = try? Data(contentsOf: assertionsFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let entries = json["data"] as? [[String: Any]] ?? []
        let records = entries.first?["storeAssertionRecords"] as? [[String: Any]] ?? []
        guard let details = records.last?["assertionDetails"] as? [String: Any],
              let id = details["assertionDetailsModeIdentifier"] as? String else { return .off }
        let mode = modeInfo(id)
        return .on(id: id, name: mode.name, symbol: mode.symbol, tint: mode.tint)
    }

    private func modeInfo(_ id: String) -> (name: String, symbol: String, tint: Tint) {
        var name = id.contains("donotdisturb.mode.default") ? "Do Not Disturb" : "Focus"
        var symbol = "moon.fill"
        var tint = Tint.purple
        if let data = try? Data(contentsOf: modesFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let entries = json["data"] as? [[String: Any]],
           let configs = entries.first?["modeConfigurations"] as? [String: Any],
           let config = configs[id] as? [String: Any],
           let mode = config["mode"] as? [String: Any] {
            if let value = mode["name"] as? String, !value.isEmpty { name = value }
            if let value = mode["symbolImageName"] as? String, SymbolPicker.exists(value) { symbol = value }
            if let value = (mode["tintColorName"] as? String)?.lowercased() {
                tint = Self.tint(from: value)
            }
        }
        return (name, symbol, tint)
    }

    private static func tint(from name: String) -> Tint {
        if name.contains("indigo") || name.contains("purple") { return .purple }
        if name.contains("blue") || name.contains("teal") || name.contains("cyan") { return .blue }
        if name.contains("green") || name.contains("mint") { return .green }
        if name.contains("orange") || name.contains("brown") { return .orange }
        if name.contains("yellow") { return .yellow }
        if name.contains("pink") { return .pink }
        if name.contains("red") { return .red }
        return .purple
    }
}
