import Foundation
import os

/// What the screen saver should show right now, fully resolved (spec §10).
///
/// The .saver runs inside the system's sandboxed legacyScreenSaver host,
/// where this domain's user preferences are invisible but files under the
/// user's real home folder are readable. So the app and `paperwallscli
/// manage` — which CAN see every preference layer — resolve the policy
/// (master switch, lock tier, allow-list, active scene) and write the
/// outcome here; the saver only ever reads this one file.
struct ScreenSaverSnapshot: Codable, Equatable {
    static let log = Logger(subsystem: ManagedPreferences.domain, category: "screensaver")
    static let currentVersion = 1

    enum State: String, Codable {
        /// `scene` is what to show.
        case active
        /// No scene has been chosen yet — the saver shows its default.
        case noneSelected
        /// `screenSaverEnabled` is off — solid color.
        case disabled
        /// `lockMode` is hard — solid color.
        case hardLock
    }

    var version = Self.currentVersion
    var generatedAt = Date()
    var state: State
    var sceneID: String?
    var sceneName: String?
    var scene: ScreenSaverScene?
    /// Library wallpaper ID → file path, for a `.wallpaper` background.
    var wallpaperPaths: [String: String] = [:]
    /// The resolved rotation pool (spec §4), for a `.rotatingPool` background.
    var rotationPaths: [String] = []
    /// Folder holding imported icon images.
    var assetsDirectory: String = ""
    var companyName: String = ""
    /// Shown when there is no scene (disabled / hard lock).
    var fallbackColorHex: String = "000000"

    /// Same outcome, ignoring when it was generated — lets writers skip
    /// rewriting an unchanged file.
    func hasSameContent(as other: ScreenSaverSnapshot) -> Bool {
        var copy = other
        copy.generatedAt = generatedAt
        return self == copy
    }

    // MARK: - Location

    /// The user's actual home folder. Inside the saver's sandbox
    /// `NSHomeDirectory()` is the container, so ask the directory service.
    static var realHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var defaultURL: URL {
        realHomeDirectory
            .appendingPathComponent("Library/Application Support/PaperWalls/Studio/ActiveScreenSaver.json")
    }

    // MARK: - Read / write

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

    /// nil when the file is missing, unreadable, or from a newer version.
    static func read(from url: URL = defaultURL) -> ScreenSaverSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let snapshot = try? decoder.decode(ScreenSaverSnapshot.self, from: data),
              snapshot.version <= currentVersion else {
            log.error("Ignoring unreadable screen saver snapshot")
            return nil
        }
        return snapshot
    }

    /// Atomic write. Returns false (and leaves the file alone) when the
    /// existing snapshot already says the same thing.
    @discardableResult
    func write(to url: URL = defaultURL) throws -> Bool {
        if let existing = Self.read(from: url), hasSameContent(as: existing) {
            return false
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: url, options: .atomic)
        return true
    }

    // MARK: - For the renderer

    /// File for an imported icon image, confined to the assets folder.
    func assetURL(named name: String) -> URL? {
        guard !assetsDirectory.isEmpty, !name.isEmpty,
              name == (name as NSString).lastPathComponent, !name.hasPrefix(".") else {
            return nil
        }
        return URL(fileURLWithPath: assetsDirectory, isDirectory: true).appendingPathComponent(name)
    }
}
