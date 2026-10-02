import CryptoKit
import Foundation
import os

/// One screen saver in the library (spec §10): a scene plus its identity.
/// User-created entries are stored one JSON file each; the admin-provisioned
/// entry (`managedScreenSaverScene`) uses the reserved ID `managed` and is
/// never written to disk.
struct StoredScreenSaver: Codable, Identifiable, Equatable {
    var schemaVersion: Int = ScreenSaverScene.currentSchemaVersion
    /// A UUID string for user scenes; `ScreenSaverSceneStore.managedSceneID`
    /// for the managed entry. This is what `activeScreenSaverSceneID` holds.
    var id: String = UUID().uuidString
    var name: String
    var createdAt = Date()
    var modifiedAt = Date()
    var scene: ScreenSaverScene

    /// Read-only, admin-provisioned entry.
    var isManaged: Bool { id == ScreenSaverSceneStore.managedSceneID }
}

/// Per-user screen saver library (spec §10):
/// `~/Library/Application Support/PaperWalls/Studio/ScreenSavers/`.
///
/// Layout: one `<uuid>.json` per scene plus `Thumbnails/<id>.png` — no
/// index file. Each write is atomic and touches one file, a corrupt file
/// costs exactly one entry (skipped + logged), and there is no index to
/// drift out of sync with the folder.
enum ScreenSaverSceneStore {
    static let log = Logger(subsystem: ManagedPreferences.domain, category: "scenestore")

    static let managedSceneID = "managed"
    static let fileExtension = "json"
    static let thumbnailsFolderName = "Thumbnails"
    static let assetsFolderName = "Assets"
    static let assetExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif"]

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PaperWalls/Studio/ScreenSavers", isDirectory: true)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Read

    /// Every readable user scene, newest first. A file that is corrupt,
    /// from a newer schema, or misnamed is skipped and logged — it never
    /// takes the rest of the library down with it.
    static func loadAll(in directory: URL = defaultDirectory) -> [StoredScreenSaver] {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(at: directory,
                                                              includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else {
            return []   // nothing saved yet
        }
        return urls
            .filter { $0.pathExtension == fileExtension }
            .compactMap { url -> StoredScreenSaver? in
                guard let data = try? Data(contentsOf: url) else {
                    log.error("Skipping unreadable scene file \(url.lastPathComponent, privacy: .public)")
                    return nil
                }
                guard let stored = decode(data) else {
                    log.error("Skipping corrupt scene file \(url.lastPathComponent, privacy: .public)")
                    return nil
                }
                // The filename is the identity; a copied/renamed file must
                // not shadow another entry.
                guard stored.id == url.deletingPathExtension().lastPathComponent,
                      UUID(uuidString: stored.id) != nil else {
                    log.error("Skipping scene file whose name doesn't match its ID: \(url.lastPathComponent, privacy: .public)")
                    return nil
                }
                return stored
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Decodes one stored entry, running the migration hook first.
    static func decode(_ data: Data) -> StoredScreenSaver? {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let version = object["schemaVersion"] as? Int ?? 1
        guard version <= ScreenSaverScene.currentSchemaVersion else {
            log.error("Scene uses schema \(version), newer than this version understands")
            return nil
        }
        if version < ScreenSaverScene.currentSchemaVersion {
            object = migrate(object, from: version)
        }
        guard let migrated = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? decoder.decode(StoredScreenSaver.self, from: migrated)
    }

    /// Migration hook: upgrades a stored entry's raw JSON one schema
    /// version at a time, BEFORE it is decoded. Schema 1 is the first
    /// version, so there is nothing to do yet — add `case 1:` (1 → 2) here
    /// when `ScreenSaverScene.currentSchemaVersion` is bumped.
    static func migrate(_ object: [String: Any], from version: Int) -> [String: Any] {
        var object = object
        var version = version
        while version < ScreenSaverScene.currentSchemaVersion {
            switch version {
            default:
                break
            }
            version += 1
        }
        object["schemaVersion"] = version
        return object
    }

    // MARK: - Write

    static func fileURL(forID id: String, in directory: URL = defaultDirectory) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension(fileExtension)
    }

    static func thumbnailURL(forID id: String, in directory: URL = defaultDirectory) -> URL {
        directory.appendingPathComponent(thumbnailsFolderName, isDirectory: true)
            .appendingPathComponent(id).appendingPathExtension("png")
    }

    /// Atomic write (temp file + rename) — a crash mid-save leaves the
    /// previous version intact. The managed entry is never persisted.
    static func save(_ stored: StoredScreenSaver, in directory: URL = defaultDirectory) throws {
        guard !stored.isManaged, UUID(uuidString: stored.id) != nil else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var stored = stored
        stored.schemaVersion = ScreenSaverScene.currentSchemaVersion
        try encoder.encode(stored).write(to: fileURL(forID: stored.id, in: directory), options: .atomic)
    }

    static func delete(id: String, in directory: URL = defaultDirectory) throws {
        guard UUID(uuidString: id) != nil else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.removeItem(at: fileURL(forID: id, in: directory))
        try? FileManager.default.removeItem(at: thumbnailURL(forID: id, in: directory))
    }

    // MARK: - Image assets

    static func assetsDirectory(in directory: URL = defaultDirectory) -> URL {
        directory.appendingPathComponent(assetsFolderName, isDirectory: true)
    }

    /// File for an imported icon image (`IconLayer.imageAssetName`), or nil
    /// for a name that isn't a plain filename.
    static func assetURL(named name: String, in directory: URL = defaultDirectory) -> URL? {
        guard !name.isEmpty, name == (name as NSString).lastPathComponent, !name.hasPrefix(".") else {
            return nil
        }
        return directory.appendingPathComponent(assetsFolderName, isDirectory: true)
            .appendingPathComponent(name)
    }

    /// Copies an image into the library and returns its asset name. The
    /// name is derived from the file's contents, so the scene keeps working
    /// when the original is moved or deleted, and importing the same image
    /// twice stores it once.
    static func importAsset(from source: URL, in directory: URL = defaultDirectory) throws -> String {
        let fileExtension = source.pathExtension.lowercased()
        guard assetExtensions.contains(fileExtension) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let data = try Data(contentsOf: source)
        let hash = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
        let name = "\(hash).\(fileExtension)"
        guard let destination = assetURL(named: name, in: directory) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try data.write(to: destination, options: .atomic)
        }
        return name
    }

    // MARK: - Naming

    /// "Bouncing Clock" → "Bouncing Clock 2", "Bouncing Clock 3", … when
    /// the name is taken (case-insensitive).
    static func uniqueName(_ name: String, existing: [String]) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Untitled" : trimmed
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var counter = 2
        while taken.contains("\(base) \(counter)".lowercased()) {
            counter += 1
        }
        return "\(base) \(counter)"
    }

