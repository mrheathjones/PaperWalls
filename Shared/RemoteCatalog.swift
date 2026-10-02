import CryptoKit
import Foundation
import os

/// A remote wallpaper feed (spec §4): the app-curated feed (URL + public
/// key baked in) or an org feed (both provided by MDM/local config).
struct RemoteFeed {
    enum Kind: String {
        case appCurated
        case orgRemote
    }

    let kind: Kind
    let manifestURL: URL
    let publicKeyBase64: String

    /// The app-curated feed. Constants are deliberately baked in — rotating
    /// either means shipping an app update. The values below are placeholders:
    /// point them at your own feed (see Deployment/publish-feed.sh) before
    /// enabling `appCuratedEnabled`.
    static let appCurated = RemoteFeed(
        kind: .appCurated,
        manifestURL: URL(string: "https://feed.example.com/catalog.json")!,
        publicKeyBase64: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")

    /// The org feed, from `orgCatalogURL` + `orgCatalogPublicKey`. nil until
    /// both are present and valid — a half-configured feed stays off.
    static func org(urlString: String?, publicKeyBase64: String?) -> RemoteFeed? {
        guard let urlString, let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true,
              let publicKeyBase64, !publicKeyBase64.isEmpty else {
            return nil
        }
        return RemoteFeed(kind: .orgRemote, manifestURL: url, publicKeyBase64: publicKeyBase64)
    }

    /// `app:` / `org:` namespace (spec §4). Author-assigned IDs that already
    /// carry the right prefix are kept as-is.
    var idPrefix: String { kind == .appCurated ? "app:" : "org:" }

    func namespacedID(_ id: String) -> String {
        id.hasPrefix(idPrefix) ? id : idPrefix + id
    }

    var signatureURL: URL {
        manifestURL.appendingPathExtension("sig")
    }
}

/// catalog.json v2 (spec §4). `image`/`thumbnail` may be absolute URLs or
/// relative to the manifest.
struct RemoteManifest: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let id: String
        let displayName: String
        let collection: String?
        let image: String
        let thumbnail: String?
        let sha256: String
        let size: Int
        let minAppVersion: String?
    }

    let version: Int
    let wallpapers: [Entry]

    static let supportedVersion = 2

    static func parse(data: Data) -> RemoteManifest? {
        guard let manifest = try? JSONDecoder().decode(RemoteManifest.self, from: data),
              manifest.version == supportedVersion else {
            return nil
        }
        return manifest
    }

    /// Entries this app version may show (minAppVersion filter).
    func entries(forAppVersion appVersion: String) -> [Entry] {
        wallpapers.filter { entry in
            guard let required = entry.minAppVersion else { return true }
            return RemoteManifest.version(appVersion, isAtLeast: required)
        }
    }

    /// Numeric dot-component comparison ("1.10" ≥ "1.9").
    static func version(_ current: String, isAtLeast required: String) -> Bool {
        let currentParts = current.split(separator: ".").map { Int($0) ?? 0 }
        let requiredParts = required.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(currentParts.count, requiredParts.count) {
            let lhs = index < currentParts.count ? currentParts[index] : 0
            let rhs = index < requiredParts.count ? requiredParts[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return true
    }
}

/// Ed25519 manifest verification. The signature file holds base64 (or raw
/// 64 bytes) of the signature over the exact manifest bytes.
enum RemoteManifestVerifier {
    static func verify(manifestData: Data, signature: Data, publicKeyBase64: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            return false
        }
        let rawSignature: Data
        if signature.count == 64 {
            rawSignature = signature
        } else if let text = String(data: signature, encoding: .utf8),
                  let decoded = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            rawSignature = decoded
        } else {
            return false
        }
        return key.isValidSignature(rawSignature, for: manifestData)
    }
}

/// Signed-feed sync + cache (spec §4). Layout per feed under
/// `~/Library/Application Support/PaperWalls/RemoteCache/<kind>/`:
///   manifest.json   last-good VERIFIED manifest (atomic swap)
///   etag.txt        for conditional refetches
///   assets/<sha256>.<ext>, thumbs/<sha256>.<ext>   content-addressed
/// Every failure path keeps the last-good cache; offline means the feed
/// simply stays at its previous state (else bundled-only).
enum RemoteCatalog {
    // FUTURE: route through PaperLog multi-sink (spec §9, deferred).
    static let log = Logger(subsystem: ManagedPreferences.domain, category: "remotecatalog")

