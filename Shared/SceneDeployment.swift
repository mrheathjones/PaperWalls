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

/// Reference configuration profile that selects one deployed saver. Same
/// payload — and the same per-release caveat — as
/// Deployment/com.herojoneslabs.paperwalls.screensaver.mobileconfig.
enum DeploymentProfile {
    static func make(bundle: SceneBundleSpec, packageIdentifier: String, organization: String,
                     idleTime: Int = 600, uuid: () -> UUID = UUID.init) -> [String: Any] {
        let modulePath = "\(SceneDeployment.installDirectory)/\(bundle.bundleName)"
        let payload: [String: Any] = [
            "PayloadType": "com.apple.screensaver.user",
            "PayloadVersion": 1,
            "PayloadIdentifier": "\(packageIdentifier).screensaver.user",
            "PayloadUUID": uuid().uuidString,
            "PayloadDisplayName": "Screen Saver Selection",
            "idleTime": idleTime,
            "moduleName": bundle.displayName,
            "modulePath": modulePath,
        ]
        return [
            "PayloadContent": [payload],
            "PayloadDescription": "Selects the “\(bundle.displayName)” screen saver. Verify on each macOS release you deploy to.",
            "PayloadDisplayName": "\(bundle.displayName) Screen Saver",
            "PayloadIdentifier": "\(packageIdentifier).screensaver",
            "PayloadOrganization": organization.isEmpty ? "YourOrg" : organization,
            "PayloadRemovalDisallowed": false,
            "PayloadScope": "User",
            "PayloadType": "Configuration",
            "PayloadUUID": uuid().uuidString,
            "PayloadVersion": 1,
        ]
    }
}
