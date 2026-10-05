import Foundation
import os

/// Every preference key the app understands. Each one can be set by MDM, by
/// a local admin config file, or by the user (Settings / CLI) — resolution
/// order lives in `PreferenceResolver`.
enum ManagedPreferenceKey: String, CaseIterable {
    case selectedWallpaperID
    case scale
    case fillColor
    case applyToAllScreens
    case lockSelection      // legacy; superseded by lockMode (still honored)
    case lockMode
    case allowLockExit
    case allowedWallpaperIDs
    case externalWallpaperFolderPath
    case showBundledWallpapers
    case showSystemWallpapers   // macOS built-in wallpapers source
    case allowSystemWallpaperDownloads  // gate the on-demand Apple CDN fetches
    case showFeaturedWallpaper
    case companyName            // org branding for the Managed source labels

    // Remote feeds (spec §4). Both gates default OFF — with no org folder
    // configured either, the app makes zero network requests (air-gap).
    case appCuratedEnabled
    case orgCatalogEnabled
    case orgCatalogURL
    case orgCatalogPublicKey

    // Primarily user-level keys (still admin-forceable — same rules).
    case personalFolderSource   // appManaged | userDefined (spec §5)
    case personalWallpaperFolderPath
    case favoriteWallpaperIDs
    case autoRotateEnabled
    case autoRotateIntervalMinutes
    case autoRotateShuffle
    case autoRotateOnWake
    case rotationPool           // unified rotation sources (spec §4)
    case appearanceTheme
    case gridColumns            // wallpaper grid density (2–4 columns)

    // Screen savers & Studio (spec §10).
    case screenSaverEnabled             // master switch; off = saver shows a solid color
    case showScreenSaversPage           // ScreenSavers page in the Library section
    case showStudio                     // Tools section / Studio
    case showStudioWallpapersTab
    case showStudioScreenSaverTab
    case allowScreenSaverCreation       // false = browse + Set Active only
    case activeScreenSaverSceneID       // scene the saver runs (UUID or "managed")
    case managedScreenSaverScene        // admin-provisioned scene (JSON string or inline object)
    case allowedScreenSaverSceneIDs     // optional allow-list for the active scene
    case enforcedScreenSaverPath        // saver to select for every Space/display (manage enforces)

    // Admin tools.
    case adminModeEnabled               // unlocks Studio › Package (deployable savers)

    // AI generation (Studio › Wallpapers). All default OFF; the master
    // switch hides every AI control regardless of the sub-toggles.
    case aiGenerationEnabled            // master switch
    case aiAppleOnDeviceEnabled         // Image Playground (Apple Intelligence, on-device)
    case aiLocalModelEnabled            // a local image-generation server
    case aiExternalModelEnabled         // a cloud image API (phase 4)
    case aiLocalModelEndpoint           // base URL, e.g. http://127.0.0.1:7860
    case aiLocalModelFlavor             // automatic1111 | openAICompatible
    case aiLocalModelName               // optional model/checkpoint name
    case aiLocalModelImageSize          // "WxH" asked of the server
    case aiExternalProvider             // google | openAI | openAICompatible
    case aiExternalEndpoint             // OpenAI-compatible only: base URL
    case aiExternalModelName            // optional model name (service default when empty)
    case aiExternalImageShape           // square | landscape | portrait
    case aiPromptImproverEnabled        // "Improve prompts with Claude"
    case aiPromptImproverModel          // optional Claude model ID (claude-opus-5-5 when empty)

    // Legacy rotation keys — read ONLY by RotationPoolMigration (spec §4).
    case autoRotateSource
    case rotateIncludeBundled
    case rotateIncludePersonal
    case rotateIncludeManaged
}

/// Pure layered lookup (unit-testable). Precedence, highest wins:
///   1) MDM profile forced   2) local "forced"   3) user value
///   4) local "defaults"     5) built-in default (callers' `??`)
struct PreferenceResolver {
    var mdmForcedValue: (String) -> Any?
    var userValue: (String) -> Any?
    var localForced: [String: Any]
    var localDefaults: [String: Any]

    func value(forKey key: String) -> Any? {
        if let value = mdmForcedValue(key) { return value }
        if let value = localForced[key] { return value }
        if let value = userValue(key) { return value }
        if let value = localDefaults[key] { return value }
        return nil
    }

    /// Forced = the user cannot override it (MDM or local "forced" layer).
    func isForced(_ key: String) -> Bool {
        mdmForcedValue(key) != nil || localForced[key] != nil
    }
}

/// Admin config for fleets without MDM (or air-gapped Macs):
/// `/Library/Application Support/PaperWalls/managed.json` (or `.plist`).
/// `forced` behaves exactly like an MDM-forced key (managed badge, blocks
/// user writes); `defaults` seeds a value the user may still override.
struct LocalManagedConfig {
    var forced: [String: Any] = [:]
    var defaults: [String: Any] = [:]

