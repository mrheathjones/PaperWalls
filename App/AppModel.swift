import AppKit
import Combine
import ImageIO
import SwiftUI

/// Sidebar destinations.
enum LibraryPage: String, CaseIterable, Identifiable {
    case browse = "Browse"
    case collections = "Collections"
    case system = "macOS"
    case managed = "Managed"
    case personal = "Personal"
    case screenSavers = "ScreenSavers"
    case studio = "Studio"
    case settings = "Settings"

    var id: String { rawValue }

    /// Sidebar grouping (spec §10). Settings is always the last row.
    var section: SidebarSection {
        switch self {
        case .studio: return .tools
        case .settings: return .settings
        default: return .library
        }
    }
}

enum SidebarSection: CaseIterable {
    case library
    case tools
    case settings

    /// Header label; Settings sits alone at the bottom without one.
    var title: String? {
        switch self {
        case .library: return "LIBRARY"
        case .tools: return "TOOLS"
        case .settings: return nil
        }
    }
}

/// What Studio's ScreenSaver tab should open with (spec §10) — set by
/// `AppModel.openStudio` from the ScreenSavers page, consumed by Studio.
enum StudioRequest: Equatable {
    case new
    case edit(sceneID: String)
}

/// Which pill is active on the Browse page.
enum BrowseFilter: Hashable {
    case all
    case favorites
    case collection(String)
    case personal
    case managed
    case appCurated
    case orgRemote
    case system

    var displayName: String {
        switch self {
        case .all: return "All"
        case .favorites: return "Favorites"
        case .collection(let name): return name
        case .personal: return "Personal"
        case .managed: return "Company"
        case .appCurated: return "Curated"
        case .orgRemote: return "Company Feed"
        case .system: return "macOS"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let prefs: PreferencesStore

    @Published var page: LibraryPage = .browse
    @Published var searchText: String = ""
    @Published var browseFilter: BrowseFilter = .all

    @Published private(set) var library = WallpaperLibrary()
    @Published private(set) var screens: [NSScreen] = []
    @Published private(set) var currentWallpaperPaths: Set<String> = []
    @Published private(set) var isApplying = false
    @Published var errorMessage: String?

    /// Wallpaper shown in the detail sheet (sheet(item:) payload).
    @Published var detailWallpaper: CuratedWallpaper?

    /// True once the user leaves the locked overlay via "Back to Library"
    /// (soft lock with allowLockExit). Resets whenever the lock engages.
    @Published var lockOverlayDismissed = false

    /// The effective lock (configured tier + legacy keys + detected OS
    /// restriction). Refreshed on pref changes, live reload, and the timer.
    @Published private(set) var lockState = LockState.current()

    private var configWatchers: [DispatchSourceFileSystemObject] = []
    private var reloadDebounce: Task<Void, Never>?

    /// Persisted (same preference domain) so the countdown survives app
    /// relaunches instead of restarting the interval every launch.
    @Published private(set) var nextRotationDate: Date? {
        didSet { persistNextRotationDate() }
    }
    @Published private(set) var now = Date()

    // MARK: Screen savers & Studio (spec §10; logic in AppModel+ScreenSavers)

    /// User-created scenes, newest first (the managed entry is separate).
    @Published var screenSavers: [StoredScreenSaver] = []
    /// The admin-provisioned read-only scene, when configured.
    @Published var managedScreenSaver: StoredScreenSaver?
    /// Rendered card thumbnails by scene ID.
    @Published var screenSaverThumbnails: [String: NSImage] = [:]
    @Published var studioTab: StudioTab = .screenSaver
    /// The Scene Composer's working state. A separate object so editing
    /// (every slider tick) doesn't republish the whole app model.
    let studio = StudioSession()

    private var pixelSizeCache: [URL: CGSize] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init(prefs: PreferencesStore) {
        self.prefs = prefs
        // One-time spec-§6 upgrade: favorites/selection recorded under the
        // old path-derived folder IDs move to content IDs. Runs before the
        // first scan; reload so the store sees the rewritten values.
        let idsMigrated = ContentIDMigration.migrateIfNeeded()
        let poolMigrated = RotationPoolMigration.migrateIfNeeded()
        if idsMigrated || poolMigrated {
            prefs.reload()
        }
        if prefs.personalFolderSource == .appManaged {
            PersonalFolder.ensureAppManagedFolderExists()
        }
        rescan()
        checkPersonalFolderSourceSwitch()
        syncRemoteFeedsIfNeeded()
        refreshScreens()
        restorePersistedRotationClock()
        reloadScreenSavers()

        // Never strand the user on a page whose gate just flipped off
        // (spec §10). Published values land after this fires, so check on
        // the next main-queue turn.
        prefs.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.enforcePageVisibility() }
            .store(in: &cancellables)

        // Feed toggles: sync immediately when a feed turns on or its config
        // changes (spec §4).
        for feedTrigger in [prefs.$appCuratedEnabled.map { _ in () }.eraseToAnyPublisher(),
                            prefs.$orgCatalogEnabled.map { _ in () }.eraseToAnyPublisher(),
                            prefs.$orgCatalogURL.map { _ in () }.eraseToAnyPublisher()] {
            feedTrigger
                .dropFirst()
                .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
                .sink { [weak self] in
                    self?.rescan()
                    self?.syncRemoteFeedsIfNeeded(force: true)
                }
                .store(in: &cancellables)
        }

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshScreens() }
            .store(in: &cancellables)

        for pathPublisher in [prefs.$externalWallpaperFolderPath, prefs.$personalWallpaperFolderPath] {
            pathPublisher
                .removeDuplicates()
                .dropFirst()
                .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.rescan() }
                .store(in: &cancellables)
        }

