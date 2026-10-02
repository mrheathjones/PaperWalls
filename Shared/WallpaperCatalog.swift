import AppKit
import CryptoKit
import Foundation
import os

/// One selectable wallpaper: shipped inside the app bundle, discovered in the
/// MDM-managed folder, or discovered in the user's personal folder.
struct CuratedWallpaper: Codable, Identifiable, Hashable {
    enum Source: String, Codable {
        case bundled
        case external     // MDM-managed folder (externalWallpaperFolderPath)
        case personal     // user's personal library (spec §5)
        case appCurated   // app-curated remote feed (spec §4)
        case orgRemote    // org remote feed (spec §4)
        case system       // macOS built-ins (/System/Library/Desktop Pictures)
    }

    let id: String
    let filename: String
    let displayName: String
    let thumbnailFilename: String?
    let collection: String?
    let source: Source

    /// The pre-spec-§6 path-derived ID (`external-<hash>`) for folder
    /// wallpapers, so IDs pinned in old profiles keep resolving. Computed at
    /// scan time — never serialized.
    let legacyID: String?

    private enum CodingKeys: String, CodingKey {
        case id, filename, displayName, thumbnailFilename, collection, source
    }

    init(id: String,
         filename: String,
         displayName: String,
         thumbnailFilename: String? = nil,
         collection: String? = nil,
         source: Source,
         legacyID: String? = nil) {
        self.id = id
        self.filename = filename
        self.displayName = displayName
        self.thumbnailFilename = thumbnailFilename
        self.collection = collection
        self.source = source
        self.legacyID = legacyID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        filename = try container.decode(String.self, forKey: .filename)
        displayName = try container.decode(String.self, forKey: .displayName)
        thumbnailFilename = try container.decodeIfPresent(String.self, forKey: .thumbnailFilename)
        collection = try container.decodeIfPresent(String.self, forKey: .collection)
        source = try container.decodeIfPresent(Source.self, forKey: .source) ?? .bundled
        legacyID = nil
    }
}

/// The resolved set of wallpapers available right now, plus URL resolution.
struct WallpaperLibrary {
    var bundled: [CuratedWallpaper] = []
    var managed: [CuratedWallpaper] = []
    var personal: [CuratedWallpaper] = []
    var appCurated: [CuratedWallpaper] = []
    var orgRemote: [CuratedWallpaper] = []
    var system: [CuratedWallpaper] = []
    /// macOS wallpapers that need an explicit download first (GUI-only).
    var systemPending: [SystemAssetEntry] = []
    var bundledFolderURL: URL?
    var managedFolderURL: URL?
    var personalFolderURL: URL?
    var appCuratedFolderURL: URL?
    var orgRemoteFolderURL: URL?
    var systemFolderURL: URL?

    var all: [CuratedWallpaper] { bundled + system + appCurated + orgRemote + managed + personal }

    /// Bundled collection names in catalog order, without duplicates.
    var collections: [String] {
        var seen = Set<String>()
        return bundled.compactMap { wallpaper in
            guard let collection = wallpaper.collection, seen.insert(collection).inserted else {
                return nil
            }
            return collection
        }
    }

    /// Looks up by the canonical ID, falling back to the legacy path-derived
    /// ID so pre-§6 profiles (e.g. a forced `selectedWallpaperID` of
    /// `external-…`) keep resolving.
    func wallpaper(withID id: String) -> CuratedWallpaper? {
        all.first { $0.id == id } ?? all.first { $0.legacyID == id }
    }

    /// Applies the showBundledWallpapers / allowedWallpaperIDs policy.
    /// When bundled wallpapers are hidden and both folders are empty this
    /// intentionally returns [] — the picker shows an empty state rather
    /// than silently overriding the toggle with the bundled set.
    func visibleWallpapers(showBundled: Bool, allowedIDs: [String]?) -> [CuratedWallpaper] {
        var visible = (showBundled ? bundled : []) + system + appCurated + orgRemote + managed + personal
        if let allowedIDs, !allowedIDs.isEmpty {
            let allowed = Set(allowedIDs)
            visible = visible.filter { allowed.contains($0.id) }
        }
        return visible
    }

