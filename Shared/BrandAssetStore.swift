import Foundation
import os

/// What a brand asset is for. Only a label for browsing — any kind can be
/// used anywhere an image can.
enum BrandAssetKind: String, Codable, CaseIterable, Identifiable {
    case logo
    case icon
    case image

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .logo: return "Logo"
        case .icon: return "Icon"
        case .image: return "Image"
        }
    }

    var pluralName: String {
        switch self {
        case .logo: return "Logos"
        case .icon: return "Icons"
        case .image: return "Images"
        }
    }

    /// A guess from a file name: "acme-logo-white.png" is a logo,
    /// "app-icon.png" an icon, anything else an image.
    static func suggested(forFileStem stem: String) -> BrandAssetKind {
        let lowered = stem.lowercased()
        if lowered.contains("logo") || lowered.contains("wordmark") || lowered.contains("brandmark") {
            return .logo
        }
        if lowered.contains("icon") || lowered.contains("glyph") || lowered.contains("symbol") {
            return .icon
        }
        return .image
    }
}

/// One entry in the organization's asset library (Studio › Assets, admin
/// mode): a display name and kind for an image that lives in the Studio
/// asset store. Scenes reference the image by `assetName`, exactly like an
/// image chosen with "Choose Image…", so a brand asset renders in the
/// saver, in wallpapers, and inside deployed bundles with no extra plumbing.
struct BrandAsset: Codable, Identifiable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = BrandAsset.currentSchemaVersion
    var id: String = UUID().uuidString
    var name: String
    var kind: BrandAssetKind = .logo
    /// Content-addressed file name in the Studio asset store
    /// (`ScreenSaverSceneStore.assetURL(named:)`).
    var assetName: String
    var createdAt = Date()
    var modifiedAt = Date()
}

extension BrandAsset {
    /// IDs of entries that come from the organization's folder
    /// (`brandAssetsFolderPath`) rather than the user's library.
    static let managedIDPrefix = "managed:"

    /// Read-only, admin-provided entry (never written to disk).
    var isManaged: Bool { id.hasPrefix(BrandAsset.managedIDPrefix) }
}

extension BrandAsset {
    // Fields added later decode leniently so older files still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = container.sceneValue(.schemaVersion, default: BrandAsset.currentSchemaVersion)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = container.sceneValue(.kind, default: .image)
        assetName = try container.decode(String.self, forKey: .assetName)
        createdAt = container.sceneValue(.createdAt, default: Date())
        modifiedAt = container.sceneValue(.modifiedAt, default: createdAt)
    }
}

/// Per-user brand asset library:
/// `~/Library/Application Support/PaperWalls/Studio/BrandAssets/`.
///
/// Same layout and rules as `ScreenSaverSceneStore`: one `<uuid>.json`
/// per asset, atomic writes, lenient decoding, and a corrupt file costs
/// exactly one entry. The image bytes themselves are NOT here — they are
/// in the Studio asset store next to the screen savers, so the files a
/// scene refers to never move when the library entry is renamed or
/// removed.
enum BrandAssetStore {
    static let log = Logger(subsystem: ManagedPreferences.domain, category: "brandassets")

