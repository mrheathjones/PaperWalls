import Foundation
import os

/// A macOS built-in wallpaper that isn't on disk yet. Modern macOS ships
/// most of its wallpapers as `.madesktop` descriptors whose full-resolution
/// image is fetched on demand (the "download" button in System Settings).
/// The descriptor names a MobileAsset ID and a small preview in
/// `.thumbnails/`; the OS's world-readable MobileAsset catalog maps that ID
/// to a public Apple CDN zip containing `AssetData/<Name>.heic`.
struct SystemAssetEntry: Identifiable, Hashable {
    let assetID: String          // mobileAssetID == catalog DesktopPictureID
    let displayName: String
    let thumbnailPath: String?   // Apple's preview in .thumbnails/
    let downloadURL: URL?        // nil = catalog unavailable (offline/air-gap)
    let downloadSize: Int?

    /// Stable, machine-independent ID (usable in allowedWallpaperIDs).
    var id: String { "macos:" + assetID }
}

/// Scans and materializes macOS built-in wallpapers (the "macOS" source).
/// Flat images in /System/Library/Desktop Pictures apply directly; the
/// on-demand ones surface as `pending` entries until the user explicitly
/// downloads them — the ONLY time this type touches the network.
enum SystemWallpaperStore {
    // FUTURE: route through PaperLog multi-sink (spec §9, deferred).
    static let log = Logger(subsystem: ManagedPreferences.domain, category: "systemwallpapers")

    static let mobileAssetCatalogPath =
        "/System/Library/AssetsV2/com_apple_MobileAsset_DesktopPicture/com_apple_MobileAsset_DesktopPicture.xml"

    /// Apple's public MobileAsset catalog — the same document the OS caches
    /// at `mobileAssetCatalogPath`. Fetched only when the local copy is
    /// absent (fresh/managed Macs often haven't populated it) AND downloads
    /// are allowed; stored beside our wallpaper cache.
    static let mesuCatalogURL =
        URL(string: "https://mesu.apple.com/assets/macos/com_apple_MobileAsset_DesktopPicture/com_apple_MobileAsset_DesktopPicture.xml")!

    static var cachedCatalogURL: URL {
        cacheDirectory.appendingPathComponent("mobileasset-catalog.xml")
    }

