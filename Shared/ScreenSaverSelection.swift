import Foundation
import os

/// Which screen saver macOS runs, and enforcing it (`enforcedScreenSaverPath`).
///
/// Since macOS 14 the selection lives in each user's wallpaper store,
/// `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`,
/// not in `com.apple.screensaver` — so the documented profile keys
/// (`moduleName` / `modulePath`) no longer select a third-party saver. The
/// store holds an "Idle" entry for the system default and for every Space,
/// display, and Space + display; System Settings only updates the ones for
/// where you clicked, so enforcing rewrites all of them.
///
/// The format is undocumented. Everything here is pure (dictionary in,
/// dictionary out) and refuses to touch an entry it doesn't recognize.
/// Observed on macOS 27:
///
///     Idle: { Content: { Choices: [{ Provider: "com.apple.wallpaper.choice.screen-saver",
///                                    Files: [],
///                                    Configuration: <bplist { module: { relative: "file:///…/X.saver" } }> }],
///                        EncodedOptionValues: <bplist { values: {} }>,
///                        Shuffle: "$null" },
///             LastSet: <date>, LastUse: <date> }
enum ScreenSaverSelection {
    static let log = Logger(subsystem: ManagedPreferences.domain, category: "saverselection")

    static let screenSaverProvider = "com.apple.wallpaper.choice.screen-saver"

