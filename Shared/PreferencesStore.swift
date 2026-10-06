import Combine
import Foundation

/// Window appearance (Settings → Theme). `system` follows the macOS
/// Light/Dark setting.
enum AppearanceTheme: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }
}

/// Observable mirror of the preference domain for SwiftUI.
///
/// Reads see the merged managed + user value (managed wins). Edits to the
/// published properties are persisted to the user layer via CFPreferences;
/// writes to keys forced by an MDM profile are dropped by ManagedPreferences
/// and the property snaps back on the next reload. Controls bound to forced
/// keys are disabled in the UI, so that path is a safety net, not the norm.
final class PreferencesStore: ObservableObject {
    @Published var selectedWallpaperID: String?
    @Published var scale: WallpaperScale = .fill
    @Published var fillColorHex: String = ""
    @Published var applyToAllScreens: Bool = true
    @Published var lockSelection: Bool = false
    @Published var lockMode: LockMode = .off
    @Published var allowLockExit: Bool = true
    @Published var allowedWallpaperIDs: [String]?
    @Published var externalWallpaperFolderPath: String = ""
    @Published var showBundledWallpapers: Bool = true
    @Published var showSystemWallpapers: Bool = true
    /// Gate for the on-demand macOS wallpaper downloads (Apple CDN).
    /// Admins force false on network-restricted fleets.
    @Published var allowSystemWallpaperDownloads: Bool = true
    @Published var showFeaturedWallpaper: Bool = true
    /// Org branding: replaces "Company"/"Managed" wording in the UI.
    @Published var companyName: String = ""

    /// "Company" unless the admin (or user) set a real name.
    var companyDisplayName: String {
        let trimmed = companyName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Company" : trimmed
    }
    @Published var appCuratedEnabled: Bool = false
    @Published var orgCatalogEnabled: Bool = false
    @Published var orgCatalogURL: String = ""
    @Published var orgCatalogPublicKey: String = ""

    /// The org feed when fully configured and enabled (spec §4).
    var orgFeed: RemoteFeed? {
        guard orgCatalogEnabled else { return nil }
        return RemoteFeed.org(urlString: orgCatalogURL.isEmpty ? nil : orgCatalogURL,
                              publicKeyBase64: orgCatalogPublicKey.isEmpty ? nil : orgCatalogPublicKey)
    }

    @Published var personalWallpaperFolderPath: String = ""

    /// Personal-source mode (spec §5). Computed, not stored, so it can never
    /// drift from `personalWallpaperFolderPath` edits: explicit key wins,
    /// else an existing user folder stays `.userDefined`, else app-managed.
    var personalFolderSource: PersonalFolderSource {
        PersonalFolderSource.resolve(raw: ManagedPreferences.string(.personalFolderSource),
                                     userDefinedPath: personalWallpaperFolderPath)
    }

    /// The folder the Personal source actually scans right now.
    var effectivePersonalFolderPath: String? {
        PersonalFolder.effectivePath(source: personalFolderSource,
                                     userDefinedPath: personalWallpaperFolderPath)
    }
    @Published var favoriteWallpaperIDs: [String] = []
    @Published var autoRotateEnabled: Bool = false
    @Published var autoRotateIntervalMinutes: Int = 30
    @Published var autoRotateShuffle: Bool = true
    @Published var autoRotateOnWake: Bool = false
    /// Unified rotation sources (spec §4) — member raw values. An empty
    /// array is meaningful: "nothing to rotate".
    @Published var rotationPool: [String] = RotationPoolMember.defaultPool
    /// True when the pool is pinned by a profile — either `rotationPool`
    /// itself or still-forced legacy rotation keys (translated live).
    @Published private(set) var rotationPoolForced: Bool = false
    @Published var appearanceTheme: AppearanceTheme = .light
    /// Wallpaper grid density (2–4 columns; header "view" control).
    @Published var gridColumns: Int = 2