    static let empty = LocalManagedConfig()

    /// Accepts JSON or plist data shaped {"forced": {…}, "defaults": {…}}.
    static func parse(data: Data) -> LocalManagedConfig? {
        let object: Any
        if let json = try? JSONSerialization.jsonObject(with: data) {
            object = json
        } else if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            object = plist
        } else {
            return nil
        }
        guard let dict = object as? [String: Any] else { return nil }
        var config = LocalManagedConfig()
        config.forced = dict["forced"] as? [String: Any] ?? [:]
        config.defaults = dict["defaults"] as? [String: Any] ?? [:]
        return config
    }
}

/// Preference access for the GUI app, the CLI, and MDM profiles.
/// This is the ONLY way settings are read (spec principle #2) — a layered
/// resolver behind the original public API.
enum ManagedPreferences {
    /// The preference domain (equals the app's bundle identifier). Rename
    /// this one constant to rebrand; the Deployment/ files reference the
    /// same string.
    static let domain = "com.herojoneslabs.paperwalls"

    // FUTURE: route through PaperLog multi-sink (spec §9, deferred).
    static let log = Logger(subsystem: domain, category: "preferences")

    /// Local admin config location (admin-writable, world-readable).
    static let localConfigDirectory = "/Library/Application Support/PaperWalls"
    static let localConfigBasename = "managed"

    private static var domainCF: CFString { domain as CFString }

    // MARK: - Local config cache

    private static let cacheLock = NSLock()
    private static var cachedLocalConfig: LocalManagedConfig?

    static var localConfig: LocalManagedConfig {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cachedLocalConfig {
            return cached
        }
        let loaded = loadLocalConfig()
        cachedLocalConfig = loaded
        return loaded
    }

    /// Live reload: drop the cache so the next read re-parses the file.
    static func invalidateLocalConfigCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cachedLocalConfig = nil
    }

    private static func loadLocalConfig() -> LocalManagedConfig {
        for ext in ["json", "plist"] {
            let path = "\(localConfigDirectory)/\(localConfigBasename).\(ext)"
            guard FileManager.default.fileExists(atPath: path),
                  let data = FileManager.default.contents(atPath: path) else {
                continue
            }
            if let config = LocalManagedConfig.parse(data: data) {
                return config
            }
            log.error("Ignoring unparseable local config at \(path, privacy: .public)")
        }
        return .empty
    }

    // MARK: - Resolver

    private static var resolver: PreferenceResolver {
        let config = localConfig
        return PreferenceResolver(
            mdmForcedValue: { key in
                guard CFPreferencesAppValueIsForced(key as CFString, domainCF) else { return nil }
                return CFPreferencesCopyAppValue(key as CFString, domainCF)
            },
            userValue: { key in
                // User layer only (SetAppValue writes land here). Managed
                // values are layer 1; byHost user values are not consulted.
                CFPreferencesCopyValue(key as CFString, domainCF,
                                       kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            },
            localForced: config.forced,
            localDefaults: config.defaults
        )
    }

    // MARK: - Public API (unchanged shape)

    /// True when MDM or the local "forced" layer pins this key — local
    /// writes are ignored and the UI shows "Managed by your organization".
    static func isForced(_ key: ManagedPreferenceKey) -> Bool {
        resolver.isForced(key.rawValue)
    }

    /// The layered value for a key (nil → caller's built-in default).
    static func value(_ key: ManagedPreferenceKey) -> Any? {
        resolver.value(forKey: key.rawValue)
    }

    static func string(_ key: ManagedPreferenceKey) -> String? {
        value(key) as? String
    }

    static func bool(_ key: ManagedPreferenceKey) -> Bool? {
        (value(key) as? NSNumber)?.boolValue ?? (value(key) as? Bool)
    }

    static func int(_ key: ManagedPreferenceKey) -> Int? {
        (value(key) as? NSNumber)?.intValue ?? (value(key) as? Int)
    }

    static func stringArray(_ key: ManagedPreferenceKey) -> [String]? {
        value(key) as? [String]
    }

    /// Writes to the current user's preference layer. Dropped (with a log
    /// entry) when the key is forced by MDM or the local config.
    static func set(_ newValue: Any?, for key: ManagedPreferenceKey) {
        guard !isForced(key) else {
            log.info("Ignored write to managed key \(key.rawValue, privacy: .public)")
            return
        }
        if let newValue {
            CFPreferencesSetAppValue(key.rawValue as CFString, newValue as CFPropertyList, domainCF)
        } else {
            CFPreferencesSetAppValue(key.rawValue as CFString, nil, domainCF)
        }
        CFPreferencesAppSynchronize(domainCF)
    }
}
