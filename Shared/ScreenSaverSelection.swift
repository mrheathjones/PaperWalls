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

// MARK: - macOS's clock over the saver

/// What PaperWalls does about the large clock macOS draws over every screen
/// saver — the "On Screen Saver" half of System Settings › Wallpaper ›
/// Clock Appearance › "Show large clock". A scene with its own clock layer
/// would otherwise show two clocks. Managed key `hideSystemSaverClock`.
enum SystemSaverClockPolicy: String, CaseIterable, Codable {
    /// Leave the setting to macOS and the user (default).
    case never
    /// Turn the clock off while a PaperWalls saver whose scene draws a
    /// clock is selected; put it back when that stops being true.
    case whenSceneHasClock
    /// Keep the clock off.
    case always

    var displayName: String {
        switch self {
        case .never: return "Leave to macOS"
        case .whenSceneHasClock: return "Hide when the scene has a clock"
        case .always: return "Always hide"
        }
    }
}

extension ScreenSaverScene {
    /// True when any layer draws a clock.
    var hasClock: Bool {
        layers.contains { layer in
            if case .clock = layer.content { return true }
            return false
        }
    }
}

/// macOS's "Show large clock › On Screen Saver" setting: `showClock` in
/// `com.apple.screensaver`, per user and per host (what ScreenSaverDefaults
/// and loginwindow read). The "On Lock Screen" half of the same popup is
/// `UsesLargeDateTime` in /Library/Preferences/com.apple.loginwindow —
/// system-level, admin-authenticated — and PaperWalls leaves it alone: the
/// saver's own clock isn't on screen there.
///
/// Everything that decides is pure; the preference layer is a `Store` so
/// tests never touch real settings. PaperWalls remembers the value it
/// replaced (per host, in its own domain) so a policy that stops applying
/// restores the user's choice, and never touches a value a profile forces.
enum SystemSaverClock {
    static let log = Logger(subsystem: ManagedPreferences.domain, category: "saverclock")
    static let domain = "com.apple.screensaver"
    static let key = "showClock"
    /// The value PaperWalls replaced ("true", "false", or "unset").
    static let restoreKey = "systemSaverClockRestore"

    struct Store {
        /// The user's own value (nil = unset; macOS then shows the clock).
        var showClock: () -> Bool?
        /// A profile forces the key, so it isn't PaperWalls' to change.
        var isForced: () -> Bool
        var setShowClock: (Bool?) -> Void
        var restoreValue: () -> String?
        var setRestoreValue: (String?) -> Void
    }