    // Screen savers & Studio (spec §10). `managedScreenSaverScene` is
    // admin-only and read through ScreenSaverSceneStore, not mirrored here.
    @Published var screenSaverEnabled: Bool = true
    @Published var showScreenSaversPage: Bool = true
    @Published var showStudio: Bool = true
    @Published var showStudioWallpapersTab: Bool = true
    @Published var showStudioScreenSaverTab: Bool = true
    @Published var allowScreenSaverCreation: Bool = true
    @Published var activeScreenSaverSceneID: String?
    @Published var allowedScreenSaverSceneIDs: [String]?
    /// Admin-set: the saver `paperwallscli manage` keeps selected.
    @Published var enforcedScreenSaverPath: String = ""
    /// What to do about macOS's own large clock over the saver.
    @Published var hideSystemSaverClock: SystemSaverClockPolicy = .never
    /// Unlocks the admin tools (Studio › Package, "Copy Scene for MDM").
    @Published var adminModeEnabled: Bool = false
    @Published var brandAssetsFolderPath: String = ""
    /// Publish to Jamf Pro (admin mode): master switch + what may be uploaded.
    @Published var jamfPublishEnabled: Bool = false
    @Published var jamfPublishPackages: Bool = true
    @Published var jamfPublishProfiles: Bool = true

    /// The resolved Jamf publishing permissions; off entirely without admin mode.
    var jamfPolicy: JamfPublishPolicy {
        JamfPublishPolicy(enabled: adminModeEnabled && jamfPublishEnabled,
                          packages: jamfPublishPackages,
                          profiles: jamfPublishProfiles)
    }

    // AI generation (Studio › Wallpapers): master switch + one toggle per
    // provider. `aiPolicy` is the resolved view the composer reads.
    @Published var aiGenerationEnabled: Bool = false
    @Published var aiAppleOnDeviceEnabled: Bool = false
    @Published var aiLocalModelEnabled: Bool = false
    @Published var aiExternalModelEnabled: Bool = false
    @Published var aiLocalModelEndpoint: String = ""
    @Published var aiLocalModelFlavor: String = LocalImageAPIFlavor.automatic1111.rawValue
    @Published var aiLocalModelName: String = ""
    @Published var aiLocalModelImageSize: String = LocalImageSize.matchWallpaper.rawValue

    @Published var aiExternalProvider: String = ExternalImageProviderKind.google.rawValue
    @Published var aiExternalEndpoint: String = ""
    @Published var aiExternalModelName: String = ""
    @Published var aiExternalImageShape: String = ExternalImageShape.matchWallpaper.rawValue
    @Published var aiPromptImproverEnabled: Bool = false
    @Published var aiPromptImproverModel: String = ""

    var externalImageEndpoint: ExternalImageEndpoint {
        ExternalImageEndpoint(provider: ExternalImageProviderKind(rawValue: aiExternalProvider) ?? .google,
                              baseURL: aiExternalEndpoint,
                              modelName: aiExternalModelName,
                              shape: ExternalImageShape(rawValue: aiExternalImageShape) ?? .matchWallpaper)
    }

    var promptImprover: PromptImprover {
        let model = aiPromptImproverModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return PromptImprover(model: model.isEmpty ? PromptImprover.defaultModel : model)
    }

    var localImageEndpoint: LocalImageEndpoint {
        LocalImageEndpoint(baseURL: aiLocalModelEndpoint,
                           flavor: LocalImageAPIFlavor(rawValue: aiLocalModelFlavor) ?? .automatic1111,
                           modelName: aiLocalModelName,
                           imageSize: LocalImageSize(rawValue: aiLocalModelImageSize) ?? .matchWallpaper)
    }

    var aiPolicy: AIGenerationPolicy {
        AIGenerationPolicy(enabled: aiGenerationEnabled,
                           appleOnDevice: aiAppleOnDeviceEnabled,
                           localModel: aiLocalModelEnabled,
                           externalModel: aiExternalModelEnabled,
                           promptImprover: aiPromptImproverEnabled)
    }

    private var isReloading = false
    private var cancellables: Set<AnyCancellable> = []

    init() {
        reload()
        installPersistence()
    }

    func isForced(_ key: ManagedPreferenceKey) -> Bool {
        ManagedPreferences.isForced(key)
    }

