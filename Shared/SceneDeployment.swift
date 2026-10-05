import Foundation

/// The pure contract behind Studio › Package (admin mode): library scenes
/// become self-contained savers for `/Library/Screen Savers` on other
/// Macs, wrapped in one installer package. The app does the file work
/// (`ScenePackager`); naming, paths, and generated documents live here so
/// tests can pin them.
enum SceneDeployment {
    /// Folder inside a bundle's Resources that holds the scene's images.
    static let mediaFolder = "Media"
    static let installDirectory = "/Library/Screen Savers"

    /// One file a deployed bundle must carry. `destination` is relative to
    /// the bundle's Resources folder.
    struct MediaFile: Equatable {
        var source: String
        var destination: String
    }

    /// Rewrites a scene snapshot so every image it shows ships inside the
    /// bundle (paths relative to Resources — see
    /// `ScreenSaverSnapshot.resolvingBundlePaths(in:)`), and lists the
    /// files to copy. "Current desktop" backgrounds stay live: they follow
    /// whatever wallpaper the target Mac has.
    static func portable(_ snapshot: ScreenSaverSnapshot) -> (snapshot: ScreenSaverSnapshot, media: [MediaFile]) {
        var portable = snapshot
        var media: [MediaFile] = []

        func destination(_ stem: String, for source: String) -> String {
            let ext = (source as NSString).pathExtension.lowercased()
            return "\(mediaFolder)/\(stem)" + (ext.isEmpty ? "" : ".\(ext)")
        }

        portable.wallpaperPaths = [:]
        for (index, id) in snapshot.wallpaperPaths.keys.sorted().enumerated() {
            guard let source = snapshot.wallpaperPaths[id] else { continue }
            let target = destination("wallpaper-\(index + 1)", for: source)
            media.append(MediaFile(source: source, destination: target))
            portable.wallpaperPaths[id] = target
        }

        portable.rotationPaths = snapshot.rotationPaths.enumerated().map { index, source in
            let target = destination("rotation-\(index + 1)", for: source)
            media.append(MediaFile(source: source, destination: target))
            return target
        }

        // Only the imported icons this scene uses — not the whole store.
        let assetsFolder = "\(mediaFolder)/Assets"
        var assetNames: [String] = []
        for layer in snapshot.scene?.layers ?? [] {
            if case .icon(let icon) = layer.content, let name = icon.imageAssetName,
               snapshot.assetURL(named: name) != nil, !assetNames.contains(name) {
                assetNames.append(name)
            }
        }
        for name in assetNames.sorted() {
            guard let source = snapshot.assetURL(named: name) else { continue }
            media.append(MediaFile(source: source.path, destination: "\(assetsFolder)/\(name)"))
        }
        portable.assetsDirectory = assetNames.isEmpty ? "" : assetsFolder

        return (portable, media)
    }

    /// Names from `security find-identity -v` lines:  1) <SHA1> "Name"
    static func identityNames(fromFindIdentityOutput output: String) -> [String] {
        var names: [String] = []
        for line in output.split(separator: "\n") {
            guard let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""), open < close else { continue }
            let name = String(line[line.index(after: open)..<close])
            if !names.contains(name) { names.append(name) }
        }
        return names
    }
}

/// One installer package holding one or more deployed scene bundles.
struct DeploymentPackageSpec: Equatable {
    static let identifierPrefix = "com.herojoneslabs.paperwalls.savers."

    var name: String
    var version: String

    /// "com.herojoneslabs.paperwalls.savers.acme-lobby-savers"
    var identifier: String {
        Self.identifierPrefix + Self.slug(name)
    }

    /// "Acme Lobby Savers-1.2.pkg"
    var pkgFilename: String {
        "\(SceneBundleSpec.sanitizedTitle(name))-\(version).pkg"
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && Self.isValidVersion(version)
    }

    /// Lowercase ASCII letters and digits joined by single hyphens.
    static func slug(_ name: String) -> String {
        var words: [String] = []
        var current = ""
        for scalar in name.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.isEmpty ? "package" : words.joined(separator: "-")
    }

    /// 1 to 4 dot-separated numbers ("1", "1.2", "2026.10.4").
    static func isValidVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        return (1...4).contains(parts.count)
            && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }
}