    private func folderURL(for source: CuratedWallpaper.Source) -> URL? {
        switch source {
        case .bundled: return bundledFolderURL
        case .external: return managedFolderURL
        case .personal: return personalFolderURL
        case .appCurated: return appCuratedFolderURL
        case .orgRemote: return orgRemoteFolderURL
        case .system: return systemFolderURL
        }
    }

    /// Filenames are folder-relative, except macOS on-demand assets whose
    /// cache lives outside the source folder — those carry absolute paths.
    func fileURL(for wallpaper: CuratedWallpaper) -> URL? {
        if wallpaper.filename.hasPrefix("/") {
            return URL(fileURLWithPath: wallpaper.filename)
        }
        return folderURL(for: wallpaper.source)?.appendingPathComponent(wallpaper.filename)
    }

    /// Bundled and feed wallpapers carry a pre-rendered thumbnail file;
    /// folder-based ones fall back to the full image, downsampled at
    /// render time.
    func thumbnailURL(for wallpaper: CuratedWallpaper) -> URL? {
        if let thumbnailFilename = wallpaper.thumbnailFilename {
            if thumbnailFilename.hasPrefix("/") {
                return URL(fileURLWithPath: thumbnailFilename)
            }
            return folderURL(for: wallpaper.source)?.appendingPathComponent(thumbnailFilename)
        }
        return fileURL(for: wallpaper)
    }
}

/// Where the "Personal" source draws from (spec §5).
enum PersonalFolderSource: String, CaseIterable {
    /// Fixed app-managed folder; users add images by dropping them onto the
    /// Personal page (files are copied in).
    case appManaged
    /// A user-chosen folder (`personalWallpaperFolderPath`). Still fully
    /// functional for existing setups and admin-forced configs, but there is
    /// deliberately no Settings UI to select it yet (spec §5 feature flag).
    case userDefined

    /// Pure resolution: an explicit `personalFolderSource` value wins;
    /// otherwise an already-configured user folder keeps working (legacy
    /// compat) and fresh setups get the app-managed folder.
    static func resolve(raw: String?, userDefinedPath: String?) -> PersonalFolderSource {
        if let raw, let source = PersonalFolderSource(rawValue: raw) {
            return source
        }
        if let userDefinedPath, !userDefinedPath.isEmpty {
            return .userDefined
        }
        return .appManaged
    }
}

/// The app-managed personal wallpaper library (spec §5): a fixed per-user
/// folder the app owns, filled by importing dropped images.
enum PersonalFolder {
    static var appManagedPath: String {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaperWalls/Personal", isDirectory: true)
            .path
    }

    /// The folder the Personal source scans in the given mode (nil = none).
    static func effectivePath(source: PersonalFolderSource, userDefinedPath: String?) -> String? {
        switch source {
        case .appManaged:
            return appManagedPath
        case .userDefined:
            guard let userDefinedPath, !userDefinedPath.isEmpty else { return nil }
            return userDefinedPath
        }
    }

    /// Live-preference convenience for the CLI and migration paths.
    static func effectivePathFromPreferences() -> String? {
        let userPath = ManagedPreferences.string(.personalWallpaperFolderPath)
        return effectivePath(source: PersonalFolderSource.resolve(raw: ManagedPreferences.string(.personalFolderSource),
                                                                  userDefinedPath: userPath),
                             userDefinedPath: userPath)
    }

    static func ensureAppManagedFolderExists() {
        try? FileManager.default.createDirectory(atPath: appManagedPath,
                                                 withIntermediateDirectories: true)
    }