    /// Tests point this at a scratch directory.
    static var cacheRootOverride: URL?

    static var cacheRoot: URL {
        cacheRootOverride ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaperWalls/RemoteCache", isDirectory: true)
    }

    static func cacheDirectory(for feed: RemoteFeed) -> URL {
        cacheRoot.appendingPathComponent(feed.kind.rawValue, isDirectory: true)
    }

    private static func assetsDirectory(for feed: RemoteFeed) -> URL {
        cacheDirectory(for: feed).appendingPathComponent("assets", isDirectory: true)
    }

    private static func thumbsDirectory(for feed: RemoteFeed) -> URL {
        cacheDirectory(for: feed).appendingPathComponent("thumbs", isDirectory: true)
    }

    static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    // FUTURE: cloud/placeholder wallpaper handler (spec §9) — on-demand
    // asset materialization (download-on-apply instead of download-on-sync)
    // would slot in around loadCached/sync. Not built yet.

    // MARK: - Cached read (no network — the ONLY path the CLI uses)

    /// Wallpapers from the last-good cache whose image file is present.
    /// `filename`/`thumbnailFilename` are relative to the feed's cache dir.
    static func loadCached(feed: RemoteFeed,
                           appVersion: String = currentAppVersion) -> (wallpapers: [CuratedWallpaper], folderURL: URL) {
        let folder = cacheDirectory(for: feed)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = RemoteManifest.parse(data: data) else {
            return ([], folder)
        }
        let fileManager = FileManager.default
        let source: CuratedWallpaper.Source = feed.kind == .appCurated ? .appCurated : .orgRemote
        let wallpapers = manifest.entries(forAppVersion: appVersion).compactMap { entry -> CuratedWallpaper? in
            let assetName = assetFilename(for: entry)
            guard fileManager.fileExists(atPath: folder.appendingPathComponent("assets/\(assetName)").path) else {
                return nil
            }
            let thumbName = thumbFilename(for: entry)
            let hasThumb = thumbName.map {
                fileManager.fileExists(atPath: folder.appendingPathComponent("thumbs/\($0)").path)
            } ?? false
            return CuratedWallpaper(id: feed.namespacedID(entry.id),
                                    filename: "assets/\(assetName)",
                                    displayName: entry.displayName,
                                    thumbnailFilename: hasThumb ? "thumbs/\(thumbName!)" : nil,
                                    collection: entry.collection,
                                    source: source)
        }
        return (wallpapers, folder)
    }

    /// Content-addressed local names: the image's sha256 + its extension.
    static func assetFilename(for entry: RemoteManifest.Entry) -> String {
        let ext = URL(string: entry.image)?.pathExtension.lowercased() ?? ""
        return ext.isEmpty ? entry.sha256 : "\(entry.sha256).\(ext)"
    }

    static func thumbFilename(for entry: RemoteManifest.Entry) -> String? {
        guard let thumbnail = entry.thumbnail else { return nil }
        let ext = URL(string: thumbnail)?.pathExtension.lowercased() ?? ""
        return ext.isEmpty ? "\(entry.sha256)-thumb" : "\(entry.sha256)-thumb.\(ext)"
    }

    /// Pure eviction rule: anything on disk the manifest no longer names.
    static func filesToEvict(existing: Set<String>, referenced: Set<String>) -> Set<String> {
        existing.subtracting(referenced)
    }

    // MARK: - Sync (network; callers gate on the resolver keys — spec §4
    // air-gap guarantee: both feed gates false + no folder ⇒ zero network)