        // Re-evaluate the lock whenever its keys change; re-show the overlay
        // when the lock engages. Also leave the Collections page if bundled
        // wallpapers get hidden.
        prefs.$lockSelection.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.refreshLockState() }
            .store(in: &cancellables)
        prefs.$lockMode.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.refreshLockState() }
            .store(in: &cancellables)
        prefs.$showBundledWallpapers
            .removeDuplicates()
            .sink { [weak self] showBundled in
                guard let self, !showBundled else { return }
                if self.page == .collections { self.page = .browse }
                if case .collection = self.browseFilter { self.browseFilter = .all }
            }
            .store(in: &cancellables)

        // macOS wallpapers are gated at scan time — re-scan on toggle, and
        // leave the macOS page/pill if the source just went away.
        prefs.$showSystemWallpapers
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] show in
                guard let self else { return }
                if !show {
                    if self.browseFilter == .system { self.browseFilter = .all }
                    if self.page == .system { self.page = .browse }
                }
                self.rescan()
            }
            .store(in: &cancellables)

        // Window appearance. NSApp.appearance (unlike preferredColorScheme,
        // whose nil never un-pins an explicit scheme on macOS) applies
        // immediately AND follows live macOS light/dark changes when nil.
        applyAppearance(prefs.appearanceTheme)
        prefs.$appearanceTheme
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] theme in self?.applyAppearance(theme) }
            .store(in: &cancellables)

        // Reset the rotation clock when its configuration changes.
        prefs.$autoRotateEnabled
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.nextRotationDate = nil }
            .store(in: &cancellables)
        prefs.$autoRotateIntervalMinutes
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.nextRotationDate = nil }
            .store(in: &cancellables)

        Timer.publish(every: 15, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.rotationTick() }
            .store(in: &cancellables)

        // Run one tick immediately so a rotation that came due while the app
        // was closed fires now instead of waiting for the first timer beat.
        rotationTick()

        // Live reload (spec §3): re-read managed + local config when the
        // profile store or the local config file changes, and on activation.
        installConfigWatchers()
        NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.reloadExternalConfig() }
            .store(in: &cancellables)

        // Settings → "Change on wake": new wallpaper each time the Mac wakes.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.prefs.autoRotateOnWake, self.lockState.allowsRotation else { return }
                self.rotateNow()
                if self.prefs.autoRotateEnabled {
                    let interval = TimeInterval(max(1, self.prefs.autoRotateIntervalMinutes)) * 60
                    self.nextRotationDate = Date().addingTimeInterval(interval)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - macOS on-demand wallpapers

    /// Asset IDs currently downloading (drives per-card spinners).
    @Published private(set) var downloadingSystemAssets: Set<String> = []

    /// True while Settings → "Collect Logs…" is gathering (spinner state).
    @Published var isCollectingDiagnostics = false

    /// "Don't show again" for the download-before-set prompt. Runtime UI
    /// state, stored as a raw same-domain key (like nextRotationDate).
    private static let suppressDownloadPromptKey = "suppressSystemDownloadSetPrompt" as CFString

    private var suppressSystemDownloadSetPrompt: Bool {
        get {
            (CFPreferencesCopyAppValue(Self.suppressDownloadPromptKey,
                                       ManagedPreferences.domain as CFString) as? Bool) ?? false
        }
        set {
            CFPreferencesSetAppValue(Self.suppressDownloadPromptKey,
                                     newValue as CFBoolean,
                                     ManagedPreferences.domain as CFString)
            CFPreferencesAppSynchronize(ManagedPreferences.domain as CFString)
        }
    }

    /// "Set" on a not-yet-downloaded macOS wallpaper: explain that a
    /// download happens first (once — the prompt has "Don't show again"),
    /// then download and apply.
    func requestSetForPendingSystemWallpaper(_ entry: SystemAssetEntry) {
        guard !suppressSystemDownloadSetPrompt else {
            downloadSystemWallpaper(entry, thenSet: true)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Download “\(entry.displayName)” first?"
        let size = entry.downloadSize.map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        }
        alert.informativeText = "This wallpaper isn't on your Mac yet. It will be downloaded from Apple\(size.map { " (\($0))" } ?? "") and then set as your desktop."
        alert.addButton(withTitle: "Download & Set")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't show this again"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if alert.suppressionButton?.state == .on {
            suppressSystemDownloadSetPrompt = true
        }
        downloadSystemWallpaper(entry, thenSet: true)
    }

    /// One-shot per launch: on Macs whose OS hasn't populated the local
    /// MobileAsset catalog (fresh/managed devices), pending entries have no
    /// download URLs — fetch Apple's public catalog copy so the Download
    /// buttons work. Gated on the same key that gates the downloads.
    private var attemptedCatalogRefresh = false

    private func refreshSystemCatalogIfNeeded() {
        guard prefs.showSystemWallpapers,
              prefs.allowSystemWallpaperDownloads,
              !attemptedCatalogRefresh,
              !library.systemPending.isEmpty,
              library.systemPending.allSatisfy({ $0.downloadURL == nil }) else {
            return
        }
        attemptedCatalogRefresh = true
        Task { [weak self] in
            if await SystemWallpaperStore.refreshCatalogIfNeeded() {
                await MainActor.run { self?.rescan() }
            }
        }
    }

    /// Explicit user action — the only path that fetches a macOS wallpaper
    /// from Apple's CDN. On success the asset lands in the cache and the
    /// rescan promotes it into the regular grid; `thenSet` applies it as
    /// the desktop right away ("Download & Set").
    func downloadSystemWallpaper(_ entry: SystemAssetEntry, thenSet: Bool = false) {
        guard prefs.allowSystemWallpaperDownloads else { return }
        guard !downloadingSystemAssets.contains(entry.assetID) else { return }
        downloadingSystemAssets.insert(entry.assetID)
        Task { @MainActor in
            defer { downloadingSystemAssets.remove(entry.assetID) }
            do {
                try await SystemWallpaperStore.download(entry)
                rescan()
                if thenSet, let wallpaper = library.system.first(where: { $0.id == entry.id }) {
                    apply(wallpaper)
                }
            } catch {
                errorMessage = "Couldn't download “\(entry.displayName)”: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Appearance

    private func applyAppearance(_ theme: AppearanceTheme) {
        switch theme {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil   // track macOS, live
        }
    }

    // MARK: - Lock state / live reload

    func refreshLockState() {
        let previous = lockState
        let next = LockState.current()
        if next.mode != previous.mode || next.osEnforced != previous.osEnforced {
            lockState = next
            if next.showsLockedView && !previous.showsLockedView {
                lockOverlayDismissed = false
            }
            // A hard lock disables Studio's composer (spec §10).
            enforcePageVisibility()
        }
    }

    /// Re-reads everything an admin can change out from under us.
    func reloadExternalConfig() {
        ManagedPreferences.invalidateLocalConfigCache()
        prefs.reload()
        refreshLockState()
        rescan()
        reloadScreenSavers()
        enforcePageVisibility()
        checkPersonalFolderSourceSwitch()
        syncRemoteFeedsIfNeeded()
    }

    /// One-time notice when an admin-forced `personalFolderSource` switch
    /// changes what the Personal source shows (spec §5). Tracked via a raw
    /// same-domain key so the notice fires once per switch, not per launch.
    private static let personalSourceTrackerKey = "lastPersonalFolderSource" as CFString

    private func checkPersonalFolderSourceSwitch() {
        let current = prefs.personalFolderSource.rawValue
        let previous = CFPreferencesCopyAppValue(Self.personalSourceTrackerKey,
                                                 ManagedPreferences.domain as CFString) as? String
        guard previous != current else { return }
        if previous != nil, ManagedPreferences.isForced(.personalFolderSource) {
            errorMessage = "Your organization changed where your Personal wallpapers come from. Your favorites are kept, but wallpapers from the previous folder may no longer be listed."
        }
        CFPreferencesSetAppValue(Self.personalSourceTrackerKey, current as CFString,
                                 ManagedPreferences.domain as CFString)
        CFPreferencesAppSynchronize(ManagedPreferences.domain as CFString)
    }

    /// Watches /Library/Managed Preferences and the local managed-config
    /// directory so admin changes apply without relaunch.
    private func installConfigWatchers() {
        let paths = [
            "/Library/Managed Preferences",
            ManagedPreferences.localConfigDirectory,
        ]
        for path in paths {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }   // directory may not exist yet
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename],
                queue: .main)
            source.setEventHandler { [weak self] in
                self?.scheduleExternalReload()
            }
            source.setCancelHandler {
                close(descriptor)
            }
            source.resume()
            configWatchers.append(source)
        }
    }

    private func scheduleExternalReload() {
        reloadDebounce?.cancel()
        reloadDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.reloadExternalConfig()
        }
    }

    // MARK: - Library

    func rescan() {
        var scanned = WallpaperCatalog.load(managedFolderPath: prefs.externalWallpaperFolderPath,
                                            personalFolderPath: prefs.effectivePersonalFolderPath,
                                            includeSystemWallpapers: prefs.showSystemWallpapers)
        // Remote feeds come from the last-good verified cache — rescan never
        // touches the network (spec §4).
        if prefs.appCuratedEnabled {
            let cached = RemoteCatalog.loadCached(feed: .appCurated)
            scanned.appCurated = cached.wallpapers
            scanned.appCuratedFolderURL = cached.folderURL
        }
        if let orgFeed = prefs.orgFeed {
            let cached = RemoteCatalog.loadCached(feed: orgFeed)
            scanned.orgRemote = cached.wallpapers
            scanned.orgRemoteFolderURL = cached.folderURL
        }
        library = scanned
        refreshCurrentWallpapers()
        refreshSystemCatalogIfNeeded()
    }

    /// Syncs the enabled remote feeds (spec §4): launch + every 6 h via the
    /// rotation tick + whenever a feed key changes. With both gates off this
    /// is a no-op — the air-gap guarantee.
    private static let feedSyncInterval: TimeInterval = 6 * 60 * 60
    private var lastFeedSync: Date?

    func syncRemoteFeedsIfNeeded(force: Bool = false) {
        var feeds: [RemoteFeed] = []
        if prefs.appCuratedEnabled { feeds.append(.appCurated) }
        if let orgFeed = prefs.orgFeed { feeds.append(orgFeed) }
        guard !feeds.isEmpty else { return }
        if !force, let last = lastFeedSync, Date().timeIntervalSince(last) < Self.feedSyncInterval {
            return
        }
        lastFeedSync = Date()
        Task { [weak self] in
            var changed = false
            for feed in feeds {
                if await RemoteCatalog.sync(feed: feed) { changed = true }
            }
            if changed {
                await MainActor.run { self?.rescan() }
            }
        }
    }

    /// allowedWallpaperIDs policy, applied to any source list.
    func allowedFilter(_ wallpapers: [CuratedWallpaper]) -> [CuratedWallpaper] {
        guard let allowed = prefs.allowedWallpaperIDs, !allowed.isEmpty else { return wallpapers }
        let allowedSet = Set(allowed)
        return wallpapers.filter { allowedSet.contains($0.id) }
    }

    func searchFilter(_ wallpapers: [CuratedWallpaper]) -> [CuratedWallpaper] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return wallpapers }
        return wallpapers.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    /// Bundled wallpapers after the showBundledWallpapers/allowedIDs policy.
    /// Empty when the toggle hides them — never falls back silently.
    var visibleBundled: [CuratedWallpaper] {
        prefs.showBundledWallpapers ? allowedFilter(library.bundled) : []
    }

    var visiblePersonal: [CuratedWallpaper] { allowedFilter(library.personal) }
    var visibleManaged: [CuratedWallpaper] { allowedFilter(library.managed) }
    var visibleAppCurated: [CuratedWallpaper] { allowedFilter(library.appCurated) }
    var visibleOrgRemote: [CuratedWallpaper] { allowedFilter(library.orgRemote) }
    var visibleSystem: [CuratedWallpaper] { allowedFilter(library.system) }

    var collections: [String] {
        var seen = Set<String>()
        return visibleBundled.compactMap { wallpaper in
            guard let collection = wallpaper.collection, seen.insert(collection).inserted else {
                return nil
            }
            return collection
        }
    }

    func bundledWallpapers(in collection: String?) -> [CuratedWallpaper] {
        guard let collection else { return visibleBundled }
        return visibleBundled.filter { $0.collection == collection }
    }

    /// Hearted wallpapers across every source (the "Favorites" collection).
    var favoriteWallpapers: [CuratedWallpaper] {
        let favorites = Set(prefs.favoriteWallpaperIDs)
        return allBrowseWallpapers.filter { favorites.contains($0.id) }
    }

    /// Everything Browse's "All" pill shows: bundled, macOS, feeds, folders.
    var allBrowseWallpapers: [CuratedWallpaper] {
        visibleBundled + visibleSystem + visibleAppCurated + visibleOrgRemote + visiblePersonal + visibleManaged
    }

    /// The Browse grid contents for the active pill.
    var browseWallpapers: [CuratedWallpaper] {
        switch browseFilter {
        case .all:
            return allBrowseWallpapers
        case .favorites:
            return favoriteWallpapers
        case .collection(let name):
            return visibleBundled.filter { $0.collection == name }
        case .personal:
            return visiblePersonal
        case .managed:
            return visibleManaged
        case .appCurated:
            return visibleAppCurated
        case .orgRemote:
            return visibleOrgRemote
        case .system:
            return visibleSystem
        }
    }

    /// Deterministic daily pick for the "Featured today" hero.
    var featuredWallpaper: CuratedWallpaper? {
        let pool = visibleBundled
        guard !pool.isEmpty else { return nil }
        let day = Calendar.current.ordinality(of: .day, in: .year, for: now) ?? 0
        return pool[day % pool.count]
    }

    func pixelSize(of wallpaper: CuratedWallpaper) -> CGSize? {
        guard let url = library.fileURL(for: wallpaper) else { return nil }
        if let cached = pixelSizeCache[url] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        let size = CGSize(width: width, height: height)
        pixelSizeCache[url] = size
        return size
    }

    func fileSizeString(of wallpaper: CuratedWallpaper) -> String? {
        guard let url = library.fileURL(for: wallpaper),
              let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// "Company", "Personal", or the bundled collection name — the detail
    /// sheet's subtitle lead-in.
    func sourceLabel(for wallpaper: CuratedWallpaper) -> String {
        switch wallpaper.source {
        case .bundled: return wallpaper.collection ?? "Curated"
        case .external: return prefs.companyDisplayName
        case .personal: return "Personal"
        case .appCurated: return wallpaper.collection ?? "Curated Feed"
        case .orgRemote: return "\(prefs.companyDisplayName) Feed"
        case .system: return "macOS"
        }
    }

    // MARK: - Company-aware labels (companyName branding)

    /// Browse pill / header label for a filter, substituting the configured
    /// company name for the generic "Company" wording.
    func displayName(for filter: BrowseFilter) -> String {
        switch filter {
        case .managed: return prefs.companyDisplayName
        case .orgRemote: return "\(prefs.companyDisplayName) Feed"
        default: return filter.displayName
        }
    }

    /// Sidebar row title; the Managed page carries the org's name.
    func sidebarTitle(for page: LibraryPage) -> String {
        guard page == .managed, prefs.companyDisplayName != "Company" else {
            return page.rawValue
        }
        return "\(prefs.companyDisplayName) (Managed)"
    }

    /// Rotation-source chip label, company-branded for the org members.
    func poolMemberLabel(_ member: RotationPoolMember) -> String {
        switch member {
        case .orgFolder: return "\(prefs.companyDisplayName) Folder"
        case .orgRemote: return "\(prefs.companyDisplayName) Feed"
        default: return member.displayName
        }
    }

    // MARK: - Screens / current wallpaper

    func refreshScreens() {
        screens = NSScreen.screens
        refreshCurrentWallpapers()
    }

    func refreshCurrentWallpapers() {
        currentWallpaperPaths = Set(NSScreen.screens.compactMap {
            WallpaperEngine.currentWallpaperURL(for: $0)?.standardizedFileURL.path
        })
    }

    func isCurrent(_ wallpaper: CuratedWallpaper) -> Bool {
        guard let url = library.fileURL(for: wallpaper) else { return false }
        return currentWallpaperPaths.contains(url.standardizedFileURL.path)
    }

    // MARK: - Favorites

    func isFavorite(_ wallpaper: CuratedWallpaper) -> Bool {
        prefs.favoriteWallpaperIDs.contains(wallpaper.id)
    }

    func toggleFavorite(_ wallpaper: CuratedWallpaper) {
        var favorites = prefs.favoriteWallpaperIDs
        if let index = favorites.firstIndex(of: wallpaper.id) {
            favorites.remove(at: index)
        } else {
            favorites.append(wallpaper.id)
        }
        prefs.favoriteWallpaperIDs = favorites
    }

    // MARK: - Apply

    var managedWallpaper: CuratedWallpaper? {
        prefs.selectedWallpaperID.flatMap { library.wallpaper(withID: $0) }
    }

    /// True when the lock tier blocks user selection. Set controls grey out.
    var selectionLocked: Bool { lockState.blocksUserSelection }

    func apply(_ wallpaper: CuratedWallpaper) {
        // The single shared pre-apply guard (spec §1) — same rules as the
        // CLI. Under enforced rotation the resolved pool is the approved set.
        if let refusal = WallpaperApplyGuard.refusalReason(forApplying: wallpaper.id,
                                                           lockState: lockState,
                                                           rotationPoolIDs: Set(rotationPool.map(\.id))) {
            errorMessage = refusal
            return
        }
        guard let url = library.fileURL(for: wallpaper) else {
            errorMessage = "Could not locate the image file for \(wallpaper.displayName)."
            return
        }
        let targets = prefs.applyToAllScreens ? screens : Array(screens.prefix(1))
        guard !targets.isEmpty else {
            errorMessage = WallpaperError.noScreens.localizedDescription
            return
        }
        let scale = prefs.scale
        let fillColor = NSColor(hexString: prefs.fillColorHex)

        isApplying = true
        Task { @MainActor in
            defer { isApplying = false }
            do {
                try await WallpaperEngine.setWallpaper(url: url,
                                                       on: targets,
                                                       scale: scale,
                                                       fillColor: fillColor)
                prefs.selectedWallpaperID = wallpaper.id
                refreshCurrentWallpapers()
                // desktopImageURL can lag the set call briefly; re-read so
                // the ACTIVE badge lands even if the first read was stale.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self.refreshCurrentWallpapers()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Auto-rotate

    /// Pool the rotation timer, "Up next", and the pre-apply guard draw
    /// from — resolved through the shared `RotationPool` (spec §4).
    var rotationPool: [CuratedWallpaper] {
        var gates: Set<RotationPoolMember> = []
        if prefs.showBundledWallpapers { gates.insert(.bundled) }
        if prefs.showSystemWallpapers { gates.insert(.system) }
        if !prefs.externalWallpaperFolderPath.isEmpty { gates.insert(.orgFolder) }
        if prefs.effectivePersonalFolderPath != nil { gates.insert(.personal) }
        if prefs.appCuratedEnabled { gates.insert(.appCurated) }
        if prefs.orgFeed != nil { gates.insert(.orgRemote) }

        // Allow-list entries may still use legacy path-derived IDs —
        // canonicalize through the library before intersecting.
        let allowed = prefs.allowedWallpaperIDs.map { ids in
            ids.map { library.wallpaper(withID: $0)?.id ?? $0 }
        }
        return RotationPool.resolve(members: prefs.rotationPool,
                                    gates: gates,
                                    sources: [.bundled: visibleBundled,
                                              .system: visibleSystem,
                                              .appCurated: visibleAppCurated,
                                              .orgRemote: visibleOrgRemote,
                                              .orgFolder: visibleManaged,
                                              .personal: visiblePersonal],
                                    favorites: Set(prefs.favoriteWallpaperIDs),
                                    lockMode: lockState.mode,
                                    allowedIDs: allowed)
    }

    /// Settings/menu-bar label for the configured pool.
    var rotationPoolLabel: String {
        let members = prefs.rotationPool.compactMap(RotationPoolMember.init(rawValue:))
        guard !members.isEmpty else { return "No sources" }
        return members.map { poolMemberLabel($0) }.joined(separator: " · ")
    }

    /// Where the rotation queue currently stands. Prefers the app's own
    /// record of the last applied wallpaper (updated synchronously on every
    /// apply) over the system readback — desktopImageURL can lag a set call
    /// by a moment, which would leave "Up next" pointing at a stale spot.
    private func rotationAnchorIndex(in pool: [CuratedWallpaper]) -> Int? {
        if let id = prefs.selectedWallpaperID,
           let index = pool.firstIndex(where: { $0.id == id }) {
            return index
        }
        return pool.firstIndex(where: { isCurrent($0) })
    }

    /// The next few wallpapers rotation will use (Settings → "Up next").
    var upNext: [CuratedWallpaper] {
        let pool = rotationPool
        guard !pool.isEmpty else { return [] }
        let start = rotationAnchorIndex(in: pool).map { $0 + 1 } ?? 0
        return (0..<min(6, pool.count))
            .map { pool[(start + $0) % pool.count] }
            .filter { $0.id != prefs.selectedWallpaperID && !isCurrent($0) }
    }

    var rotationStatusTitle: String {
        prefs.autoRotateEnabled ? "Auto-rotate on" : "Auto-rotate off"
    }

    var rotationStatusDetail: String {
        guard prefs.autoRotateEnabled else { return "Turn on in Settings" }
        if !lockState.allowsRotation { return "Paused — selection is locked" }
        // Defined no-op state (spec §4): an empty pool keeps the current
        // wallpaper rather than falling back to some source.
        if rotationPool.isEmpty { return "Nothing to rotate — pick sources in Settings" }
        let sourceLabel = rotationPoolLabel
        guard let nextRotationDate else { return "Starting soon · \(sourceLabel)" }
        let minutes = max(1, Int(ceil(nextRotationDate.timeIntervalSince(now) / 60)))
        return "Next change in \(minutes) min · \(sourceLabel)"
    }

    /// "Rotate Now" in the sidebar card: rotate immediately and restart the
    /// countdown from now.
    func rotateNowManually() {
        rotateNow()
        if prefs.autoRotateEnabled {
            nextRotationDate = Date().addingTimeInterval(rotationInterval)
        }
    }

    /// "Next Wallpaper": apply exactly what "Up next" previews (instead of
    /// waiting out the timer) and restart the countdown.
    func applyNextWallpaper() {
        guard let next = upNext.first else { return }
        apply(next)
        if prefs.autoRotateEnabled {
            nextRotationDate = Date().addingTimeInterval(rotationInterval)
        }
    }

    private var rotationInterval: TimeInterval {
        TimeInterval(max(1, prefs.autoRotateIntervalMinutes)) * 60
    }

    private func rotationTick() {
        now = Date()
        refreshLockState()
        syncRemoteFeedsIfNeeded()   // interval sync (no-op inside 6 h / gates off)
        guard prefs.autoRotateEnabled, lockState.allowsRotation else {
            if nextRotationDate != nil { nextRotationDate = nil }
            return
        }
        guard let due = nextRotationDate else {
            nextRotationDate = now.addingTimeInterval(rotationInterval)
            return
        }
        if now >= due {
            rotateNow()
            nextRotationDate = now.addingTimeInterval(rotationInterval)
        }
    }

    // MARK: - Rotation clock persistence

    private static let nextRotationKey = "nextRotationDate" as CFString

    /// Reload the persisted due date on launch; clamp it if the interval was
    /// shortened while the app was closed. Overdue dates are kept as-is so
    /// the immediate init tick fires the missed rotation.
    private func restorePersistedRotationClock() {
        guard prefs.autoRotateEnabled,
              let timestamp = CFPreferencesCopyAppValue(Self.nextRotationKey,
                                                        ManagedPreferences.domain as CFString) as? Double else {
            return
        }
        var due = Date(timeIntervalSince1970: timestamp)
        let latestAllowed = Date().addingTimeInterval(rotationInterval)
        if due > latestAllowed {
            due = latestAllowed
        }
        nextRotationDate = due
    }

    private func persistNextRotationDate() {
        let value = nextRotationDate.map { $0.timeIntervalSince1970 as CFNumber }
        CFPreferencesSetAppValue(Self.nextRotationKey, value, ManagedPreferences.domain as CFString)
        CFPreferencesAppSynchronize(ManagedPreferences.domain as CFString)
    }

    private func rotateNow() {
        let pool = rotationPool
        guard !pool.isEmpty else { return }
        let next: CuratedWallpaper
        if prefs.autoRotateShuffle {
            let candidates = pool.filter { $0.id != prefs.selectedWallpaperID && !isCurrent($0) }
            next = candidates.randomElement() ?? pool[0]
        } else if let anchorIndex = rotationAnchorIndex(in: pool) {
            next = pool[(anchorIndex + 1) % pool.count]
        } else {
            next = pool[0]
        }
        apply(next)
    }
}