/// Making one deployed saver the screen saver on target Macs. Two parts,
/// deployed together (verified on macOS 27):
///
///   * **Select** — PaperWalls' `enforcedScreenSaverPath`; the manage agent
///     writes it into the wallpaper store (see `ScreenSaverSelection`).
///   * **Lock** — a `com.apple.screensaver` profile forcing `moduleName`.
///     System Settings then can't change the choice, but on macOS 14+ this
///     key alone doesn't select a third-party saver; it only locks one that
///     is already selected.
enum DeploymentEnforcement {
    /// "/Library/Screen Savers/Acme – Lobby.saver"
    static func saverPath(for bundle: SceneBundleSpec) -> String {
        "\(SceneDeployment.installDirectory)/\(bundle.bundleName)"
    }

    /// A managed-preferences profile forcing `enforcedScreenSaverPath`,
    /// shaped like Deployment/com.herojoneslabs.paperwalls.mobileconfig.
    static func profile(bundle: SceneBundleSpec, packageIdentifier: String, organization: String,
                        uuid: () -> UUID = UUID.init) -> [String: Any] {
        let settings: [String: Any] = [
            ManagedPreferenceKey.enforcedScreenSaverPath.rawValue: saverPath(for: bundle),
        ]
        let payload: [String: Any] = [
            "PayloadType": "com.apple.ManagedClient.preferences",
            "PayloadVersion": 1,
            "PayloadIdentifier": "\(packageIdentifier).enforce.mcx",
            "PayloadUUID": uuid().uuidString,
            "PayloadDisplayName": "Enforced Screen Saver",
            "PayloadContent": [
                ManagedPreferences.domain: ["Forced": [["mcx_preference_settings": settings]]],
            ],
        ]
        return [
            "PayloadContent": [payload],
            "PayloadDescription": "Keeps “\(bundle.displayName)” selected as the screen saver. Requires PaperWalls with its manage LaunchAgent on the Mac.",
            "PayloadDisplayName": "\(bundle.displayName) Screen Saver",
            "PayloadIdentifier": "\(packageIdentifier).enforce",
            "PayloadOrganization": organization.isEmpty ? "YourOrg" : organization,
            "PayloadRemovalDisallowed": false,
            "PayloadScope": "System",
            "PayloadType": "Configuration",
            "PayloadUUID": uuid().uuidString,
            "PayloadVersion": 1,
        ]
    }

    /// "Acme – Lobby": what `moduleName` must hold (the saver's bundle name).
    static func moduleName(for bundle: SceneBundleSpec) -> String {
        bundle.displayName
    }

    /// The lock: a computer-level `com.apple.screensaver` profile forcing
    /// `moduleName`. Only that key — idle time and password settings are
    /// left to the admin's own screen saver profile.
    static func lockProfile(bundle: SceneBundleSpec, packageIdentifier: String, organization: String,
                            uuid: () -> UUID = UUID.init) -> [String: Any] {
        let payload: [String: Any] = [
            "PayloadType": "com.apple.screensaver",
            "PayloadVersion": 1,
            "PayloadIdentifier": "\(packageIdentifier).lock.screensaver",
            "PayloadUUID": uuid().uuidString,
            "PayloadDisplayName": "Screen Saver Lock",
            "moduleName": moduleName(for: bundle),
        ]
        return [
            "PayloadContent": [payload],
            "PayloadDescription": "Locks the screen saver to “\(bundle.displayName)”. Deploy with the PaperWalls enforcement profile, which selects it.",
            "PayloadDisplayName": "\(bundle.displayName) Screen Saver Lock",
            "PayloadIdentifier": "\(packageIdentifier).lock",
            "PayloadOrganization": organization.isEmpty ? "YourOrg" : organization,
            "PayloadRemovalDisallowed": false,
            "PayloadScope": "System",
            "PayloadType": "Configuration",
            "PayloadUUID": uuid().uuidString,
            "PayloadVersion": 1,
        ]
    }

    /// The same setting for /Library/Application Support/PaperWalls/managed.json.
    static func managedJSON(bundle: SceneBundleSpec) -> String {
        let object: [String: Any] = ["forced": [ManagedPreferenceKey.enforcedScreenSaverPath.rawValue: saverPath(for: bundle)]]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