    static let live = Store(
        showClock: {
            (CFPreferencesCopyValue(key as CFString, domain as CFString,
                                    kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? NSNumber)?.boolValue
        },
        isForced: {
            CFPreferencesAppValueIsForced(key as CFString, domain as CFString)
        },
        setShowClock: { value in
            CFPreferencesSetValue(key as CFString, value.map { NSNumber(value: $0) }, domain as CFString,
                                  kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        },
        restoreValue: {
            CFPreferencesCopyValue(restoreKey as CFString, ManagedPreferences.domain as CFString,
                                   kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? String
        },
        setRestoreValue: { value in
            CFPreferencesSetValue(restoreKey as CFString, value as CFString?, ManagedPreferences.domain as CFString,
                                  kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            CFPreferencesSynchronize(ManagedPreferences.domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        })

    static func restoreToken(for value: Bool?) -> String {
        value.map { $0 ? "true" : "false" } ?? "unset"
    }

    static func restoredValue(from token: String) -> Bool? {
        switch token {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    // MARK: Deciding

    static func shouldHide(policy: SystemSaverClockPolicy, sceneHasClock: Bool) -> Bool {
        switch policy {
        case .never: return false
        case .whenSceneHasClock: return sceneHasClock
        case .always: return true
        }
    }

    enum Outcome: Equatable {
        /// A profile forces the key; nothing to do here.
        case managedByProfile
        /// Turned the clock off (and noted what it was).
        case hidden
        /// It was already off.
        case alreadyHidden
        /// The policy stopped applying: put back the value PaperWalls replaced.
        case restored(Bool?)
        /// Nothing to change.
        case leftAlone
    }

    /// Applies `policy` for the current user and host.
    @discardableResult
    static func apply(policy: SystemSaverClockPolicy, sceneHasClock: Bool, store: Store = live) -> Outcome {
        guard !store.isForced() else { return .managedByProfile }
        let current = store.showClock()
        if shouldHide(policy: policy, sceneHasClock: sceneHasClock) {
            if current == false { return .alreadyHidden }
            if store.restoreValue() == nil {
                store.setRestoreValue(restoreToken(for: current))
            }
            store.setShowClock(false)
            log.info("Hid the macOS screen saver clock (policy \(policy.rawValue, privacy: .public))")
            return .hidden
        }
        guard let token = store.restoreValue() else { return .leftAlone }
        store.setRestoreValue(nil)
        // Only undo PaperWalls' own change; a user who turned the clock back
        // on in the meantime keeps it.
        guard current == false else { return .leftAlone }
        let previous = restoredValue(from: token)
        store.setShowClock(previous)
        log.info("Restored the macOS screen saver clock to \(restoreToken(for: previous), privacy: .public)")
        return .restored(previous)
    }

    // MARK: Which scene is on screen

    /// The saver the policy looks at: the enforced one, else what macOS has
    /// selected — the system default entry (what System Settings updates
    /// on every click), else the most common choice across Spaces and
    /// displays. Nil when nothing is a screen saver choice.
    static func effectiveSaverPath(enforced: String?, store: [String: Any]?) -> String? {
        let enforced = (enforced ?? "").trimmingCharacters(in: .whitespaces)
        if !enforced.isEmpty { return enforced }
        guard let store, let entries = try? ScreenSaverSelection.idleEntries(in: store) else { return nil }
        if let systemDefault = entries.first(where: { $0.location == "SystemDefault" }) {
            return systemDefault.saverPath
        }
        var counts: [String: Int] = [:]
        for entry in entries {
            if let path = entry.saverPath { counts[path, default: 0] += 1 }
        }
        return counts.max { a, b in a.value < b.value || (a.value == b.value && a.key > b.key) }?.key
    }

    /// Where a saver's scene comes from; replaceable in tests.
    struct SceneSource {
        /// A scene bundle's own snapshot (Contents/Resources/PaperWallsScene.json).
        var bundledSnapshot: (String) -> ScreenSaverSnapshot?
        /// The main saver's input: the snapshot the app / manage publishes.
        var publishedSnapshot: () -> ScreenSaverSnapshot?
        /// True for any PaperWalls saver bundle (main, per-scene tile, deployed).
        var isPaperWallsSaver: (String) -> Bool

        static let live = SceneSource(
            bundledSnapshot: { path in
                ScreenSaverSnapshot.read(from: URL(fileURLWithPath: path)
                    .appendingPathComponent("Contents/Resources/\(ScreenSaverSnapshot.bundledFilename)"))
            },
            publishedSnapshot: { ScreenSaverSnapshot.read() },
            isPaperWallsSaver: { path in
                Bundle(path: path)?.bundleIdentifier?.hasPrefix("\(ManagedPreferences.domain).saver") == true
            })
    }

    /// Whether the saver at `path` draws its own clock. Mirrors what
    /// `PaperWallsSaverView` shows: a scene bundle's snapshot, else the
    /// published snapshot — and the built-in Minimal Clock when there is
    /// none yet. Non-PaperWalls savers never count.
    static func saverHasClock(at path: String?, source: SceneSource = .live) -> Bool {
        guard let path else { return false }
        if let bundled = source.bundledSnapshot(path) {
            return snapshotHasClock(bundled)
        }
        guard source.isPaperWallsSaver(path) else { return false }
        return source.publishedSnapshot().map(snapshotHasClock) ?? true
    }

    static func snapshotHasClock(_ snapshot: ScreenSaverSnapshot) -> Bool {
        switch snapshot.state {
        case .active: return snapshot.scene?.hasClock ?? true   // the saver falls back to Minimal Clock
        case .noneSelected: return true                          // built-in Minimal Clock
        case .disabled, .hardLock: return false                  // solid color
        }
    }

    // MARK: From preferences

    static var currentPolicy: SystemSaverClockPolicy {
        ManagedPreferences.string(.hideSystemSaverClock).flatMap(SystemSaverClockPolicy.init(rawValue:)) ?? .never
    }

    /// Resolves the policy and the on-screen scene from preferences and
    /// applies it. Cheap when the policy is `never`.
    @discardableResult
    static func applyFromPreferences(store: Store = live, source: SceneSource = .live)
        -> (policy: SystemSaverClockPolicy, outcome: Outcome) {
        let policy = currentPolicy
        var sceneHasClock = false
        if policy == .whenSceneHasClock {
            let enforced = ManagedPreferences.string(.enforcedScreenSaverPath)
            let wallpaperStore = (enforced ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                ? try? ScreenSaverSelection.readStore()
                : nil
            sceneHasClock = saverHasClock(at: effectiveSaverPath(enforced: enforced, store: wallpaperStore), source: source)
        }
        return (policy, apply(policy: policy, sceneHasClock: sceneHasClock, store: store))
    }

    /// One line for `paperwallscli screensaver`.
    static func statusDescription(store: Store = live) -> String {
        let policy = currentPolicy
        if store.isForced() {
            return "macOS clock: forced by a configuration profile (policy \(policy.rawValue) not applied)"
        }
        let shown = store.showClock() ?? true
        var line = "macOS clock: \(shown ? "shown" : "hidden") over the screen saver (policy \(policy.rawValue)"
        if !shown, store.restoreValue() != nil {
            line += "; hidden by PaperWalls"
        }
        return line + ")"
    }
}
