import Foundation
import os

/// Studio › Package (admin mode): builds deployable screen savers from
/// library scenes. One run produces a folder:
///
///     <Name>-<version>/
///       <Name>-<version>.pkg        installs every saver to /Library/Screen Savers
///       Savers/<Display Name>.saver the same bundles, for other delivery tools
///       Enforce/                    optional: selects (PaperWalls profile / managed.json) and locks (screensaver profile) one saver,
///                                   and/or hides macOS's clock over the saver (profile, or PaperWalls policy)
///       MDM/<scene>.json            managedScreenSaverScene values
///       DEPLOY.txt                  what's here and how to ship it
///
/// Each saver is a scene bundle (see `SceneBundleSpec`, `.deployed`) that
/// carries its own images, so it shows the same thing on every Mac.
enum ScenePackager {
    static let log = Logger(subsystem: ManagedPreferences.domain, category: "packager")

    struct Item {
        let spec: SceneBundleSpec
        /// Resolved with this Mac's absolute paths; made portable here.
        let snapshot: ScreenSaverSnapshot
        /// `managedScreenSaverScene` JSON for this scene, if it has one.
        let managedSceneJSON: String?
    }

    struct Request {
        var package: DeploymentPackageSpec
        var items: [Item]
        var outputDirectory: URL
        /// "Developer ID Application: …"; nil signs the savers ad hoc.
        var appIdentity: String?
        /// "Developer ID Installer: …"; nil leaves the pkg unsigned.
        var installerIdentity: String?
        /// The saver to keep selected on target Macs (`enforcedScreenSaverPath`);
        /// nil skips it.
        var enforcedSaver: SceneBundleSpec?
        /// What to do about macOS's large clock over the saver.
        var systemClock: DeploymentEnforcement.ClockDelivery = .leave
        var organization: String
    }

    struct Result {
        let folder: URL
        let pkg: URL
        /// The Enforce/ profiles: select + lock when a saver is enforced,
        /// and the clock profile or policy when one is included.
        let profiles: [URL]
    }

    enum PackagingError: LocalizedError {
        case noTemplate
        case nothingSelected
        case invalidPackage
        case duplicateNames([String])
        case missingMedia(scene: String, path: String)

        var errorDescription: String? {
            switch self {
            case .noTemplate:
                return "This copy of PaperWalls has no built-in screen saver to package."
            case .nothingSelected:
                return "Choose at least one screen saver to package."
            case .invalidPackage:
                return "The package needs a name and a version like 1.0."
            case .duplicateNames(let names):
                return "Two screen savers would share a name: \(names.joined(separator: ", ")). Rename one."
            case .missingMedia(let scene, let path):
                return "“\(scene)” uses an image that can't be read: \(path)"
            }
        }
    }

    // MARK: - Build

    @MainActor
    static func build(_ request: Request, progress: @escaping (String) -> Void) async throws -> Result {
        guard let templateURL = SceneBundleManager.templateURL else { throw PackagingError.noTemplate }
        guard !request.items.isEmpty else { throw PackagingError.nothingSelected }
        guard request.package.isValid else { throw PackagingError.invalidPackage }
        let names = request.items.map(\.spec.bundleName)
        let duplicates = Set(names.filter { name in names.filter { $0 == name }.count > 1 })
        guard duplicates.isEmpty else { throw PackagingError.duplicateNames(duplicates.sorted()) }

        // Thumbnails render on the main actor, from the original paths.
        var prepared: [(item: Item, thumbnails: SceneBundleManager.Thumbnails)] = []
        for item in request.items {
            progress("Rendering “\(item.spec.displayName)”…")
            prepared.append((item, await SceneBundleManager.renderThumbnails(for: item.snapshot)))
        }

        return try await Task.detached(priority: .userInitiated) {
            try assemble(request, prepared: prepared, templateURL: templateURL) { message in
                Task { @MainActor in progress(message) }
            }
        }.value
    }