    static let fileExtension = "json"

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PaperWalls/Studio/BrandAssets", isDirectory: true)
    }

    // MARK: - Read

    /// Every readable asset, newest first.
    static func loadAll(in directory: URL = defaultDirectory) -> [BrandAsset] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                      includingPropertiesForKeys: nil,
                                                                      options: [.skipsHiddenFiles]) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == fileExtension }
            .compactMap { url -> BrandAsset? in
                guard let data = try? Data(contentsOf: url),
                      let asset = try? ScreenSaverSceneStore.decoder.decode(BrandAsset.self, from: data) else {
                    log.error("Skipping unreadable brand asset file \(url.lastPathComponent, privacy: .public)")
                    return nil
                }
                guard asset.schemaVersion <= BrandAsset.currentSchemaVersion else {
                    log.error("Brand asset \(url.lastPathComponent, privacy: .public) uses a newer schema")
                    return nil
                }
                // The filename is the identity; a copied file must not
                // shadow another entry.
                guard asset.id == url.deletingPathExtension().lastPathComponent,
                      UUID(uuidString: asset.id) != nil else {
                    log.error("Skipping brand asset whose name doesn't match its ID: \(url.lastPathComponent, privacy: .public)")
                    return nil
                }
                // An entry whose name isn't a plain file name can't resolve
                // to anything in the asset store.
                guard ScreenSaverSceneStore.assetURL(named: asset.assetName) != nil else {
                    log.error("Skipping brand asset with an invalid image name: \(url.lastPathComponent, privacy: .public)")
                    return nil
                }
                return asset
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    // MARK: - Write

    static func fileURL(forID id: String, in directory: URL = defaultDirectory) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension(fileExtension)
    }

    /// Atomic write (temp file + rename).
    static func save(_ asset: BrandAsset, in directory: URL = defaultDirectory) throws {
        guard UUID(uuidString: asset.id) != nil,
              ScreenSaverSceneStore.assetURL(named: asset.assetName) != nil else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var asset = asset
        asset.schemaVersion = BrandAsset.currentSchemaVersion
        try ScreenSaverSceneStore.encoder.encode(asset).write(to: fileURL(forID: asset.id, in: directory), options: .atomic)
    }

    /// Removes the library entry only. The image file stays in the asset
    /// store because scenes may still use it — see `AppModel.deleteBrandAsset`.
    static func delete(id: String, in directory: URL = defaultDirectory) throws {
        guard UUID(uuidString: id) != nil else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.removeItem(at: fileURL(forID: id, in: directory))
    }

    // MARK: - Naming

    /// "acme-logo_white.png" → "Acme Logo White". The name stays editable;
    /// this is just a better starting point than the file name.
    static func suggestedName(forFileStem stem: String) -> String {
        let words = stem
            .replacingOccurrences(of: "[-_.]+", with: " ", options: .regularExpression)
            .split(separator: " ")
            .map { word -> String in
                let text = String(word)
                // Keep all-caps words (ACME) and mixed-case words (iPhone) as
                // they are; capitalize plain lower-case ones.
                guard text == text.lowercased() else { return text }
                return text.prefix(1).uppercased() + text.dropFirst()
            }
        let name = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Untitled" : name
    }

    /// "Logo" → "Logo 2" when the name is taken (case-insensitive).
    static func uniqueName(_ name: String, existing: [String]) -> String {
        ScreenSaverSceneStore.uniqueName(name, existing: existing)
    }
}

// MARK: - Managed folder (brandAssetsFolderPath)

/// The organization's assets, read from a folder an admin deploys to the
/// Mac. Entries are regular `BrandAsset`s with managed IDs; the image bytes
/// stay in the folder until a scene uses one, at which point the app copies
/// them into the Studio asset store (see `AppModel.useBrandAsset`).
struct ManagedBrandAssetFolder: Equatable {
    var assets: [BrandAsset] = []
    /// Where each managed asset's image lives, by `assetName`.
    var sources: [String: URL] = [:]

    var isEmpty: Bool { assets.isEmpty }
}

extension BrandAssetStore {
    /// Lists the folder's image files (one level, hidden files skipped),
    /// sorted by file name. Names and kinds come from the file names —
    /// `acme-logo-white.png` → "Acme Logo White", Logo. Byte-identical files
    /// are listed once. A missing or unreadable folder is simply empty.
    static func scanManagedFolder(_ path: String) -> ManagedBrandAssetFolder {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ManagedBrandAssetFolder() }
        let folder = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder,
                                                                      includingPropertiesForKeys: Array(keys),
                                                                      options: [.skipsHiddenFiles]) else {
            return ManagedBrandAssetFolder()
        }
        var result = ManagedBrandAssetFolder()
        var names: [String] = []
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for url in sorted {
            let ext = url.pathExtension.lowercased()
            guard ScreenSaverSceneStore.assetExtensions.contains(ext),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let assetName = ScreenSaverSceneStore.assetName(forData: data, fileExtension: ext),
                  result.sources[assetName] == nil else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            let name = uniqueName(suggestedName(forFileStem: stem), existing: names)
            let modified = values.contentModificationDate ?? Date()
            result.assets.append(BrandAsset(id: BrandAsset.managedIDPrefix + assetName,
                                            name: name,
                                            kind: .suggested(forFileStem: stem),
                                            assetName: assetName,
                                            createdAt: modified,
                                            modifiedAt: modified))
            result.sources[assetName] = url
            names.append(name)
        }
        return result
    }

    /// The user's own entries first, then the organization's — minus any
    /// managed image the user already has in the library (same bytes), so
    /// a logo never shows twice.
    static func merged(library: [BrandAsset], managed: [BrandAsset]) -> [BrandAsset] {
        let taken = Set(library.map(\.assetName))
        return library + managed.filter { !taken.contains($0.assetName) }
    }
}

extension ScreenSaverScene {
    /// Every Studio asset-store image this scene draws: the background
    /// image, if any, each icon layer that uses an image, and each
    /// subject cutout.
    var referencedAssetNames: Set<String> {
        var names: Set<String> = []
        if case .image(let name) = background.source, !name.isEmpty {
            names.insert(name)
        }
        for layer in layers {
            if let name = layer.content.imageAssetName {
                names.insert(name)
            }
        }
        return names
    }
}