    /// Downloaded full-res images live in the app's own per-user cache
    /// (System Settings' own downloads land in SIP-protected asset stores
    /// with unstable paths, so we keep our own copies).
    static var cacheDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaperWalls/SystemWallpapers", isDirectory: true)
    }

    static func cachedFileURL(assetID: String) -> URL {
        cacheDirectory.appendingPathComponent("\(assetID).heic")
    }

    // MARK: - Scan (disk only)

    /// Everything the macOS source offers: `ready` wallpapers (flat files +
    /// already-downloaded assets, absolute-path filenames) and `pending`
    /// on-demand entries.
    static func scan() -> (ready: [CuratedWallpaper], pending: [SystemAssetEntry]) {
        let folderURL = URL(fileURLWithPath: WallpaperCatalog.systemWallpapersPath, isDirectory: true)
        var ready = WallpaperCatalog.scanFolder(at: folderURL, source: .system)

        let downloads = catalogDownloadMap()
        var pending: [SystemAssetEntry] = []
        let descriptors = ((try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) ?? [])
            .filter { $0.hasSuffix(".madesktop") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        for descriptorName in descriptors {
            let descriptorURL = folderURL.appendingPathComponent(descriptorName)
            guard let data = try? Data(contentsOf: descriptorURL),
                  let descriptor = parseDescriptor(data: data) else {
                continue
            }
            let displayName = (descriptorName as NSString).deletingPathExtension
            let cached = cachedFileURL(assetID: descriptor.assetID)
            if FileManager.default.fileExists(atPath: cached.path) {
                ready.append(CuratedWallpaper(id: "macos:" + descriptor.assetID,
                                              filename: cached.path,
                                              displayName: displayName,
                                              thumbnailFilename: descriptor.thumbnailPath,
                                              collection: nil,
                                              source: .system))
            } else {
                let download = downloads[descriptor.assetID]
                pending.append(SystemAssetEntry(assetID: descriptor.assetID,
                                                displayName: displayName,
                                                thumbnailPath: descriptor.thumbnailPath,
                                                downloadURL: download?.url,
                                                downloadSize: download?.size))
            }
        }
        return (ready, pending)
    }

    /// Pure `.madesktop` plist parse (unit-testable).
    static func parseDescriptor(data: Data) -> (assetID: String, thumbnailPath: String?)? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let assetID = dict["mobileAssetID"] as? String else {
            return nil
        }
        return (assetID, dict["thumbnailPath"] as? String)
    }

    /// DesktopPictureID → (CDN zip URL, size). Prefers the OS's own catalog;
    /// falls back to our fetched copy (see `refreshCatalogIfNeeded`). Empty
    /// when neither exists — pending entries then have no download offer.
    static func catalogDownloadMap(catalogPath: String = mobileAssetCatalogPath) -> [String: (url: URL, size: Int?)] {
        if let data = FileManager.default.contents(atPath: catalogPath) {
            let map = parseCatalog(data: data)
            if !map.isEmpty { return map }
        }
        if let data = FileManager.default.contents(atPath: cachedCatalogURL.path) {
            return parseCatalog(data: data)
        }
        return [:]
    }

    /// When no usable catalog exists locally, fetch Apple's public copy and
    /// cache it. Returns true when a fresh catalog landed (callers rescan).
    /// Callers gate this on `allowSystemWallpaperDownloads`.
    static func refreshCatalogIfNeeded(session: URLSession = .shared) async -> Bool {
        guard catalogDownloadMap().isEmpty else { return false }
        guard let (data, response) = try? await session.data(from: mesuCatalogURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              !parseCatalog(data: data).isEmpty else {
            log.info("MobileAsset catalog fetch failed or unusable; downloads stay unavailable")
            return false
        }
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: cachedCatalogURL, options: .atomic)
        } catch {
            return false
        }
        log.notice("Fetched Apple's wallpaper catalog (local copy was missing)")
        return true
    }

    /// Pure catalog parse (unit-testable).
    static func parseCatalog(data: Data) -> [String: (url: URL, size: Int?)] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let assets = dict["Assets"] as? [[String: Any]] else {
            return [:]
        }
        var map: [String: (url: URL, size: Int?)] = [:]
        for asset in assets {
            guard let id = asset["DesktopPictureID"] as? String,
                  let base = asset["__BaseURL"] as? String,
                  let relative = asset["__RelativePath"] as? String,
                  let url = URL(string: base + relative) else {
                continue
            }
            map[id] = (url, asset["_DownloadSize"] as? Int)
        }
        return map
    }

    // MARK: - Download (network — ONLY on explicit user action)

    enum DownloadError: LocalizedError {
        case noDownloadURL
        case badArchive

        var errorDescription: String? {
            switch self {
            case .noDownloadURL:
                return "Apple's wallpaper catalog isn't available on this Mac, so this wallpaper can't be downloaded."
            case .badArchive:
                return "The downloaded wallpaper couldn't be unpacked."
            }
        }
    }

    /// Fetches the asset zip from Apple's CDN, extracts the image, and
    /// stores it in the cache. Throws on any failure; the cache is only
    /// ever written atomically-complete.
    static func download(_ entry: SystemAssetEntry, session: URLSession = .shared) async throws {
        guard let downloadURL = entry.downloadURL else { throw DownloadError.noDownloadURL }

        let (zipURL, response) = try await session.download(from: downloadURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("paperwalls-asset-\(entry.assetID)-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // MobileAsset zips are plain zip archives; ditto is the standard
        // extraction tool for a non-sandboxed app.
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-xk", zipURL.path, workDir.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw DownloadError.badArchive }

        // The wallpaper is AssetData/<Name>.heic — take the largest image.
        let extracted = (FileManager.default.enumerator(at: workDir, includingPropertiesForKeys: [.fileSizeKey])?
            .compactMap { $0 as? URL } ?? [])
            .filter { WallpaperCatalog.supportedExtensions.contains($0.pathExtension.lowercased()) }
            .max { (lhs, rhs) in
                let l = (try? lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let r = (try? rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return l < r
            }
        guard let extracted else { throw DownloadError.badArchive }

        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let destination = cachedFileURL(assetID: entry.assetID)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: extracted, to: destination)
        log.notice("Downloaded macOS wallpaper \(entry.assetID, privacy: .public)")
    }
}
