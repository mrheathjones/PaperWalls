import Foundation
import os

/// One wallpaper design in Studio › Wallpapers: a scene plus the pixel
/// size it renders at and the file its last render became. The design
/// stays editable here; the rendered PNG lives in the Personal library
/// like any other wallpaper.
struct StoredWallpaperDesign: Codable, Identifiable, Equatable {
    var schemaVersion: Int = ScreenSaverScene.currentSchemaVersion
    var id: String = UUID().uuidString
    var name: String
    var createdAt = Date()
    var modifiedAt = Date()
    var scene: ScreenSaverScene
    var pixelWidth: Int = 2560
    var pixelHeight: Int = 1600
    /// Name of the last rendered file inside the Personal folder, so a
    /// re-save replaces it instead of adding another copy.
    var exportedFilename: String?

    var pixelSize: CGSize {
        get { CGSize(width: pixelWidth, height: pixelHeight) }
        set {
            pixelWidth = Int(newValue.width.rounded())
            pixelHeight = Int(newValue.height.rounded())
        }
    }
}

extension StoredWallpaperDesign {
    // Fields added later decode leniently so older files still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        scene = try container.decode(ScreenSaverScene.self, forKey: .scene)
        pixelWidth = max(1, container.sceneValue(.pixelWidth, default: 2560))
        pixelHeight = max(1, container.sceneValue(.pixelHeight, default: 1600))
        exportedFilename = try? container.decodeIfPresent(String.self, forKey: .exportedFilename)
    }
}

/// Per-user wallpaper designs:
/// `~/Library/Application Support/PaperWalls/Studio/Wallpapers/`.
///
/// Same layout and rules as `ScreenSaverSceneStore`: one `<uuid>.json`
/// per design plus `Thumbnails/<id>.png`, atomic writes, lenient decoding,
/// and a corrupt file costs exactly one entry.
enum WallpaperDesignStore {
    static let log = Logger(subsystem: ManagedPreferences.domain, category: "wallpaperdesigns")

    static let fileExtension = "json"
    static let thumbnailsFolderName = "Thumbnails"

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PaperWalls/Studio/Wallpapers", isDirectory: true)
    }

    // MARK: - Read

    /// Every readable design, newest first.
    static func loadAll(in directory: URL = defaultDirectory) -> [StoredWallpaperDesign] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                      includingPropertiesForKeys: nil,
                                                                      options: [.skipsHiddenFiles]) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == fileExtension }
            .compactMap { url -> StoredWallpaperDesign? in
                guard let data = try? Data(contentsOf: url) else {
                    log.error("Skipping unreadable design file \(url.lastPathComponent, privacy: .public)")
                    return nil
                }
                guard let design = decode(data) else {
                    log.error("Skipping corrupt design file \(url.lastPathComponent, privacy: .public)")
                    return nil
                }
                guard design.id == url.deletingPathExtension().lastPathComponent,
                      UUID(uuidString: design.id) != nil else {
                    log.error("Skipping design file whose name doesn't match its ID: \(url.lastPathComponent, privacy: .public)")
                    return nil
                }
                return design
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Decodes one design, running the scene store's migration hook first
    /// (the scene inside follows the same schema).
    static func decode(_ data: Data) -> StoredWallpaperDesign? {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let version = object["schemaVersion"] as? Int ?? 1
        guard version <= ScreenSaverScene.currentSchemaVersion else {
            log.error("Design uses schema \(version), newer than this version understands")
            return nil
        }
        if version < ScreenSaverScene.currentSchemaVersion {
            object = ScreenSaverSceneStore.migrate(object, from: version)
        }
        guard let migrated = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? ScreenSaverSceneStore.decoder.decode(StoredWallpaperDesign.self, from: migrated)
    }

    // MARK: - Write

    static func fileURL(forID id: String, in directory: URL = defaultDirectory) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension(fileExtension)
    }

    static func thumbnailURL(forID id: String, in directory: URL = defaultDirectory) -> URL {
        directory.appendingPathComponent(thumbnailsFolderName, isDirectory: true)
            .appendingPathComponent(id).appendingPathExtension("png")
    }

    static func save(_ design: StoredWallpaperDesign, in directory: URL = defaultDirectory) throws {
        guard UUID(uuidString: design.id) != nil else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var design = design
        design.schemaVersion = ScreenSaverScene.currentSchemaVersion
        try ScreenSaverSceneStore.encoder.encode(design)
            .write(to: fileURL(forID: design.id, in: directory), options: .atomic)
    }

    static func delete(id: String, in directory: URL = defaultDirectory) throws {
        guard UUID(uuidString: id) != nil else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.removeItem(at: fileURL(forID: id, in: directory))
        try? FileManager.default.removeItem(at: thumbnailURL(forID: id, in: directory))
    }

    // MARK: - Naming

    static func uniqueName(_ name: String, existing: [String]) -> String {
        ScreenSaverSceneStore.uniqueName(name, existing: existing)
    }

    /// The PNG name a design renders to: its name made safe for a file
    /// system ("Team / Q4: Launch" → "Team - Q4- Launch.png").
    static func exportFilename(for name: String) -> String {
        var stem = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while stem.hasPrefix(".") {
            stem.removeFirst()
        }
        stem = stem.trimmingCharacters(in: .whitespaces)
        if stem.count > 80 {
            stem = String(stem.prefix(80)).trimmingCharacters(in: .whitespaces)
        }
        return (stem.isEmpty ? "Wallpaper" : stem) + ".png"
    }
}

/// The pixel sizes a wallpaper can be rendered at.
enum WallpaperRenderSize {
    struct Option: Identifiable, Equatable {
        var id: String { label }
        var label: String
        var pixelSize: CGSize
        /// True for a connected display (listed first).
        var isDisplay: Bool
    }

    static let presets: [CGSize] = [
        CGSize(width: 5120, height: 2880),
        CGSize(width: 3840, height: 2160),
        CGSize(width: 2560, height: 1600),
        CGSize(width: 2560, height: 1440),
        CGSize(width: 1920, height: 1080),
    ]

    static func label(for size: CGSize) -> String {
        "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
    }

    /// Connected displays first (main display first), then the presets a
    /// display doesn't already cover.
    static func options(displayPixelSizes: [CGSize]) -> [Option] {
        var options: [Option] = []
        var seen: [CGSize] = []
        for (index, size) in displayPixelSizes.enumerated() where size.width >= 1 && size.height >= 1 && !seen.contains(size) {
            seen.append(size)
            let name = index == 0 ? "Main display" : "Display \(index + 1)"
            options.append(Option(label: "\(name) (\(label(for: size)))", pixelSize: size, isDisplay: true))
        }
        for size in presets where !seen.contains(size) {
            seen.append(size)
            options.append(Option(label: label(for: size), pixelSize: size, isDisplay: false))
        }
        return options
    }

    /// What a new design renders at: the main display, else 2560 × 1600.
    static func defaultPixelSize(displayPixelSizes: [CGSize]) -> CGSize {
        options(displayPixelSizes: displayPixelSizes).first { $0.isDisplay }?.pixelSize
            ?? CGSize(width: 2560, height: 1600)
    }
}

enum WallpaperDesignError: LocalizedError {
    case noPersonalFolder
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .noPersonalFolder:
            return "There is no Personal wallpaper folder to save into. Check the Personal folder in Settings."
        case .renderFailed:
            return "The wallpaper image couldn’t be rendered."
        }
    }
}