    // MARK: - Managed scene

    /// The admin-provisioned scene, if `managedScreenSaverScene` is set.
    static func managedScene(defaultName: String = "Managed Screen Saver") -> StoredScreenSaver? {
        managedScene(from: ManagedPreferences.value(.managedScreenSaverScene), defaultName: defaultName)
    }

    /// Pure parse. `value` is a JSON string (profiles, Jamf) or an inline
    /// object (managed.json / plist). Either shape may be a bare scene or
    /// `{"name": "…", "scene": {…}}`. Unparseable input yields nil.
    static func managedScene(from value: Any?, defaultName: String) -> StoredScreenSaver? {
        let object: [String: Any]
        if let string = value as? String {
            guard let parsed = (try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? [String: Any] else {
                log.error("Ignoring managedScreenSaverScene: not valid JSON")
                return nil
            }
            object = parsed
        } else if let dictionary = value as? [String: Any] {
            object = dictionary
        } else {
            return nil
        }

        let sceneObject = object["scene"] as? [String: Any] ?? object
        guard JSONSerialization.isValidJSONObject(sceneObject),
              let data = try? JSONSerialization.data(withJSONObject: sceneObject),
              let scene = try? JSONDecoder().decode(ScreenSaverScene.self, from: data) else {
            log.error("Ignoring managedScreenSaverScene: not a scene")
            return nil
        }
        let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let epoch = Date(timeIntervalSince1970: 0)
        return StoredScreenSaver(id: managedSceneID,
                                 name: (name?.isEmpty ?? true) ? defaultName : name!,
                                 createdAt: epoch,
                                 modifiedAt: epoch,
                                 scene: scene)
    }

    /// The JSON an admin pastes into `managedScreenSaverScene` to provision
    /// this scene ("Export for MDM").
    static func managedSceneJSON(for stored: StoredScreenSaver) -> String? {
        struct Export: Encodable {
            let name: String
            let scene: ScreenSaverScene
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Export(name: stored.name, scene: stored.scene)) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