    /// Copies dropped image files into the app-managed folder, de-duping
    /// filenames. Non-images (and folders) are skipped. Returns how many
    /// files were imported.
    @discardableResult
    static func importImages(at urls: [URL]) -> Int {
        ensureAppManagedFolderExists()
        let folderURL = URL(fileURLWithPath: appManagedPath, isDirectory: true)
        let fileManager = FileManager.default
        var existing = Set((try? fileManager.contentsOfDirectory(atPath: appManagedPath))?
            .map { $0.lowercased() } ?? [])
        var imported = 0
        for url in urls where WallpaperCatalog.supportedExtensions.contains(url.pathExtension.lowercased()) {
            let name = uniqueFilename(url.lastPathComponent, existingLowercased: existing)
            do {
                try fileManager.copyItem(at: url, to: folderURL.appendingPathComponent(name))
                existing.insert(name.lowercased())
                imported += 1
            } catch {
                WallpaperCatalog.log.error("Import failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return imported
    }

    /// "photo.jpg" → "photo 2.jpg" → "photo 3.jpg"… against a
    /// case-insensitive set of names already in the folder.
    static func uniqueFilename(_ filename: String, existingLowercased: Set<String>) -> String {
        guard existingLowercased.contains(filename.lowercased()) else { return filename }
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            if !existingLowercased.contains(candidate.lowercased()) {
                return candidate
            }
            counter += 1
        }
    }
}

enum WallpaperCatalog {
    // FUTURE: route through PaperLog multi-sink (spec §9, deferred).
    static let log = Logger(subsystem: ManagedPreferences.domain, category: "catalog")

    static let wallpapersSubdirectory = "Wallpapers"
    static let catalogResourceName = "catalog"
    static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "tiff"]

    /// Flip to scan the external wallpaper folders recursively.
    static let scansExternalFolderRecursively = false

    /// Bundle identifier and name of the GUI app; the CLI uses them to
    /// locate the bundled catalog inside the installed app.
    static let guiAppBundleIdentifier = ManagedPreferences.domain
    static let guiAppName = "PaperWalls.app"

    private struct CatalogFile: Codable {
        let wallpapers: [CuratedWallpaper]
    }

    /// macOS's built-in wallpapers. Only the flat image files scan — the
    /// `.madesktop` dynamic/aerial bundles aren't settable via
    /// setDesktopImageURL and are skipped by the extension filter.
    static let systemWallpapersPath = "/System/Library/Desktop Pictures"

    /// Loads bundled + system + managed-folder + personal-folder wallpapers.
    /// Either folder path may be nil/empty, missing on disk, or unreadable —
    /// all degrade to an empty list for that source.
    static func load(managedFolderPath: String?,
                     personalFolderPath: String?,
                     includeSystemWallpapers: Bool = true) -> WallpaperLibrary {
        var library = WallpaperLibrary()

        if includeSystemWallpapers {
            library.systemFolderURL = URL(fileURLWithPath: systemWallpapersPath, isDirectory: true)
            let scanned = SystemWallpaperStore.scan()
            library.system = scanned.ready
            library.systemPending = scanned.pending
        }

        if let bundle = resourceBundle(),
           let catalogURL = bundle.url(forResource: catalogResourceName,
                                       withExtension: "json",
                                       subdirectory: wallpapersSubdirectory) {
            do {
                let data = try Data(contentsOf: catalogURL)
                library.bundled = try JSONDecoder().decode(CatalogFile.self, from: data).wallpapers
                library.bundledFolderURL = catalogURL.deletingLastPathComponent()
            } catch {
                log.error("Failed to load bundled catalog: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            log.info("No bundled wallpaper catalog found")
        }

        if let folderURL = folderURL(fromPath: managedFolderPath) {
            library.managedFolderURL = folderURL
            library.managed = scanFolder(at: folderURL, source: .external)
        }
        if let folderURL = folderURL(fromPath: personalFolderPath) {
            library.personalFolderURL = folderURL
            library.personal = scanFolder(at: folderURL, source: .personal)
        }

        return library
    }

    /// Content-ID hash cache used by folder scans; tests swap in a scratch
    /// cache so they never touch the user's real cache file.
    static var contentIDCache = ContentIDCache.shared

    static func folderURL(fromPath path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    /// Lists supported images directly in a wallpaper folder (non-recursive
    /// by default; see `scansExternalFolderRecursively`).
    ///
    /// TODO: If this app is ever sandboxed (App Store distribution), folders
    /// under the user's home directory will need security-scoped bookmarks.
    /// This build targets non-sandboxed .pkg distribution, so plain
    /// FileManager access is sufficient.
    static func scanFolder(at folderURL: URL, source: CuratedWallpaper.Source) -> [CuratedWallpaper] {
        // FUTURE: cloud-backed user folders (spec §9) — a dataless/iCloud
        // placeholder handler slots in here (detect unmaterialized files,
        // skip or fetch on demand). No iCloud materialization yet.
        let wallpapers = imageFiles(in: folderURL).map { url in
            // Content-derived identity (spec §6) survives moves and folder
            // switches; the path hash stays as the fallback for unreadable
            // files and as the legacy alias for old profiles.
            let legacyID = legacyPathID(forPath: url.path)
            return CuratedWallpaper(id: contentIDCache.contentID(forFileAt: url) ?? legacyID,
                                    filename: relativeFilename(of: url, in: folderURL),
                                    displayName: url.deletingPathExtension().lastPathComponent,
                                    thumbnailFilename: nil,
                                    collection: nil,
                                    source: source,
                                    legacyID: legacyID)
        }
        contentIDCache.flushIfDirty()
        return wallpapers
    }

    /// Supported images directly in `folderURL`, sorted for display.
    static func imageFiles(in folderURL: URL) -> [URL] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            log.info("Wallpaper folder missing: \(folderURL.path, privacy: .public)")
            return []
        }

        let contents: [URL]
        if scansExternalFolderRecursively {
            contents = deepContents(of: folderURL, fileManager: fileManager)
        } else {
            do {
                contents = try fileManager.contentsOfDirectory(at: folderURL,
                                                               includingPropertiesForKeys: [.isRegularFileKey],
                                                               options: [.skipsHiddenFiles])
            } catch {
                log.error("Cannot read wallpaper folder \(folderURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return []
            }
        }

        return contents
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Pre-§6 identifier for a folder wallpaper, derived from its absolute
    /// path. Kept for the one-time favorites/selection remap and as the
    /// legacy alias on scanned wallpapers.
    static func legacyPathID(forPath path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        return WallpaperContentID.legacyIDPrefix + hex
    }

    /// The bundle carrying Resources/Wallpapers. For the GUI app (or a CLI
    /// embedded inside it) that is Bundle.main; a standalone CLI falls back
    /// to a sibling app, the standard install locations, and finally a
    /// LaunchServices lookup by bundle identifier.
    static func resourceBundle() -> Bundle? {
        if hasCatalog(Bundle.main) {
            return Bundle.main
        }

        // For a bare command-line tool, bundleURL is the executable's directory.
        var candidates: [URL] = [
            Bundle.main.bundleURL.appendingPathComponent(guiAppName),
            URL(fileURLWithPath: "/Applications").appendingPathComponent(guiAppName),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications")
                .appendingPathComponent(guiAppName),
        ]
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: guiAppBundleIdentifier) {
            candidates.append(appURL)
        }
        for url in candidates {
            if let bundle = Bundle(url: url), hasCatalog(bundle) {
                return bundle
            }
        }
        return nil
    }

    private static func hasCatalog(_ bundle: Bundle) -> Bool {
        bundle.url(forResource: catalogResourceName,
                   withExtension: "json",
                   subdirectory: wallpapersSubdirectory) != nil
    }

    private static func deepContents(of folderURL: URL, fileManager: FileManager) -> [URL] {
        guard let enumerator = fileManager.enumerator(at: folderURL,
                                                      includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else {
            log.error("Cannot enumerate wallpaper folder \(folderURL.path, privacy: .public)")
            return []
        }
        return enumerator.compactMap { $0 as? URL }
    }

    private static func relativeFilename(of url: URL, in folderURL: URL) -> String {
        let filePath = url.standardizedFileURL.path
        let base = folderURL.standardizedFileURL.path + "/"
        return filePath.hasPrefix(base) ? String(filePath.dropFirst(base.count)) : url.lastPathComponent
    }
}
