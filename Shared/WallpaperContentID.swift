import CryptoKit
import Foundation
import os

/// Content-derived identity for folder wallpapers (migration spec §6).
///
/// Folder wallpapers used to be identified by a hash of their absolute path
/// (`external-<hash>`), so moving a file — or switching the personal folder
/// mode — orphaned favorites and `selectedWallpaperID`. IDs are now derived
/// from the file's bytes (`file:<hash>`), so identity survives renames,
/// moves, and folder switches. Accepted trade-off: byte-identical duplicates
/// collapse to one ID. Bundled/manifest IDs stay author-assigned.
enum WallpaperContentID {
    static let idPrefix = "file:"
    static let legacyIDPrefix = "external-"

    /// Files larger than two chunks are fingerprinted from their head + tail
    /// chunks instead of every byte; the byte size is always mixed in.
    static let fingerprintChunkBytes = 1 << 20   // 1 MiB

    static func isContentID(_ id: String) -> Bool { id.hasPrefix(idPrefix) }
    static func isLegacyPathID(_ id: String) -> Bool { id.hasPrefix(legacyIDPrefix) }

    /// size + modification date without URL's per-object resource-value
    /// cache, which can return stale values after a file changes.
    static func stat(_ url: URL) -> (size: Int, modified: TimeInterval)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 else {
            return nil
        }
        return (size, modified)
    }

    /// Fingerprints the file at `url`: SHA-256 over (byte size + full bytes),
    /// or (byte size + first/last chunk) for large files. nil when the file
    /// cannot be read — callers fall back to the legacy path-derived ID.
    static func id(forFileAt url: URL) -> String? {
        guard let size = stat(url)?.size,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        withUnsafeBytes(of: UInt64(size).littleEndian) { hasher.update(bufferPointer: $0) }
        do {
            if size <= fingerprintChunkBytes * 2 {
                hasher.update(data: try handle.readToEnd() ?? Data())
            } else {
                hasher.update(data: try handle.read(upToCount: fingerprintChunkBytes) ?? Data())
                try handle.seek(toOffset: UInt64(size - fingerprintChunkBytes))
                hasher.update(data: try handle.read(upToCount: fingerprintChunkBytes) ?? Data())
            }
        } catch {
            return nil
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(16)
        return idPrefix + hex
    }
}

/// Per-user cache of content IDs keyed by path + modification date + size,
/// so rescans only hash new or changed files (spec §6). Persisted alongside
/// the app's other per-user state; a lost or unreadable cache just means
/// files get re-hashed.
final class ContentIDCache {
    static let shared = ContentIDCache()

    struct Entry: Codable, Equatable {
        let size: Int
        let modified: TimeInterval
        let id: String
    }

    private let cacheFileURL: URL
    private let lock = NSLock()
    private var entries: [String: Entry]?   // nil until first load
    private var dirty = false

    /// Default cache lives in the per-user Application Support directory;
    /// tests inject a scratch location.
    init(cacheFileURL: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaperWalls/content-id-cache.json")) {
        self.cacheFileURL = cacheFileURL
    }

    /// The content ID for `url`, from cache when the file is unchanged.
    /// nil when the file cannot be statted or read.
    func contentID(forFileAt url: URL) -> String? {
        guard let (size, modified) = WallpaperContentID.stat(url) else { return nil }
        let path = url.standardizedFileURL.path

        lock.lock()
        loadIfNeeded()
        if let entry = entries?[path], entry.size == size, entry.modified == modified {
            lock.unlock()
            return entry.id
        }
        lock.unlock()

        guard let id = WallpaperContentID.id(forFileAt: url) else { return nil }

        lock.lock()
        entries?[path] = Entry(size: size, modified: modified, id: id)
        dirty = true
        lock.unlock()
        return id
    }

    /// Writes the cache back to disk if anything changed this scan.
    func flushIfDirty() {
        lock.lock()
        defer { lock.unlock() }
        guard dirty, let entries else { return }
        do {
            try FileManager.default.createDirectory(at: cacheFileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: cacheFileURL, options: .atomic)
            dirty = false
        } catch {
            WallpaperCatalog.log.error("Cannot persist content-ID cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadIfNeeded() {
        guard entries == nil else { return }
        if let data = try? Data(contentsOf: cacheFileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }
}

/// One-time upgrade from path-derived to content-derived folder IDs
/// (spec §6): for files still present in the configured folders, rewrite
/// `favoriteWallpaperIDs` and `selectedWallpaperID` from the old ID to the
/// new one. Legacy IDs whose file is gone (or whose folder is currently
/// unreachable) are left in place — re-checking them is a cheap prefix scan,
/// so the remap retries on the next launch instead of orphaning them behind
/// a done-marker.
enum ContentIDMigration {
    /// Pure remap: substitutes mapped IDs and de-duplicates (two paths that
    /// held identical bytes collapse to one content ID) preserving order.
    static func remap(ids: [String], mapping: [String: String]) -> [String] {
        var seen = Set<String>()
        return ids.compactMap { id in
            let mapped = mapping[id] ?? id
            return seen.insert(mapped).inserted ? mapped : nil
        }
    }

    /// Runs the remap against live preferences. Returns true when anything
    /// was rewritten (callers reload their preference mirror).
    @discardableResult
    static func migrateIfNeeded() -> Bool {
        let favorites = ManagedPreferences.stringArray(.favoriteWallpaperIDs) ?? []
        let selected = ManagedPreferences.string(.selectedWallpaperID)
        let hasLegacyIDs = favorites.contains(where: WallpaperContentID.isLegacyPathID)
            || selected.map(WallpaperContentID.isLegacyPathID) == true
        guard hasLegacyIDs else { return false }

        let mapping = legacyToContentIDMapping()
        guard !mapping.isEmpty else { return false }

        var changed = false
        let remappedFavorites = remap(ids: favorites, mapping: mapping)
        if remappedFavorites != favorites {
            ManagedPreferences.set(remappedFavorites.isEmpty ? nil : remappedFavorites,
                                   for: .favoriteWallpaperIDs)
            changed = true
        }
        if let selected, let mapped = mapping[selected] {
            ManagedPreferences.set(mapped, for: .selectedWallpaperID)
            changed = true
        }
        if changed {
            WallpaperCatalog.log.notice("Migrated path-derived wallpaper IDs to content IDs")
        }
        return changed
    }

    /// old path-derived ID → new content ID, for every image currently in
    /// the managed and personal folders. The stored user-defined personal
    /// path is scanned even when the mode is app-managed: legacy favorites
    /// point at files there, and their content IDs must carry over.
    private static func legacyToContentIDMapping() -> [String: String] {
        var mapping: [String: String] = [:]
        let folderPaths = [ManagedPreferences.string(.externalWallpaperFolderPath),
                           ManagedPreferences.string(.personalWallpaperFolderPath),
                           PersonalFolder.appManagedPath]
        for path in folderPaths {
            guard let folderURL = WallpaperCatalog.folderURL(fromPath: path) else { continue }
            for url in WallpaperCatalog.imageFiles(in: folderURL) {
                if let contentID = WallpaperCatalog.contentIDCache.contentID(forFileAt: url) {
                    mapping[WallpaperCatalog.legacyPathID(forPath: url.path)] = contentID
                }
            }
        }
        WallpaperCatalog.contentIDCache.flushIfDirty()
        return mapping
    }
}
