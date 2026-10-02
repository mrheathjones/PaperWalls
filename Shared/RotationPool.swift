import Foundation

/// Members of the unified rotation pool (spec §4). Raw values are what the
/// `rotationPool` preference stores. `favorites` is special: it narrows the
/// pool to hearted wallpapers instead of contributing a source.
enum RotationPoolMember: String, CaseIterable, Identifiable {
    case favorites
    case bundled
    case system      // macOS built-in wallpapers
    case appCurated
    case orgRemote
    case orgFolder
    case personal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .favorites: return "Favorites"
        case .bundled: return "Bundled"
        case .system: return "macOS"
        case .appCurated: return "Curated Feed"
        case .orgRemote: return "Company Feed"
        case .orgFolder: return "Company Folder"
        case .personal: return "Personal"
        }
    }

    /// Built-in default when neither `rotationPool` nor any legacy rotation
    /// key is set: every real source (matches the old "All wallpapers"
    /// default). Source gates keep disabled feeds inert.
    static let defaultPool: [String] =
        [RotationPoolMember.bundled, .system, .appCurated, .orgRemote, .orgFolder, .personal].map(\.rawValue)
}

/// THE single source of truth for what rotation may draw from (spec §4):
/// the timer, "Up next", the pre-apply guard under enforced rotation, and
/// the Tier-3 watcher (spec §7) all resolve through here.
enum RotationPool {
    /// Pure resolution. `gates` holds the sources currently enabled
    /// (feed gate on, folder configured, …); members whose gate is off
    /// contribute nothing. `favorites` filters the assembled pool — or, as
    /// the sole member, selects hearted wallpapers across every gated
    /// source. `hard` pins the desktop (empty pool); `enforcedRotation`
    /// additionally intersects the allow-list. An empty result is the
    /// defined "Nothing to rotate" no-op: keep the current wallpaper.
    static func resolve(members rawMembers: [String],
                        gates: Set<RotationPoolMember>,
                        sources: [RotationPoolMember: [CuratedWallpaper]],
                        favorites: Set<String>,
                        lockMode: LockMode,
                        allowedIDs: [String]?) -> [CuratedWallpaper] {
        guard lockMode != .hard else { return [] }

        let members = rawMembers.compactMap(RotationPoolMember.init(rawValue:))
        let sourceMembers = members.filter { $0 != .favorites }
        let filterToFavorites = members.contains(.favorites)

        let drawFrom: [RotationPoolMember]
        if !sourceMembers.isEmpty {
            drawFrom = sourceMembers
        } else if filterToFavorites {
            // Favorites as the sole member: hearted wallpapers everywhere.
            drawFrom = RotationPoolMember.allCases.filter { $0 != .favorites }
        } else {
            drawFrom = []
        }

        // Duplicate content IDs can appear in more than one source.
        var seen = Set<String>()
        var pool = drawFrom
            .filter { gates.contains($0) }
            .flatMap { sources[$0] ?? [] }
            .filter { seen.insert($0.id).inserted }

        if filterToFavorites {
            pool = pool.filter { favorites.contains($0.id) }
        }

        if lockMode == .enforcedRotation, let allowedIDs, !allowedIDs.isEmpty {
            let allowed = Set(allowedIDs)
            pool = pool.filter { allowed.contains($0.id) }
        }
        return pool
    }
}

extension RotationPool {
    /// The configured pool through every layer (spec §4): still-forced
    /// legacy keys translate live; else the new key; else legacy user
    /// values (pre-migration safety net); else the built-in default.
    /// Single source of truth for the GUI store AND headless callers.
    static func effectiveConfiguredPool() -> (members: [String], forced: Bool) {
        if let forcedLegacy = RotationPoolMigration.forcedLegacyPool() {
            return (forcedLegacy, true)
        }
        if let configured = ManagedPreferences.stringArray(.rotationPool) {
            return (configured, ManagedPreferences.isForced(.rotationPool))
        }
        let derived = RotationPoolMigration.derive(
            source: ManagedPreferences.string(.autoRotateSource),
            includeBundled: ManagedPreferences.bool(.rotateIncludeBundled),
            includePersonal: ManagedPreferences.bool(.rotateIncludePersonal),
            includeManaged: ManagedPreferences.bool(.rotateIncludeManaged))
        return (derived ?? RotationPoolMember.defaultPool, false)
    }