    /// Re-reads every key from CFPreferences (e.g. after a profile change).
    func reload() {
        isReloading = true
        defer { isReloading = false }
        selectedWallpaperID = ManagedPreferences.string(.selectedWallpaperID)
        scale = ManagedPreferences.string(.scale).flatMap(WallpaperScale.init(rawValue:)) ?? .fill
        fillColorHex = ManagedPreferences.string(.fillColor) ?? ""
        applyToAllScreens = ManagedPreferences.bool(.applyToAllScreens) ?? true
        lockSelection = ManagedPreferences.bool(.lockSelection) ?? false
        allowLockExit = ManagedPreferences.bool(.allowLockExit) ?? true
        // Published value includes the legacy lockSelection mapping so the
        // Settings picker reflects the effective configured tier.
        lockMode = LockMode.resolveConfigured(
            lockModeRaw: ManagedPreferences.string(.lockMode),
            lockSelection: lockSelection,
            allowLockExit: allowLockExit,
            allowLockExitForced: ManagedPreferences.isForced(.allowLockExit))
        allowedWallpaperIDs = ManagedPreferences.stringArray(.allowedWallpaperIDs)
        externalWallpaperFolderPath = ManagedPreferences.string(.externalWallpaperFolderPath) ?? ""
        showBundledWallpapers = ManagedPreferences.bool(.showBundledWallpapers) ?? true
        showSystemWallpapers = ManagedPreferences.bool(.showSystemWallpapers) ?? true
        allowSystemWallpaperDownloads = ManagedPreferences.bool(.allowSystemWallpaperDownloads) ?? true
        showFeaturedWallpaper = ManagedPreferences.bool(.showFeaturedWallpaper) ?? true
        companyName = ManagedPreferences.string(.companyName) ?? ""
        appCuratedEnabled = ManagedPreferences.bool(.appCuratedEnabled) ?? false
        orgCatalogEnabled = ManagedPreferences.bool(.orgCatalogEnabled) ?? false
        orgCatalogURL = ManagedPreferences.string(.orgCatalogURL) ?? ""
        orgCatalogPublicKey = ManagedPreferences.string(.orgCatalogPublicKey) ?? ""

        personalWallpaperFolderPath = ManagedPreferences.string(.personalWallpaperFolderPath) ?? ""
        favoriteWallpaperIDs = ManagedPreferences.stringArray(.favoriteWallpaperIDs) ?? []
        autoRotateEnabled = ManagedPreferences.bool(.autoRotateEnabled) ?? false
        autoRotateIntervalMinutes = ManagedPreferences.int(.autoRotateIntervalMinutes) ?? 30
        autoRotateShuffle = ManagedPreferences.bool(.autoRotateShuffle) ?? true
        autoRotateOnWake = ManagedPreferences.bool(.autoRotateOnWake) ?? false
        // Effective pool (spec §4) — shared layered logic, see
        // RotationPool.effectiveConfiguredPool().
        (rotationPool, rotationPoolForced) = RotationPool.effectiveConfiguredPool()
        appearanceTheme = ManagedPreferences.string(.appearanceTheme).flatMap(AppearanceTheme.init(rawValue:)) ?? .light
        gridColumns = min(4, max(2, ManagedPreferences.int(.gridColumns) ?? 2))

        screenSaverEnabled = ManagedPreferences.bool(.screenSaverEnabled) ?? true
        showScreenSaversPage = ManagedPreferences.bool(.showScreenSaversPage) ?? true
        showStudio = ManagedPreferences.bool(.showStudio) ?? true
        showStudioWallpapersTab = ManagedPreferences.bool(.showStudioWallpapersTab) ?? true
        showStudioScreenSaverTab = ManagedPreferences.bool(.showStudioScreenSaverTab) ?? true
        allowScreenSaverCreation = ManagedPreferences.bool(.allowScreenSaverCreation) ?? true
        activeScreenSaverSceneID = ManagedPreferences.string(.activeScreenSaverSceneID)
        allowedScreenSaverSceneIDs = ManagedPreferences.stringArray(.allowedScreenSaverSceneIDs)
        enforcedScreenSaverPath = ManagedPreferences.string(.enforcedScreenSaverPath) ?? ""
        hideSystemSaverClock = SystemSaverClock.currentPolicy
        adminModeEnabled = ManagedPreferences.bool(.adminModeEnabled) ?? false
        brandAssetsFolderPath = ManagedPreferences.string(.brandAssetsFolderPath) ?? ""
        jamfPublishEnabled = ManagedPreferences.bool(.jamfPublishEnabled) ?? false
        jamfPublishPackages = ManagedPreferences.bool(.jamfPublishPackages) ?? true
        jamfPublishProfiles = ManagedPreferences.bool(.jamfPublishProfiles) ?? true
        aiGenerationEnabled = ManagedPreferences.bool(.aiGenerationEnabled) ?? false
        aiAppleOnDeviceEnabled = ManagedPreferences.bool(.aiAppleOnDeviceEnabled) ?? false
        aiLocalModelEnabled = ManagedPreferences.bool(.aiLocalModelEnabled) ?? false
        aiExternalModelEnabled = ManagedPreferences.bool(.aiExternalModelEnabled) ?? false
        aiLocalModelEndpoint = ManagedPreferences.string(.aiLocalModelEndpoint) ?? ""
        aiLocalModelFlavor = ManagedPreferences.string(.aiLocalModelFlavor) ?? LocalImageAPIFlavor.automatic1111.rawValue
        aiLocalModelName = ManagedPreferences.string(.aiLocalModelName) ?? ""
        aiLocalModelImageSize = ManagedPreferences.string(.aiLocalModelImageSize) ?? LocalImageSize.matchWallpaper.rawValue
        aiExternalProvider = ManagedPreferences.string(.aiExternalProvider) ?? ExternalImageProviderKind.google.rawValue
        aiExternalEndpoint = ManagedPreferences.string(.aiExternalEndpoint) ?? ""
        aiExternalModelName = ManagedPreferences.string(.aiExternalModelName) ?? ""
        aiExternalImageShape = ManagedPreferences.string(.aiExternalImageShape) ?? ExternalImageShape.matchWallpaper.rawValue
        aiPromptImproverEnabled = ManagedPreferences.bool(.aiPromptImproverEnabled) ?? false
        aiPromptImproverModel = ManagedPreferences.string(.aiPromptImproverModel) ?? ""
    }