    nonisolated private static func assemble(_ request: Request,
                                             prepared: [(item: Item, thumbnails: SceneBundleManager.Thumbnails)],
                                             templateURL: URL,
                                             progress: @escaping (String) -> Void) throws -> Result {
        let fileManager = FileManager.default
        // Stage outside iCloud Drive — its extended attributes break codesign.
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("PaperWallsPackage-\(UUID().uuidString)", isDirectory: true)
        let payloadSavers = scratch.appendingPathComponent("root/Library/Screen Savers", isDirectory: true)
        try fileManager.createDirectory(at: payloadSavers, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        // 1. The savers
        for (item, thumbnails) in prepared {
            progress("Building “\(item.spec.displayName)”…")
            let (portable, media) = SceneDeployment.portable(item.snapshot)
            for file in media where !fileManager.isReadableFile(atPath: file.source) {
                throw PackagingError.missingMedia(scene: item.spec.displayName, path: file.source)
            }
            try SceneBundleManager.stage(spec: item.spec, snapshot: portable, thumbnails: thumbnails,
                                         templateURL: templateURL, in: payloadSavers,
                                         extraInfo: ["CFBundleShortVersionString": request.package.version],
                                         media: media, signingIdentity: request.appIdentity)
        }
        try ProcessRunner.run("/usr/bin/xattr", ["-cr", payloadSavers.path])

        // 2. The pkg. The saver host keeps loaded code for its whole life,
        // so an update only takes effect once it restarts (the system
        // relaunches it).
        progress("Building the installer package…")
        let builtPkg = try InstallerBuilder.build(
            root: scratch.appendingPathComponent("root", isDirectory: true),
            scratch: scratch,
            package: request.package,
            postinstall: """
                #!/bin/bash
                /usr/bin/killall legacyScreenSaver legacyScreenSaver-x86_64 2>/dev/null
                exit 0

                """,
            installerIdentity: request.installerIdentity)

        // 3. The output folder, swapped in whole
        progress("Writing the deployment folder…")
        let staging = scratch.appendingPathComponent("out", isDirectory: true)
        let savers = staging.appendingPathComponent("Savers", isDirectory: true)
        try fileManager.createDirectory(at: savers, withIntermediateDirectories: true)
        try fileManager.copyItem(at: builtPkg, to: staging.appendingPathComponent(builtPkg.lastPathComponent))
        for (item, _) in prepared {
            try fileManager.copyItem(at: payloadSavers.appendingPathComponent(item.spec.bundleName),
                                     to: savers.appendingPathComponent(item.spec.bundleName))
        }
        let mdmItems = prepared.compactMap { entry in entry.item.managedSceneJSON.map { (entry.item.spec, $0) } }
        if !mdmItems.isEmpty {
            let mdm = staging.appendingPathComponent("MDM", isDirectory: true)
            try fileManager.createDirectory(at: mdm, withIntermediateDirectories: true)
            for (spec, json) in mdmItems {
                try Data(json.utf8).write(to: mdm.appendingPathComponent("\(spec.title).json"))
            }
        }
        var profilePaths: [String] = []   // relative to the output folder
        let enforce = staging.appendingPathComponent("Enforce", isDirectory: true)
        func writeProfile(_ profile: [String: Any], named name: String) throws {
            try fileManager.createDirectory(at: enforce, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
                .write(to: enforce.appendingPathComponent(name))
            profilePaths.append("Enforce/\(name)")
        }
        let hideClockViaPaperWalls = request.systemClock == .paperWalls
        let packageTitle = SceneBundleSpec.sanitizedTitle(request.package.name)
        if let saver = request.enforcedSaver {
            let profile = DeploymentEnforcement.profile(bundle: saver, packageIdentifier: request.package.identifier,
                                                        organization: request.organization,
                                                        hideSystemClock: hideClockViaPaperWalls)
            try writeProfile(profile, named: "\(saver.title) – Enforce Screen Saver.mobileconfig")
            try Data(DeploymentEnforcement.managedJSON(bundle: saver, hideSystemClock: hideClockViaPaperWalls).utf8)
                .write(to: enforce.appendingPathComponent("managed.json"))
            let lock = DeploymentEnforcement.lockProfile(bundle: saver, packageIdentifier: request.package.identifier,
                                                         organization: request.organization)
            try writeProfile(lock, named: "\(saver.title) – Lock Screen Saver.mobileconfig")
        } else if hideClockViaPaperWalls {
            let profile = DeploymentEnforcement.clockPolicyProfile(packageIdentifier: request.package.identifier,
                                                                   organization: request.organization)
            try writeProfile(profile, named: "\(packageTitle) – PaperWalls Clock Policy.mobileconfig")
            try Data(DeploymentEnforcement.clockPolicyManagedJSON().utf8)
                .write(to: enforce.appendingPathComponent("managed.json"))
        }
        if request.systemClock == .profile {
            let profile = DeploymentEnforcement.hideClockProfile(packageIdentifier: request.package.identifier,
                                                                 organization: request.organization)
            try writeProfile(profile, named: "\(packageTitle) – Hide System Clock.mobileconfig")
        }
        try Data(deployNotes(request, includesMDM: !mdmItems.isEmpty).utf8)
            .write(to: staging.appendingPathComponent("DEPLOY.txt"))

        let folderName = (request.package.pkgFilename as NSString).deletingPathExtension
        let folder = request.outputDirectory.appendingPathComponent(folderName, isDirectory: true)
        if fileManager.fileExists(atPath: folder.path) {
            try fileManager.trashItem(at: folder, resultingItemURL: nil)
        }
        try fileManager.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        try fileManager.moveItem(at: staging, to: folder)
        log.info("Packaged \(prepared.count) screen saver(s) as \(request.package.identifier, privacy: .public) \(request.package.version, privacy: .public)")
        return Result(folder: folder, pkg: folder.appendingPathComponent(builtPkg.lastPathComponent),
                      profiles: profilePaths.map { folder.appendingPathComponent($0) })
    }

    // MARK: - DEPLOY.txt

    nonisolated static func deployNotes(_ request: Request, includesMDM: Bool) -> String {
        let package = request.package
        let saverLines = request.items
            .map { item -> String in
                var line = "  • \(SceneDeployment.installDirectory)/\(item.spec.bundleName)"
                if case .currentDesktop? = item.snapshot.scene?.background.source {
                    line += "\n      (background: each Mac's own desktop picture)"
                }
                return line
            }
            .joined(separator: "\n")
        let signed = request.appIdentity.map { "Savers signed with \($0) (hardened runtime)." }
            ?? "Savers are signed ad hoc."
        let pkgSigned = request.installerIdentity.map { "Package signed with \($0)." }
            ?? "Package is unsigned. Jamf Pro installs it as-is; MDM InstallEnterpriseApplication needs a signed pkg."
        var notes = """
        \(package.name) \(package.version)
        Built by PaperWalls on \(Date().formatted(date: .abbreviated, time: .shortened)).

        WHAT'S HERE
        \(package.pkgFilename)
          Identifier \(package.identifier), version \(package.version). Installs:
        \(saverLines)
        Savers/
          The same bundles, for tools that copy files instead of installing pkgs.

        SIGNING
        \(signed)
        \(pkgSigned)


        """
        if request.appIdentity != nil, request.installerIdentity != nil {
            notes += """
            To notarize (uses the same keychain profile as Deployment/build-pkg.sh):
              xcrun notarytool submit "\(package.pkgFilename)" --keychain-profile "PaperWalls-Notary" --wait
              xcrun stapler staple "\(package.pkgFilename)"


            """
        }
        notes += """
        DEPLOYING
        1. Upload the pkg to Jamf Pro (or your MDM) and scope a policy to the target Macs.
        2. Each saver appears under System Settings › Screen Saver. Users can pick one,
           or ENFORCE (below) can select one and lock it.
        3. Each saver shows its own scene and carries its own images. The PaperWalls app
           isn't required on the target Mac.
        4. To ship a new version, raise the version number and package again. The pkg
           restarts the screen saver host so the new version loads; reopen System
           Settings to see it.


        """
        if let saver = request.enforcedSaver {
            notes += """
            ENFORCE (Enforce/)
            Makes \(DeploymentEnforcement.saverPath(for: saver)) the screen saver.
            Deploy both parts; each does half the job on macOS 14 and later:

              SELECT  "\(saver.title) – Enforce Screen Saver.mobileconfig" (or managed.json in
                      /Library/Application Support/PaperWalls/ on Macs without MDM) sets
                      enforcedScreenSaverPath. The PaperWalls manage LaunchAgent (in the
                      PaperWalls pkg) writes the selection for every Space and display, at
                      login and hourly. Needs PaperWalls 0.3.3 or later. To apply it at once,
                      run this as the user:  paperwallscli screensaver enforce
              LOCK    "\(saver.title) – Lock Screen Saver.mobileconfig" forces
                      com.apple.screensaver moduleName = "\(DeploymentEnforcement.moduleName(for: saver))", so users
                      can't pick another saver. On its own it doesn't select the saver; it
                      only locks one that's already selected.

            With SELECT alone, users can change the saver until the next agent run. Keep
            idle time and password settings in your existing screen saver profile; if it
            already sets moduleName, use that instead of the LOCK profile.


            """
        }
        switch request.systemClock {
        case .leave:
            break
        case .profile:
            let name = SceneBundleSpec.sanitizedTitle(request.package.name)
            notes += """
            SYSTEM CLOCK (Enforce/)
            macOS draws its own large clock over every screen saver when System Settings ›
            Wallpaper › Clock Appearance › "Show large clock" includes the screen saver — two
            clocks, for a scene that draws one. "\(name) – Hide System Clock.mobileconfig"
            forces com.apple.screensaver showClock = false (the "On Screen Saver" half of that
            setting; the lock screen clock is untouched). Users can't turn it back on while
            the profile is installed. Nothing from PaperWalls is needed on the Mac. If your
            own screen saver profile already sets showClock, use that instead.


            """
        case .paperWalls:
            let carrier = request.enforcedSaver != nil
                ? "the SELECT profile and managed.json above also set"
                : "\"\(SceneBundleSpec.sanitizedTitle(request.package.name)) – PaperWalls Clock Policy.mobileconfig\" (or managed.json in /Library/Application Support/PaperWalls/ on Macs without MDM) sets"
            notes += """
            SYSTEM CLOCK (Enforce/)
            macOS draws its own large clock over every screen saver when System Settings ›
            Wallpaper › Clock Appearance › "Show large clock" includes the screen saver — two
            clocks, for a scene that draws one. Here \(carrier)
            hideSystemSaverClock = whenSceneHasClock. The PaperWalls manage LaunchAgent (and
            the app) then turns macOS's clock off while a PaperWalls saver whose scene draws a
            clock is the selected one, and puts the user's setting back when it isn't. The
            key is honored by PaperWalls 0.8 or later; a configuration profile that forces
            showClock wins over it. To apply at once, run as the user:
              paperwallscli screensaver enforce


            """
        }
        if includesMDM {
            notes += """
            MDM (MDM/)
            Each file is a managedScreenSaverScene value for the com.herojoneslabs.paperwalls
            domain. Use it to provision the scene inside the PaperWalls app itself (its
            "Managed" screen saver), instead of or alongside the packaged savers.


            """
        }
        notes += """
        REMOVING
          sudo rm -rf "/Library/Screen Savers/<name>.saver"
          sudo pkgutil --forget \(package.identifier)
        Installing a new version doesn't remove savers that were dropped from the package.


        """
        return notes
    }
}

/// The pkgbuild → productbuild steps shared by the saver and wallpaper
/// packagers: a payload root becomes one flat distribution package, signed
/// when an installer identity is given.
enum InstallerBuilder {
    /// Returns the built pkg inside `scratch`, named `package.pkgFilename`.
    static func build(root: URL, scratch: URL, package: DeploymentPackageSpec,
                      postinstall: String? = nil, installerIdentity: String?) throws -> URL {
        let fileManager = FileManager.default
        let componentPlist = scratch.appendingPathComponent("components.plist")
        try ProcessRunner.run("/usr/bin/pkgbuild", ["--analyze", "--root", root.path, componentPlist.path])
        try pinComponents(at: componentPlist)
        var arguments = [
            "--root", root.path,
            "--component-plist", componentPlist.path,
            "--identifier", package.identifier,
            "--version", package.version,
            "--install-location", "/",
        ]
        if let postinstall {
            let scripts = scratch.appendingPathComponent("scripts", isDirectory: true)
            try fileManager.createDirectory(at: scripts, withIntermediateDirectories: true)
            let script = scripts.appendingPathComponent("postinstall")
            try Data(postinstall.utf8).write(to: script)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            arguments += ["--scripts", scripts.path]
        }
        let componentPkg = scratch.appendingPathComponent("component.pkg")
        try ProcessRunner.run("/usr/bin/pkgbuild", arguments + [componentPkg.path])

        let builtPkg = scratch.appendingPathComponent(package.pkgFilename)
        var productArguments = ["--package", componentPkg.path]
        if let installerIdentity, !installerIdentity.isEmpty {
            productArguments += ["--sign", installerIdentity, "--timestamp"]
        }
        try ProcessRunner.run("/usr/bin/productbuild", productArguments + [builtPkg.path])
        return builtPkg
    }

    /// Installs bundles exactly where we put them: no relocation to a copy
    /// the user moved, no skipping because an installed copy looks newer.
    /// A payload without bundles (wallpapers) analyzes to an empty list.
    private static func pinComponents(at url: URL) throws {
        let data = try Data(contentsOf: url)
        guard var components = try PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        for index in components.indices {
            components[index]["BundleIsRelocatable"] = false
            components[index]["BundleIsVersionChecked"] = false
            components[index]["BundleOverwriteAction"] = "upgrade"
        }
        try PropertyListSerialization.data(fromPropertyList: components, format: .xml, options: 0).write(to: url)
    }
}

/// Code-signing and installer-signing identities in the login keychain.
enum SigningIdentities {
    /// "Developer ID Application: …" (also Apple Development, for testing).
    static func codeSigning() -> [String] {
        identities(policy: "codesigning").filter {
            $0.hasPrefix("Developer ID Application:") || $0.hasPrefix("Apple Development:")
        }
    }

    /// "Developer ID Installer: …"
    static func installer() -> [String] {
        identities(policy: "basic").filter { $0.hasPrefix("Developer ID Installer:") }
    }

    private static func identities(policy: String) -> [String] {
        guard let output = try? ProcessRunner.run("/usr/bin/security", ["find-identity", "-v", "-p", policy]) else {
            return []
        }
        return SceneDeployment.identityNames(fromFindIdentityOutput: output)
    }
}