    /// Headless resolution for the CLI (`manage`/`watch`): gates and inputs
    /// read live through the resolver, sources drawn from `library`.
    static func resolveFromPreferences(library: WallpaperLibrary,
                                       lockMode: LockMode) -> [CuratedWallpaper] {
        var gates: Set<RotationPoolMember> = []
        if ManagedPreferences.bool(.showBundledWallpapers) ?? true { gates.insert(.bundled) }
        if ManagedPreferences.bool(.showSystemWallpapers) ?? true { gates.insert(.system) }
        if !(ManagedPreferences.string(.externalWallpaperFolderPath) ?? "").isEmpty { gates.insert(.orgFolder) }
        if PersonalFolder.effectivePathFromPreferences() != nil { gates.insert(.personal) }
        if ManagedPreferences.bool(.appCuratedEnabled) == true { gates.insert(.appCurated) }
        if ManagedPreferences.bool(.orgCatalogEnabled) == true,
           RemoteFeed.org(urlString: ManagedPreferences.string(.orgCatalogURL),
                          publicKeyBase64: ManagedPreferences.string(.orgCatalogPublicKey)) != nil {
            gates.insert(.orgRemote)
        }
        let allowed = ManagedPreferences.stringArray(.allowedWallpaperIDs).map { ids in
            ids.map { library.wallpaper(withID: $0)?.id ?? $0 }
        }
        return resolve(members: effectiveConfiguredPool().members,
                       gates: gates,
                       sources: [.bundled: library.bundled,
                                 .system: library.system,
                                 .appCurated: library.appCurated,
                                 .orgRemote: library.orgRemote,
                                 .orgFolder: library.managed,
                                 .personal: library.personal],
                       favorites: Set(ManagedPreferences.stringArray(.favoriteWallpaperIDs) ?? []),
                       lockMode: lockMode,
                       allowedIDs: allowed)
    }
}

/// Pure rules for the Tier-3 watcher (spec §7): reversion, not prevention.
enum WatchPolicy {
    /// A desktop is compliant when its current picture path is one of the
    /// approved pool's files. An unreadable current picture counts as
    /// non-compliant — the watcher restores a known-good state.
    static func isCompliant(currentPath: String?, approvedPaths: Set<String>) -> Bool {
        guard let currentPath else { return false }
        return approvedPaths.contains(currentPath)
    }

    /// What to re-apply on drift: the last-approved selection if it's still
    /// in the pool (legacy ID aliases honored), else the pool's first entry.
    static func revertTarget(pool: [CuratedWallpaper], selectedID: String?) -> CuratedWallpaper? {
        if let selectedID,
           let selected = pool.first(where: { $0.id == selectedID || $0.legacyID == selectedID }) {
            return selected
        }
        return pool.first
    }
}

/// One-time migration from the legacy rotation keys (`autoRotateSource` +
/// `rotateIncludeBundled/Personal/Managed`) into `rotationPool` (spec §4).
/// The legacy keys are read HERE and nowhere else in the live model.
enum RotationPoolMigration {
    /// Pure mapping. nil = no legacy key was set (leave `rotationPool`
    /// unset so the built-in default applies). Per spec, migrated pools
    /// contain only the legacy sources — the new feed members join a pool
    /// when the user (or an admin) adds them, or via the fresh-install
    /// default.
    static func derive(source: String?,
                       includeBundled: Bool?,
                       includePersonal: Bool?,
                       includeManaged: Bool?) -> [String]? {
        switch source {
        case "favorites":
            return [RotationPoolMember.favorites.rawValue]
        case "managed":
            return [RotationPoolMember.orgFolder.rawValue]
        case "all", nil:
            guard source != nil || includeBundled != nil
                || includePersonal != nil || includeManaged != nil else {
                return nil
            }
            var pool: [String] = []
            if includeBundled ?? true { pool.append(RotationPoolMember.bundled.rawValue) }
            if includeManaged ?? true { pool.append(RotationPoolMember.orgFolder.rawValue) }
            if includePersonal ?? true { pool.append(RotationPoolMember.personal.rawValue) }
            return pool
        default:
            return nil   // unrecognized legacy value — don't guess
        }
    }

    /// Persists the derived pool to the user layer once. Returns true when
    /// something was written (callers reload their preference mirror).
    @discardableResult
    static func migrateIfNeeded() -> Bool {
        guard ManagedPreferences.stringArray(.rotationPool) == nil else { return false }
        guard let derived = derive(source: ManagedPreferences.string(.autoRotateSource),
                                   includeBundled: ManagedPreferences.bool(.rotateIncludeBundled),
                                   includePersonal: ManagedPreferences.bool(.rotateIncludePersonal),
                                   includeManaged: ManagedPreferences.bool(.rotateIncludeManaged)) else {
            return false
        }
        ManagedPreferences.set(derived, for: .rotationPool)
        return true
    }

    /// Forced-legacy translation (spec: "translate MDM-forced legacy keys
    /// into forced rotationPool where possible"): a profile still forcing
    /// the OLD keys yields a pool that overrides any user `rotationPool` —
    /// unless the profile forces `rotationPool` itself, which always wins.
    static func forcedLegacyPool() -> [String]? {
        guard !ManagedPreferences.isForced(.rotationPool) else { return nil }
        let sourceForced = ManagedPreferences.isForced(.autoRotateSource)
        let bundledForced = ManagedPreferences.isForced(.rotateIncludeBundled)
        let personalForced = ManagedPreferences.isForced(.rotateIncludePersonal)
        let managedForced = ManagedPreferences.isForced(.rotateIncludeManaged)
        guard sourceForced || bundledForced || personalForced || managedForced else { return nil }
        return derive(source: sourceForced ? ManagedPreferences.string(.autoRotateSource) : nil,
                      includeBundled: bundledForced ? ManagedPreferences.bool(.rotateIncludeBundled) : nil,
                      includePersonal: personalForced ? ManagedPreferences.bool(.rotateIncludePersonal) : nil,
                      includeManaged: managedForced ? ManagedPreferences.bool(.rotateIncludeManaged) : nil)
    }
}
