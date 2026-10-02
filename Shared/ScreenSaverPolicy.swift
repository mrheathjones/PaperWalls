import Foundation

/// Everything that decides which screen saver may run and what the user
/// may change (spec §10) — pure, so the app, the CLI, and tests agree.
struct ScreenSaverPolicy: Equatable {
    /// `screenSaverEnabled` master switch.
    var enabled: Bool = true
    var lockMode: LockMode = .off
    /// `activeScreenSaverSceneID` as resolved through the preference layers.
    var activeID: String?
    /// True when a profile or the local config pins the active scene.
    var activeIDForced: Bool = false
    /// `allowedScreenSaverSceneIDs`; nil or empty allows every scene.
    var allowedIDs: [String]?
    /// `allowScreenSaverCreation`.
    var allowCreation: Bool = true

    /// Reads the live preference layers.
    static func current(lockMode: LockMode) -> ScreenSaverPolicy {
        ScreenSaverPolicy(enabled: ManagedPreferences.bool(.screenSaverEnabled) ?? true,
                          lockMode: lockMode,
                          activeID: ManagedPreferences.string(.activeScreenSaverSceneID),
                          activeIDForced: ManagedPreferences.isForced(.activeScreenSaverSceneID),
                          allowedIDs: ManagedPreferences.stringArray(.allowedScreenSaverSceneIDs),
                          allowCreation: ManagedPreferences.bool(.allowScreenSaverCreation) ?? true)
    }

    // MARK: - What may run

    /// The allow-list restricts which scenes may be ACTIVE; it never hides
    /// a scene from the library.
    func isAllowed(_ id: String) -> Bool {
        guard let allowedIDs, !allowedIDs.isEmpty else { return true }
        return allowedIDs.contains(id)
    }

    /// The scene the saver runs, or nil for "show nothing but a solid
    /// color". `availableIDs` is every scene that exists right now
    /// (library + managed).
    ///
    ///   * disabled, or `hard` lock → nil.
    ///   * `soft` lock → only the admin's choice applies: the forced
    ///     active ID, else the managed scene; with neither, the user's
    ///     current scene stays (frozen — they can't change it).
    ///   * otherwise → the active ID if it exists and is allowed.
    func effectiveActiveID(availableIDs: [String]) -> String? {
        guard enabled, lockMode != .hard else { return nil }
        let available = Set(availableIDs)

        if lockMode == .soft {
            if activeIDForced, let activeID, available.contains(activeID) {
                return activeID
            }
            if available.contains(ScreenSaverSceneStore.managedSceneID) {
                return ScreenSaverSceneStore.managedSceneID
            }
        }
        guard let activeID, available.contains(activeID), isAllowed(activeID) else { return nil }
        return activeID
    }

    // MARK: - What the user may change

    /// Create, edit, rename, delete. Off under a hard lock.
    var canCreate: Bool {
        allowCreation && lockMode != .hard
    }

    /// "Set as Active" on a card. Greyed out while the feature is off,
    /// the active scene is forced, or a soft/hard lock is in effect.
    func canSetActive(_ id: String) -> Bool {
        guard enabled, !activeIDForced else { return false }
        guard lockMode == .off || lockMode == .enforcedRotation else { return false }
        return isAllowed(id)
    }

    /// Why "Set as Active" is unavailable (tooltip), or nil when it isn't.
    func setActiveRefusalReason(_ id: String) -> String? {
        if !enabled { return "Screen savers are turned off" }
        if activeIDForced { return "The active screen saver is set by your organization" }
        if lockMode == .soft || lockMode == .hard { return "Screen saver selection is locked by your organization" }
        if !isAllowed(id) { return "Your organization doesn't allow this screen saver" }
        return nil
    }
}

/// Which Studio tabs exist (spec §10).
enum StudioTab: String, CaseIterable, Identifiable {
    case wallpapers
    case screenSaver

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wallpapers: return "Wallpapers"
        case .screenSaver: return "ScreenSaver"
        }
    }

    /// Pure hide logic. The ScreenSaver tab is the composer, so it is
    /// unavailable whenever creation is; an empty result hides Studio
    /// (and the whole Tools section) entirely.
    static func visibleTabs(showStudio: Bool,
                            showWallpapersTab: Bool,
                            showScreenSaverTab: Bool,
                            canCreate: Bool) -> [StudioTab] {
        guard showStudio else { return [] }
        var tabs: [StudioTab] = []
        if showWallpapersTab { tabs.append(.wallpapers) }
        if showScreenSaverTab && canCreate { tabs.append(.screenSaver) }
        return tabs
    }
}
