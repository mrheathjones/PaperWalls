import CryptoKit
import Foundation

/// How a scene becomes its own tile in System Settings (spec §10).
///
/// A *scene bundle* is a copy of PaperWalls.saver in the user's
/// `~/Library/Screen Savers`, renamed for one scene and carrying that
/// scene's snapshot and thumbnail. macOS loads every saver into one host
/// process, so each copy needs a unique principal-class name; the saver's
/// load hook (`SceneBundleIdentity.m`) registers that class and ties it to
/// the copy's path. Everything here is the pure naming/identity contract
/// shared by the generator, the saver, and the uninstaller.
///
/// A *deployed* bundle (Studio › Package) is the same thing built for
/// `/Library/Screen Savers` on other Macs. It gets its own identifier and
/// class prefixes so it can never collide with — or be cleaned up as — a
/// user's own tile for the same scene.
struct SceneBundleSpec: Equatable {
    enum Flavor: Equatable {
        /// Generated per user in ~/Library/Screen Savers.
        case userTile
        /// Built by an admin for deployment.
        case deployed
    }

    static let namePrefix = "PaperWalls – "
    static let bundleExtension = "saver"
    static let identifierPrefix = "com.herojoneslabs.paperwalls.saver.scene."
    static let principalClassPrefix = "PaperWallsScene_"
    static let deployedIdentifierPrefix = "com.herojoneslabs.paperwalls.saver.deployed."
    static let deployedPrincipalClassPrefix = "PaperWallsDeployed_"
    /// Keeps generated filenames sane; Finder's limit is 255 bytes.
    static let maximumTitleLength = 60

    let sceneID: String
    let title: String
    let flavor: Flavor

    init(sceneID: String, name: String, isManaged: Bool) {
        self.sceneID = sceneID
        var title = Self.sanitizedTitle(name)
        if isManaged {
            title += " (Managed)"
        }
        self.title = title
        self.flavor = .userTile
    }

    /// A deployable bundle, named exactly as the admin chose (no prefix).
    init(deployedSceneID sceneID: String, displayName: String) {
        self.sceneID = sceneID
        self.title = Self.sanitizedTitle(displayName)
        self.flavor = .deployed
    }

    /// "PaperWalls – Bouncing Clock.saver"
    var bundleName: String {
        "\(displayName).\(Self.bundleExtension)"
    }

    /// "PaperWalls – Bouncing Clock" (CFBundleName / CFBundleDisplayName).
    var displayName: String {
        flavor == .deployed ? title : "\(Self.namePrefix)\(title)"
    }

    /// Unique per scene; the scene ID is recoverable from it.
    var bundleIdentifier: String {
        (flavor == .deployed ? Self.deployedIdentifierPrefix : Self.identifierPrefix) + sceneID.lowercased()
    }

    /// Unique per scene and a valid Objective-C class name.
    var principalClassName: String {
        let digest = SHA256.hash(data: Data(sceneID.lowercased().utf8))
        let prefix = flavor == .deployed ? Self.deployedPrincipalClassPrefix : Self.principalClassPrefix
        return prefix + digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Filesystem-safe title: no path separators or control characters,
    /// collapsed whitespace, length-capped, never empty.
    static func sanitizedTitle(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if scalar == "/" || scalar == ":" || scalar == "\u{0}" || CharacterSet.controlCharacters.contains(scalar) {
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
        }
        var title = String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        if title.hasPrefix(".") {
            title.removeFirst()
        }
        if title.count > maximumTitleLength {
            title = String(title.prefix(maximumTitleLength)).trimmingCharacters(in: .whitespaces)
        }
        return title.isEmpty ? "Untitled" : title
    }

    /// The scene ID a generated bundle stands for, from its identifier.
    static func sceneID(fromBundleIdentifier identifier: String) -> String? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        let id = String(identifier.dropFirst(identifierPrefix.count))
        return id.isEmpty ? nil : id
    }

    /// True for a filename this feature generated (and may remove).
    static func isGeneratedBundleName(_ filename: String) -> Bool {
        filename.hasPrefix(namePrefix) && filename.hasSuffix(".\(bundleExtension)")
    }

    /// The template's Info.plist, re-identified for this scene.
    func infoDictionary(fromTemplate template: [String: Any]) -> [String: Any] {
        var info = template
        info["CFBundleName"] = displayName
        info["CFBundleDisplayName"] = displayName
        info["CFBundleIdentifier"] = bundleIdentifier
        info["NSPrincipalClass"] = principalClassName
        return info
    }
}