    /// Returns true when the local cache changed. All failures log and
    /// leave the last-good cache untouched.
    @discardableResult
    static func sync(feed: RemoteFeed,
                     appVersion: String = currentAppVersion,
                     session: URLSession = .shared) async -> Bool {
        let folder = cacheDirectory(for: feed)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: assetsDirectory(for: feed), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: thumbsDirectory(for: feed), withIntermediateDirectories: true)
        } catch {
            log.error("Cannot create feed cache: \(error.localizedDescription, privacy: .public)")
            return false
        }

        // 1. Conditional manifest fetch.
        var request = URLRequest(url: feed.manifestURL)
        let etagFile = folder.appendingPathComponent("etag.txt")
        if let etag = try? String(contentsOf: etagFile, encoding: .utf8) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        guard let (manifestData, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            log.info("Feed \(feed.kind.rawValue, privacy: .public): manifest fetch failed; keeping last-good cache")
            return false
        }
        if http.statusCode == 304 {
            return false
        }
        guard http.statusCode == 200, !manifestData.isEmpty else {
            log.error("Feed \(feed.kind.rawValue, privacy: .public): manifest HTTP \(http.statusCode)")
            return false
        }

        // 2. Signature — REQUIRED. An unsigned or tampered manifest never lands.
        guard let (signatureData, sigResponse) = try? await session.data(from: feed.signatureURL),
              (sigResponse as? HTTPURLResponse)?.statusCode == 200,
              RemoteManifestVerifier.verify(manifestData: manifestData,
                                            signature: signatureData,
                                            publicKeyBase64: feed.publicKeyBase64) else {
            log.error("Feed \(feed.kind.rawValue, privacy: .public): signature missing or invalid; keeping last-good cache")
            return false
        }

        // 3. Parse.
        guard let manifest = RemoteManifest.parse(data: manifestData) else {
            log.error("Feed \(feed.kind.rawValue, privacy: .public): unparseable or unsupported manifest version")
            return false
        }
        let entries = manifest.entries(forAppVersion: appVersion)

        // 4. Download added/changed assets (content-addressed → a present
        // file is by definition current). sha256-verify every download.
        for entry in entries {
            let assetURL = assetsDirectory(for: feed).appendingPathComponent(assetFilename(for: entry))
            if !fileManager.fileExists(atPath: assetURL.path) {
                guard let remote = URL(string: entry.image, relativeTo: feed.manifestURL),
                      await download(from: remote, to: assetURL, expectedSHA256: entry.sha256, session: session) else {
                    log.error("Feed \(feed.kind.rawValue, privacy: .public): asset failed for \(entry.id, privacy: .public); keeping last-good cache")
                    return false
                }
            }
            if let thumbName = thumbFilename(for: entry) {
                let thumbURL = thumbsDirectory(for: feed).appendingPathComponent(thumbName)
                if !fileManager.fileExists(atPath: thumbURL.path),
                   let remote = URL(string: entry.thumbnail ?? "", relativeTo: feed.manifestURL) {
                    // Thumbs are cosmetic — a failed thumb never fails the sync.
                    _ = await download(from: remote, to: thumbURL, expectedSHA256: nil, session: session)
                }
            }
        }

        // 5. Atomic manifest swap + etag, then evict unreferenced files.
        do {
            try manifestData.write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        } catch {
            log.error("Feed \(feed.kind.rawValue, privacy: .public): cannot persist manifest: \(error.localizedDescription, privacy: .public)")
            return false
        }
        if let etag = http.value(forHTTPHeaderField: "ETag") {
            try? etag.write(to: etagFile, atomically: true, encoding: .utf8)
        }
        evict(feed: feed, keepingAssets: Set(entries.map(assetFilename(for:))),
              thumbs: Set(entries.compactMap(thumbFilename(for:))))
        log.notice("Feed \(feed.kind.rawValue, privacy: .public): synced \(entries.count) wallpaper(s)")
        return true
    }

    private static func download(from remote: URL, to destination: URL,
                                 expectedSHA256: String?, session: URLSession) async -> Bool {
        guard let (data, response) = try? await session.data(from: remote),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return false
        }
        if let expectedSHA256 {
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == expectedSHA256.lowercased() else {
                log.error("sha256 mismatch for \(remote.lastPathComponent, privacy: .public)")
                return false
            }
        }
        do {
            try data.write(to: destination, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func evict(feed: RemoteFeed, keepingAssets: Set<String>, thumbs: Set<String>) {
        let fileManager = FileManager.default
        for (directory, keep) in [(assetsDirectory(for: feed), keepingAssets),
                                  (thumbsDirectory(for: feed), thumbs)] {
            let existing = Set((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
            for name in filesToEvict(existing: existing, referenced: keep) {
                try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }
}