    /// Persists each published property back to CFPreferences when it changes
    /// through a binding. Empty strings/arrays clear the key.
    private func installPersistence() {
        persist($selectedWallpaperID, .selectedWallpaperID) { $0 }
        persist($scale, .scale) { $0.rawValue }
        persist($fillColorHex, .fillColor) { $0.isEmpty ? nil : $0 }
        persist($applyToAllScreens, .applyToAllScreens) { $0 }
        persist($lockSelection, .lockSelection) { $0 }
        persist($lockMode, .lockMode) { $0.rawValue }
        persist($allowLockExit, .allowLockExit) { $0 }
        persist($allowedWallpaperIDs, .allowedWallpaperIDs) { ($0?.isEmpty ?? true) ? nil : $0 }
        persist($externalWallpaperFolderPath, .externalWallpaperFolderPath) { $0.isEmpty ? nil : $0 }
        persist($showBundledWallpapers, .showBundledWallpapers) { $0 }
        persist($showSystemWallpapers, .showSystemWallpapers) { $0 }
        persist($allowSystemWallpaperDownloads, .allowSystemWallpaperDownloads) { $0 }
        persist($showFeaturedWallpaper, .showFeaturedWallpaper) { $0 }
        persist($companyName, .companyName) { $0.isEmpty ? nil : $0 }
        persist($appCuratedEnabled, .appCuratedEnabled) { $0 }
        persist($orgCatalogEnabled, .orgCatalogEnabled) { $0 }
        persist($orgCatalogURL, .orgCatalogURL) { $0.isEmpty ? nil : $0 }
        persist($orgCatalogPublicKey, .orgCatalogPublicKey) { $0.isEmpty ? nil : $0 }

        persist($personalWallpaperFolderPath, .personalWallpaperFolderPath) { $0.isEmpty ? nil : $0 }
        persist($favoriteWallpaperIDs, .favoriteWallpaperIDs) { $0.isEmpty ? nil : $0 }
        persist($autoRotateEnabled, .autoRotateEnabled) { $0 }
        persist($autoRotateIntervalMinutes, .autoRotateIntervalMinutes) { $0 }
        persist($autoRotateShuffle, .autoRotateShuffle) { $0 }
        persist($autoRotateOnWake, .autoRotateOnWake) { $0 }
        // Unlike the other arrays, an empty pool persists as [] — it's the
        // deliberate "nothing to rotate" state, not "use the default".
        persist($rotationPool, .rotationPool) { $0 }
        persist($appearanceTheme, .appearanceTheme) { $0.rawValue }
        persist($gridColumns, .gridColumns) { $0 }

        persist($screenSaverEnabled, .screenSaverEnabled) { $0 }
        persist($showScreenSaversPage, .showScreenSaversPage) { $0 }
        persist($showStudio, .showStudio) { $0 }
        persist($showStudioWallpapersTab, .showStudioWallpapersTab) { $0 }
        persist($showStudioScreenSaverTab, .showStudioScreenSaverTab) { $0 }
        persist($allowScreenSaverCreation, .allowScreenSaverCreation) { $0 }
        persist($activeScreenSaverSceneID, .activeScreenSaverSceneID) { $0 }
        persist($allowedScreenSaverSceneIDs, .allowedScreenSaverSceneIDs) { ($0?.isEmpty ?? true) ? nil : $0 }
        persist($enforcedScreenSaverPath, .enforcedScreenSaverPath) { $0.isEmpty ? nil : $0 }
        persist($hideSystemSaverClock, .hideSystemSaverClock) { $0 == .never ? nil : $0.rawValue }
        persist($adminModeEnabled, .adminModeEnabled) { $0 }
        persist($brandAssetsFolderPath, .brandAssetsFolderPath) { $0.isEmpty ? nil : $0 }
        persist($jamfPublishEnabled, .jamfPublishEnabled) { $0 }
        persist($jamfPublishPackages, .jamfPublishPackages) { $0 }
        persist($jamfPublishProfiles, .jamfPublishProfiles) { $0 }
        persist($aiGenerationEnabled, .aiGenerationEnabled) { $0 }
        persist($aiAppleOnDeviceEnabled, .aiAppleOnDeviceEnabled) { $0 }
        persist($aiLocalModelEnabled, .aiLocalModelEnabled) { $0 }
        persist($aiExternalModelEnabled, .aiExternalModelEnabled) { $0 }
        persist($aiLocalModelEndpoint, .aiLocalModelEndpoint) { $0.isEmpty ? nil : $0 }
        persist($aiLocalModelFlavor, .aiLocalModelFlavor) { $0 }
        persist($aiLocalModelName, .aiLocalModelName) { $0.isEmpty ? nil : $0 }
        persist($aiLocalModelImageSize, .aiLocalModelImageSize) { $0 }
        persist($aiExternalProvider, .aiExternalProvider) { $0 }
        persist($aiExternalEndpoint, .aiExternalEndpoint) { $0.isEmpty ? nil : $0 }
        persist($aiExternalModelName, .aiExternalModelName) { $0.isEmpty ? nil : $0 }
        persist($aiExternalImageShape, .aiExternalImageShape) { $0 }
        persist($aiPromptImproverEnabled, .aiPromptImproverEnabled) { $0 }
        persist($aiPromptImproverModel, .aiPromptImproverModel) { $0.isEmpty ? nil : $0 }
    }

    private func persist<Value: Equatable>(_ publisher: Published<Value>.Publisher,
                                           _ key: ManagedPreferenceKey,
                                           transform: @escaping (Value) -> Any?) {
        publisher
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] value in
                guard let self, !self.isReloading else { return }
                ManagedPreferences.set(transform(value), for: key)
            }
            .store(in: &cancellables)
    }
}
