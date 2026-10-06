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

        // Only the imported images this scene uses — not the whole store.
        let assetsFolder = "\(mediaFolder)/Assets"
        var assetNames: [String] = []
        if case .image(let name)? = snapshot.scene?.background.source,
           snapshot.assetURL(named: name) != nil {
            assetNames.append(name)
        }
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

/// What a Studio › Package run ships: each kind installs somewhere else
/// and gets its own pkg identifier prefix, so a saver package and a
/// wallpaper package with the same name never share a receipt.
enum DeploymentKind: String, CaseIterable {
    case screenSavers
    case wallpapers

    var identifierPrefix: String {
        switch self {
        case .screenSavers: return DeploymentPackageSpec.identifierPrefix
        case .wallpapers: return WallpaperDeployment.identifierPrefix
        }
    }
}

/// One installer package holding one or more deployed scene bundles, or a
/// folder of wallpapers (`kind`).
struct DeploymentPackageSpec: Equatable {
    static let identifierPrefix = "com.herojoneslabs.paperwalls.savers."

    var name: String
    var version: String
    var kind: DeploymentKind = .screenSavers

    /// "com.herojoneslabs.paperwalls.savers.acme-lobby-savers"
    var identifier: String {
        kind.identifierPrefix + Self.slug(name)
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
    /// With `hideSystemClock` it also carries the PaperWalls clock policy
    /// (`ClockDelivery.paperWalls`).
    static func profile(bundle: SceneBundleSpec, packageIdentifier: String, organization: String,
                        hideSystemClock: Bool = false, includeLockScreen: Bool = true,
                        uuid: () -> UUID = UUID.init) -> [String: Any] {
        var settings: [String: Any] = [
            ManagedPreferenceKey.enforcedScreenSaverPath.rawValue: saverPath(for: bundle),
        ]
        if hideSystemClock {
            settings.merge(clockPolicySettings(includeLockScreen: includeLockScreen)) { _, new in new }
        }
        var description = "Keeps “\(bundle.displayName)” selected as the screen saver."
        if hideSystemClock {
            description += " Hides macOS's own clock over it\(includeLockScreen ? " and on the lock screen" : "") while the saver's scene draws a clock."
        }
        description += " Requires PaperWalls with its manage LaunchAgent on the Mac."
        return preferencesProfile(settings: settings,
                                  identifier: "\(packageIdentifier).enforce",
                                  payloadDisplayName: "Enforced Screen Saver",
                                  displayName: "\(bundle.displayName) Screen Saver",
                                  description: description,
                                  organization: organization, uuid: uuid)
    }

    /// A computer-level profile forcing PaperWalls-domain `settings`.
    private static func preferencesProfile(settings: [String: Any], identifier: String, payloadDisplayName: String,
                                           displayName: String, description: String, organization: String,
                                           uuid: () -> UUID) -> [String: Any] {
        let payload: [String: Any] = [
            "PayloadType": "com.apple.ManagedClient.preferences",
            "PayloadVersion": 1,
            "PayloadIdentifier": "\(identifier).mcx",
            "PayloadUUID": uuid().uuidString,
            "PayloadDisplayName": payloadDisplayName,
            "PayloadContent": [
                ManagedPreferences.domain: ["Forced": [["mcx_preference_settings": settings]]],
            ],
        ]
        return [
            "PayloadContent": [payload],
            "PayloadDescription": description,
            "PayloadDisplayName": displayName,
            "PayloadIdentifier": identifier,
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

    /// The same setting(s) for /Library/Application Support/PaperWalls/managed.json.
    static func managedJSON(bundle: SceneBundleSpec, hideSystemClock: Bool = false, includeLockScreen: Bool = true) -> String {
        var forced: [String: Any] = [ManagedPreferenceKey.enforcedScreenSaverPath.rawValue: saverPath(for: bundle)]
        if hideSystemClock {
            forced.merge(clockPolicySettings(includeLockScreen: includeLockScreen)) { _, new in new }
        }
        return managedJSON(forced: forced)
    }

    private static func managedJSON(forced: [String: Any]) -> String {
        let object: [String: Any] = ["forced": forced]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // MARK: macOS's clock over the saver

    /// How a package deals with the large clock macOS draws over every
    /// screen saver (two clocks, when the scene has one of its own). The
    /// admin picks the delivery that fits their fleet.
    enum ClockDelivery: String, CaseIterable {
        /// Nothing in the package.
        case leave
        /// A `com.apple.screensaver` profile forcing `showClock = false`:
        /// always off, locked, no PaperWalls needed on the Mac.
        case profile
        /// PaperWalls' `hideSystemSaverClock = whenSceneHasClock`: the
        /// manage agent turns the clock off while a clock scene is on
        /// screen and puts it back otherwise. Needs PaperWalls on the Mac.
        case paperWalls

        var displayName: String {
            switch self {
            case .leave: return "Leave to macOS"
            case .profile: return "Profile: always off"
            case .paperWalls: return "PaperWalls: off when the scene has a clock"
            }
        }
    }

    /// What the PaperWalls delivery sets.
    static let clockPolicyValue = SystemSaverClockPolicy.whenSceneHasClock

    /// The PaperWalls keys: the policy, plus the lock screen opt-out when
    /// the package leaves the lock screen alone (the key defaults to true).
    static func clockPolicySettings(includeLockScreen: Bool) -> [String: Any] {
        var settings: [String: Any] = [ManagedPreferenceKey.hideSystemSaverClock.rawValue: clockPolicyValue.rawValue]
        if !includeLockScreen {
            settings[ManagedPreferenceKey.hideSystemSaverClockOnLockScreen.rawValue] = false
        }
        return settings
    }

    /// The PaperWalls delivery on its own, for a package that doesn't
    /// enforce a saver.
    static func clockPolicyProfile(packageIdentifier: String, organization: String, includeLockScreen: Bool = true,
                                   uuid: () -> UUID = UUID.init) -> [String: Any] {
        preferencesProfile(settings: clockPolicySettings(includeLockScreen: includeLockScreen),
                           identifier: "\(packageIdentifier).clock",
                           payloadDisplayName: "Screen Saver Clock Policy",
                           displayName: "PaperWalls Screen Saver Clock",
                           description: "Hides macOS's own clock over the screen saver\(includeLockScreen ? " and on the lock screen" : "") while a PaperWalls saver whose scene draws a clock is selected. Requires PaperWalls with its manage LaunchAgent on the Mac.",
                           organization: organization, uuid: uuid)
    }

    static func clockPolicyManagedJSON(includeLockScreen: Bool = true) -> String {
        managedJSON(forced: clockPolicySettings(includeLockScreen: includeLockScreen))
    }

    /// The profile delivery: a computer-level profile forcing
    /// `com.apple.screensaver` `showClock = false` — the "On Screen Saver"
    /// half of "Show large clock" — and, with `includeLockScreen`, a second
    /// payload forcing `com.apple.loginwindow` `UsesLargeDateTime = false`,
    /// the "On Lock Screen" half. Only those keys, like the lock profile.
    static func hideClockProfile(packageIdentifier: String, organization: String, includeLockScreen: Bool = true,
                                 uuid: () -> UUID = UUID.init) -> [String: Any] {
        var payloads: [[String: Any]] = [[
            "PayloadType": SystemSaverClock.domain,
            "PayloadVersion": 1,
            "PayloadIdentifier": "\(packageIdentifier).hideclock.screensaver",
            "PayloadUUID": uuid().uuidString,
            "PayloadDisplayName": "Screen Saver Clock",
            SystemSaverClock.key: false,
        ]]
        if includeLockScreen {
            payloads.append([
                "PayloadType": SystemSaverClock.lockScreenDomain,
                "PayloadVersion": 1,
                "PayloadIdentifier": "\(packageIdentifier).hideclock.loginwindow",
                "PayloadUUID": uuid().uuidString,
                "PayloadDisplayName": "Lock Screen Clock",
                SystemSaverClock.lockScreenKey: false,
            ])
        }
        return [
            "PayloadContent": payloads,
            "PayloadDescription": "Turns off the large clock macOS shows over screen savers (Show large clock › On Screen Saver)\(includeLockScreen ? " and on the lock screen" : ""), so a saver with its own clock doesn't show two. Users can't turn it back on while the profile is installed.",
            "PayloadDisplayName": "Hide Screen Saver Clock",
            "PayloadIdentifier": "\(packageIdentifier).hideclock",
            "PayloadOrganization": organization.isEmpty ? "YourOrg" : organization,
            "PayloadRemovalDisallowed": false,
            "PayloadScope": "System",
            "PayloadType": "Configuration",
            "PayloadUUID": uuid().uuidString,
            "PayloadVersion": 1,
        ]
    }
}
