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

extension ScreenSaverSnapshot {
    /// Pure resolution of what the saver should show (spec §10). `scenes`
    /// is every scene that exists (library + managed). The lookups are
    /// only consulted for the background the chosen scene actually uses.
    static func make(policy: ScreenSaverPolicy,
                     scenes: [StoredScreenSaver],
                     companyName: String,
                     assetsDirectory: String,
                     wallpaperPath: (String) -> String?,
                     rotationPaths: () -> [String]) -> ScreenSaverSnapshot {
        var snapshot = ScreenSaverSnapshot(state: .noneSelected,
                                           assetsDirectory: assetsDirectory,
                                           companyName: companyName)
        guard policy.enabled else {
            snapshot.state = .disabled
            return snapshot
        }
        guard policy.lockMode != .hard else {
            snapshot.state = .hardLock
            return snapshot
        }
        guard let activeID = policy.effectiveActiveID(availableIDs: scenes.map(\.id)),
              let stored = scenes.first(where: { $0.id == activeID }) else {
            return snapshot
        }
        return forScene(stored, companyName: companyName, assetsDirectory: assetsDirectory,
                        wallpaperPath: wallpaperPath, rotationPaths: rotationPaths)
    }

    /// An "active" snapshot for one specific scene, policy already decided —
    /// what a scene bundle carries, and what the active snapshot becomes.
    static func forScene(_ stored: StoredScreenSaver,
                         companyName: String,
                         assetsDirectory: String,
                         wallpaperPath: (String) -> String?,
                         rotationPaths: () -> [String]) -> ScreenSaverSnapshot {
        var snapshot = ScreenSaverSnapshot(state: .active,
                                           sceneID: stored.id,
                                           sceneName: stored.name,
                                           scene: stored.scene,
                                           assetsDirectory: assetsDirectory,
                                           companyName: companyName)
        switch stored.scene.background.source {
        case .wallpaper(let id):
            if let path = wallpaperPath(id) {
                snapshot.wallpaperPaths[id] = path
            }
        case .rotatingPool:
            snapshot.rotationPaths = rotationPaths()
        case .currentDesktop, .solid, .gradient, .unsupported:
            break
        }
        return snapshot
    }

    /// Headless resolution for the CLI (`manage`): every input read live
    /// through the preference layers, wallpapers drawn from `library`.
    static func makeFromPreferences(library: WallpaperLibrary, lockMode: LockMode) -> ScreenSaverSnapshot {
        let company = (ManagedPreferences.string(.companyName) ?? "").trimmingCharacters(in: .whitespaces)
        let managed = ScreenSaverSceneStore.managedScene(
            defaultName: "\(company.isEmpty ? "Company" : company) Screen Saver")
        return make(policy: .current(lockMode: lockMode),
                    scenes: (managed.map { [$0] } ?? []) + ScreenSaverSceneStore.loadAll(),
                    companyName: company,
                    assetsDirectory: ScreenSaverSceneStore.assetsDirectory().path,
                    wallpaperPath: { id in
                        library.wallpaper(withID: id).flatMap { library.fileURL(for: $0) }?.path
                    },
                    rotationPaths: {
                        RotationPool.resolveFromPreferences(library: library, lockMode: lockMode)
                            .compactMap { library.fileURL(for: $0)?.path }
                    })
    }
}

/// The scene being composed in Studio (spec §10): a working copy plus the
/// baseline it started from, so "unsaved changes" and Reset are exact.
struct SceneDraft: Equatable {
    /// The library entry being edited; nil until the draft is first saved.
    var sceneID: String?
    var name: String
    var scene: ScreenSaverScene

    private(set) var baselineName: String
    private(set) var baselineScene: ScreenSaverScene
    /// Set when the draft started from a built-in preset.
    private(set) var presetName: String?

    /// A new, not-yet-saved screen saver (blank or from a preset).
    init(newNamed name: String, scene: ScreenSaverScene, presetName: String? = nil) {
        self.sceneID = nil
        self.name = name
        self.scene = scene
        self.baselineName = name
        self.baselineScene = scene
        self.presetName = presetName
    }

    /// An existing library entry opened for editing.
    init(editing stored: StoredScreenSaver) {
        self.sceneID = stored.id
        self.name = stored.name
        self.scene = stored.scene
        self.baselineName = stored.name
        self.baselineScene = stored.scene
        self.presetName = nil
    }

    var isNew: Bool { sceneID == nil }

    /// Differs from what it started as (the preset, or the saved entry).
    var isDirty: Bool {
        name != baselineName || scene != baselineScene
    }

    /// A new draft can always be saved; an existing one only when changed.
    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (isNew || isDirty)
    }

    /// "Reset to Preset" for a preset-based draft, else "Revert to Saved".
    var resetLabel: String {
        isNew ? (presetName == nil ? "Reset" : "Reset to Preset") : "Revert to Saved"
    }

    mutating func reset() {
        name = baselineName
        scene = baselineScene
    }
}

/// Which Studio tabs exist (spec §10).
enum StudioTab: String, CaseIterable, Identifiable {
    case wallpapers
    case screenSaver
    /// Admin mode only: build deployable packages from library scenes.
    case package

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wallpapers: return "Wallpapers"
        case .screenSaver: return "ScreenSaver"
        case .package: return "Package"
        }
    }

    /// Pure hide logic. The ScreenSaver tab is the composer, so it is
    /// unavailable whenever creation is. Package follows admin mode alone —
    /// hiding Studio or turning off creation on an admin's Mac must not
    /// take packaging away. An empty result hides Studio (and the whole
    /// Tools section) entirely.
    static func visibleTabs(showStudio: Bool,
                            showWallpapersTab: Bool,
                            showScreenSaverTab: Bool,
                            canCreate: Bool,
                            adminMode: Bool = false) -> [StudioTab] {
        var tabs: [StudioTab] = []
        if showStudio {
            if showWallpapersTab { tabs.append(.wallpapers) }
            if showScreenSaverTab && canCreate { tabs.append(.screenSaver) }
        }
        if adminMode { tabs.append(.package) }
        return tabs
    }
}