    static var storeURL: URL {
        ScreenSaverSnapshot.realHomeDirectory
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    enum SelectionError: LocalizedError, Equatable {
        case unreadableStore
        case unexpectedFormat(String)
        case writeFailed(String)
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .unreadableStore:
                return "The wallpaper store couldn't be read"
            case .unexpectedFormat(let detail):
                return "The wallpaper store has an unrecognized layout (\(detail)); left unchanged"
            case .writeFailed(let detail):
                return "The wallpaper store couldn't be written: \(detail)"
            case .verificationFailed:
                return "The wallpaper store didn't hold the new selection after writing; the backup was restored"
            }
        }
    }

    /// One Idle entry: where it sits in the store, and what it selects.
    struct IdleEntry: Equatable {
        /// e.g. "SystemDefault", "Displays/<uuid>", "Spaces/<uuid>/Default"
        let location: String
        let provider: String?
        /// The saver's file path, for a screen-saver choice.
        let saverPath: String?
    }

    // MARK: - Module URL

    /// "file:///Library/Screen%20Savers/X.saver" — the form System Settings
    /// writes (no trailing slash, percent-encoded).
    static func moduleURLString(forSaverAt path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: false).absoluteString
    }

    static func saverPath(fromModuleURLString string: String) -> String? {
        guard let url = URL(string: string), url.isFileURL else { return nil }
        return url.standardizedFileURL.path
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
    }

    // MARK: - Reading

    /// Every Idle entry in the store, in a stable order.
    static func idleEntries(in store: [String: Any]) throws -> [IdleEntry] {
        var entries: [IdleEntry] = []
        try visitIdleEntries(in: store, location: "") { location, idle in
            entries.append(try describe(idle, at: location))
            return nil
        }
        return entries
    }

    private static func describe(_ idle: [String: Any], at location: String) throws -> IdleEntry {
        guard let content = idle["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]] else {
            throw SelectionError.unexpectedFormat("no Content.Choices at \(location)")
        }
        guard let choice = choices.first else {
            return IdleEntry(location: location, provider: nil, saverPath: nil)
        }
        let provider = choice["Provider"] as? String
        var saverPath: String?
        if provider == screenSaverProvider,
           let data = choice["Configuration"] as? Data,
           let configuration = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let module = configuration["module"] as? [String: Any],
           let relative = module["relative"] as? String {
            saverPath = Self.saverPath(fromModuleURLString: relative)
        }
        return IdleEntry(location: location, provider: provider, saverPath: saverPath)
    }

    /// True when every Idle entry already selects `saverPath`.
    static func isEnforced(_ saverPath: String, in store: [String: Any]) throws -> Bool {
        let entries = try idleEntries(in: store)
        return !entries.isEmpty && entries.allSatisfy { entry in
            entry.provider == screenSaverProvider && entry.saverPath.map { samePath($0, saverPath) } == true
        }
    }

    // MARK: - Enforcing

    /// The store with every Idle entry selecting `saverPath`, and how many
    /// entries changed. Entries that already select it are left as they are;
    /// everything that isn't an Idle entry (desktop pictures, unknown keys)
    /// is untouched. Throws, changing nothing, if any Idle entry has an
    /// unrecognized layout.
    static func enforcing(_ saverPath: String, in store: [String: Any],
                          now: Date = Date()) throws -> (store: [String: Any], changed: Int) {
        let content = try selectionContent(for: saverPath)
        var changed = 0
        let updated = try visitIdleEntries(in: store, location: "") { location, idle in
            let entry = try describe(idle, at: location)
            if entry.provider == screenSaverProvider, let current = entry.saverPath, samePath(current, saverPath) {
                return nil
            }
            var replaced = idle
            replaced["Content"] = content
            replaced["LastSet"] = now
            changed += 1
            return replaced
        }
        return (updated, changed)
    }

    /// The Content System Settings writes for a third-party saver.
    static func selectionContent(for saverPath: String) throws -> [String: Any] {
        let configuration: [String: Any] = ["module": ["relative": moduleURLString(forSaverAt: saverPath)]]
        let options: [String: Any] = ["values": [String: Any]()]
        return [
            "Choices": [[
                "Provider": screenSaverProvider,
                "Files": [Any](),
                "Configuration": try PropertyListSerialization.data(fromPropertyList: configuration,
                                                                     format: .binary, options: 0),
            ]],
            "EncodedOptionValues": try PropertyListSerialization.data(fromPropertyList: options,
                                                                       format: .binary, options: 0),
            "Shuffle": "$null",
        ]
    }

    /// Walks every dictionary holding an "Idle" dictionary (the system
    /// default, displays, Spaces, Space + display). `transform` returns a
    /// replacement Idle entry, or nil to keep it. Doesn't descend into the
    /// entries themselves.
    @discardableResult
    private static func visitIdleEntries(in node: [String: Any], location: String,
                                         _ transform: (String, [String: Any]) throws -> [String: Any]?) throws -> [String: Any] {
        var result = node
        if let idleValue = node["Idle"] {
            guard let idle = idleValue as? [String: Any] else {
                throw SelectionError.unexpectedFormat("Idle at \(location.isEmpty ? "/" : location) isn't a dictionary")
            }
            if let replacement = try transform(location.isEmpty ? "/" : location, idle) {
                result["Idle"] = replacement
            }
        }
        for key in node.keys.sorted() where key != "Idle" && key != "Desktop" {
            guard let child = node[key] as? [String: Any] else { continue }
            let childLocation = location.isEmpty ? key : "\(location)/\(key)"
            result[key] = try visitIdleEntries(in: child, location: childLocation, transform)
        }
        return result
    }

    // MARK: - Store file

    static func readStore(at url: URL = storeURL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let store = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw SelectionError.unreadableStore
        }
        return store
    }

    /// Where the store is copied before PaperWalls changes it.
    static var backupURL: URL {
        ScreenSaverSnapshot.realHomeDirectory
            .appendingPathComponent("Library/Application Support/PaperWalls/WallpaperStore-backup.plist")
    }

    enum Outcome: Equatable {
        /// Every Idle entry already selected the saver.
        case alreadyEnforced
        /// This many entries were rewritten.
        case enforced(changed: Int)
    }

    /// Makes `saverPath` the screen saver everywhere for the current user:
    /// backs up the store, rewrites it, reads it back to verify (restoring
    /// the backup if that fails), then restarts WallpaperAgent so it takes
    /// effect. A no-op when nothing needs to change.
    static func enforce(_ saverPath: String, storeURL: URL = storeURL, backupURL: URL = backupURL,
                        restartAgent: Bool = true) throws -> Outcome {
        let store = try readStore(at: storeURL)
        let (updated, changed) = try enforcing(saverPath, in: store)
        guard changed > 0 else { return .alreadyEnforced }

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.copyItem(at: storeURL, to: backupURL)
            let data = try PropertyListSerialization.data(fromPropertyList: updated, format: .binary, options: 0)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            throw SelectionError.writeFailed(error.localizedDescription)
        }

        guard let written = try? readStore(at: storeURL), (try? isEnforced(saverPath, in: written)) == true else {
            _ = try? fileManager.replaceItemAt(storeURL, withItemAt: backupURL, backupItemName: nil,
                                               options: .usingNewMetadataOnly)
            throw SelectionError.verificationFailed
        }
        log.info("Enforced screen saver \(saverPath, privacy: .public) on \(changed) entries")
        if restartAgent {
            restartWallpaperAgent()
        }
        return .enforced(changed: changed)
    }

    /// WallpaperAgent reads the store when it starts; launchd relaunches it.
    static func restartWallpaperAgent() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["WallpaperAgent"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
