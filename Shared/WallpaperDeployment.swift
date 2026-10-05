import Foundation

/// The pure contract behind Studio › Package › Wallpapers (admin mode):
/// library wallpapers become plain image files in one folder on other
/// Macs, wrapped in an installer package, plus a PaperWalls profile that
/// points the Managed source (`externalWallpaperFolderPath`) at that
/// folder. The app does the file work (`WallpaperPackager`); naming,
/// paths, and generated documents live here so tests can pin them.
///
/// Wallpaper identity is content-derived (`file:<hash>`, spec §6), and the
/// package copies the bytes unchanged, so an ID computed at build time is
/// the ID every target Mac sees. That is what lets the profile pin a
/// default wallpaper and an allow-list before the files ever land.
enum WallpaperDeployment {
    static let identifierPrefix = "com.herojoneslabs.paperwalls.wallpapers."
    /// Fleet-wide, readable by every user, and already PaperWalls' own
    /// system folder (managed.json lives beside it).
    static let defaultInstallDirectory = "/Library/Application Support/PaperWalls/Wallpapers"

    /// One image the package installs. `filename` is relative to the
    /// install folder — the Managed source scans it flat, so there are no
    /// subfolders.
    struct File: Equatable {
        var source: String
        var filename: String
    }

    /// "Aurora Veil" + "/…/01-aurora-veil.HEIC" → "Aurora Veil.heic". The
    /// title rules are the saver bundle's (no slashes or colons, trimmed,
    /// capped); the extension follows the source file, lowercased.
    static func filename(name: String, sourcePath: String) -> String {
        let title = SceneBundleSpec.sanitizedTitle(name)
        let ext = (sourcePath as NSString).pathExtension.lowercased()
        return ext.isEmpty ? title : "\(title).\(ext)"
    }

    /// Resolves clashes in order ("photo.jpg", "photo 2.jpg", …) the way
    /// the Personal folder import does, case-insensitively — the target is
    /// an ordinary (case-insensitive) APFS volume.
    static func uniqueFilenames(_ filenames: [String]) -> [String] {
        var taken = Set<String>()
        return filenames.map { filename in
            let unique = PersonalFolder.uniqueFilename(filename, existingLowercased: taken)
            taken.insert(unique.lowercased())
            return unique
        }
    }

    /// Trims whitespace and a trailing slash; "~" is not expanded because
    /// the folder must mean the same thing on every Mac.
    static func normalizedInstallDirectory(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    /// Absolute, not the root, no `.`/`..` hops, and outside the places the
    /// OS seals or a user owns: the pkg installs for every user of the Mac.
    static func isValidInstallDirectory(_ path: String) -> Bool {
        let normalized = normalizedInstallDirectory(path)
        guard normalized.hasPrefix("/"), normalized != "/" else { return false }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        let sealed = ["/System", "/private", "/bin", "/sbin", "/usr", "/etc", "/var", "/tmp", "/dev", "/Volumes"]
        if sealed.contains(where: { normalized == $0 || normalized.hasPrefix($0 + "/") }) { return false }
        // A home folder belongs to one user; a folder inside /Users/Shared
        // is for everyone (/Users/Shared itself is too busy to scan flat).
        if normalized.hasPrefix("/Users/"), !normalized.hasPrefix("/Users/Shared/") {
            return false
        }
        return true
    }

    /// "/Library/Application Support/PaperWalls/Wallpapers/Aurora Veil.heic"
    static func installedPath(for file: File, installDirectory: String) -> String {
        normalizedInstallDirectory(installDirectory) + "/" + file.filename
    }
}

/// What the generated PaperWalls profile forces on target Macs. Only the
/// folder is required; the rest are the admin's choices in Studio › Package.
struct WallpaperDeploymentSettings: Equatable {
    var installDirectory: String
    /// Content ID of the wallpaper to apply (`selectedWallpaperID`); the
    /// manage agent and the app honor it.
    var defaultWallpaperID: String?
    /// nil leaves each Mac's lock tier alone.
    var lockMode: LockMode?
    /// Content IDs the library is restricted to (`allowedWallpaperIDs`);
    /// nil leaves every source visible.
    var allowedWallpaperIDs: [String]?

    /// The `mcx_preference_settings` dictionary, keys sorted for stable
    /// output. `lockMode` also writes the legacy `lockSelection` so a
    /// pre-lockMode PaperWalls on the fleet locks too.
    var preferenceSettings: [String: Any] {
        var settings: [String: Any] = [
            ManagedPreferenceKey.externalWallpaperFolderPath.rawValue:
                WallpaperDeployment.normalizedInstallDirectory(installDirectory),
        ]
        if let defaultWallpaperID, !defaultWallpaperID.isEmpty {
            settings[ManagedPreferenceKey.selectedWallpaperID.rawValue] = defaultWallpaperID
        }
        if let lockMode {
            settings[ManagedPreferenceKey.lockMode.rawValue] = lockMode.rawValue
            settings[ManagedPreferenceKey.lockSelection.rawValue] = lockMode != .off
        }
        if let allowedWallpaperIDs, !allowedWallpaperIDs.isEmpty {
            settings[ManagedPreferenceKey.allowedWallpaperIDs.rawValue] = allowedWallpaperIDs
        }
        return settings
    }
}

/// The profile and local config that make a deployed wallpaper folder
/// show up in PaperWalls, shaped like Deployment/com.herojoneslabs.paperwalls.mobileconfig.
enum WallpaperDeploymentProfile {
    static func profile(settings: WallpaperDeploymentSettings, packageName: String, packageIdentifier: String,
                        organization: String, uuid: () -> UUID = UUID.init) -> [String: Any] {
        let payload: [String: Any] = [
            "PayloadType": "com.apple.ManagedClient.preferences",
            "PayloadVersion": 1,
            "PayloadIdentifier": "\(packageIdentifier).configure.mcx",
            "PayloadUUID": uuid().uuidString,
            "PayloadDisplayName": "Deployed Wallpapers",
            "PayloadContent": [
                ManagedPreferences.domain: ["Forced": [["mcx_preference_settings": settings.preferenceSettings]]],
            ],
        ]
        return [
            "PayloadContent": [payload],
            "PayloadDescription": description(for: settings, packageName: packageName),
            "PayloadDisplayName": "\(packageName) Wallpapers",
            "PayloadIdentifier": "\(packageIdentifier).configure",
            "PayloadOrganization": organization.isEmpty ? "YourOrg" : organization,
            "PayloadRemovalDisallowed": false,
            "PayloadScope": "System",
            "PayloadType": "Configuration",
            "PayloadUUID": uuid().uuidString,
            "PayloadVersion": 1,
        ]
    }

    /// The same settings for /Library/Application Support/PaperWalls/managed.json.
    static func managedJSON(settings: WallpaperDeploymentSettings) -> String {
        let object: [String: Any] = ["forced": settings.preferenceSettings]
        let data = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func description(for settings: WallpaperDeploymentSettings, packageName: String) -> String {
        var sentences = ["Shows the wallpapers installed by “\(packageName)” in PaperWalls."]
        if settings.defaultWallpaperID != nil {
            sentences.append("Applies the chosen default wallpaper.")
        }
        if let lockMode = settings.lockMode, lockMode != .off {
            sentences.append("Lock tier: \(lockMode.displayName).")
        }
        if settings.allowedWallpaperIDs?.isEmpty == false {
            sentences.append("Restricts the library to the packaged wallpapers.")
        }
        return sentences.joined(separator: " ")
    }
}
