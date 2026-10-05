import Foundation
import os

/// Studio › Package (admin mode): builds deployable screen savers from
/// library scenes. One run produces a folder:
///
///     <Name>-<version>/
///       <Name>-<version>.pkg        installs every saver to /Library/Screen Savers
///       Savers/<Display Name>.saver the same bundles, for other delivery tools
///       Enforce/                    optional: keeps one saver selected (profile + managed.json)
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
        var organization: String
    }

    struct Result {
        let folder: URL
        let pkg: URL
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

        // 2. The pkg
        progress("Building the installer package…")
        let root = scratch.appendingPathComponent("root", isDirectory: true)
        let componentPlist = scratch.appendingPathComponent("components.plist")
        try ProcessRunner.run("/usr/bin/pkgbuild", ["--analyze", "--root", root.path, componentPlist.path])
        try pinComponents(at: componentPlist)
        // The saver host keeps loaded code for its whole life, so an update
        // only takes effect once it restarts (the system relaunches it).
        let scripts = scratch.appendingPathComponent("scripts", isDirectory: true)
        try fileManager.createDirectory(at: scripts, withIntermediateDirectories: true)
        let postinstall = scripts.appendingPathComponent("postinstall")
        try Data("""
            #!/bin/bash
            /usr/bin/killall legacyScreenSaver legacyScreenSaver-x86_64 2>/dev/null
            exit 0

            """.utf8).write(to: postinstall)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: postinstall.path)
        let componentPkg = scratch.appendingPathComponent("component.pkg")
        try ProcessRunner.run("/usr/bin/pkgbuild", [
            "--root", root.path,
            "--component-plist", componentPlist.path,
            "--scripts", scripts.path,
            "--identifier", request.package.identifier,
            "--version", request.package.version,
            "--install-location", "/",
            componentPkg.path,
        ])
        let builtPkg = scratch.appendingPathComponent(request.package.pkgFilename)
        var productArguments = ["--package", componentPkg.path]
        if let identity = request.installerIdentity, !identity.isEmpty {
            productArguments += ["--sign", identity, "--timestamp"]
        }
        try ProcessRunner.run("/usr/bin/productbuild", productArguments + [builtPkg.path])

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
        if let saver = request.enforcedSaver {
            let enforce = staging.appendingPathComponent("Enforce", isDirectory: true)
            try fileManager.createDirectory(at: enforce, withIntermediateDirectories: true)
            let profile = DeploymentEnforcement.profile(bundle: saver, packageIdentifier: request.package.identifier,
                                                        organization: request.organization)
            try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
                .write(to: enforce.appendingPathComponent("\(saver.title) – Enforce Screen Saver.mobileconfig"))
            try Data(DeploymentEnforcement.managedJSON(bundle: saver).utf8)
                .write(to: enforce.appendingPathComponent("managed.json"))
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
        return Result(folder: folder, pkg: folder.appendingPathComponent(builtPkg.lastPathComponent))
    }

    /// Installs exactly where we put them: no relocation to a copy the
    /// user moved, no skipping because an installed copy looks newer.
    nonisolated private static func pinComponents(at url: URL) throws {
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
           or PaperWalls can keep one selected (ENFORCE, below).
        3. Each saver shows its own scene and carries its own images. The PaperWalls app
           isn't required on the target Mac.
        4. To ship a new version, raise the version number and package again. The pkg
           restarts the screen saver host so the new version loads; reopen System
           Settings to see it.

        """
        if let saver = request.enforcedSaver {
            notes += """
            ENFORCE (Enforce/)
            Keeps \(DeploymentEnforcement.saverPath(for: saver)) selected for every
            Space and display. Deploy the .mobileconfig through your MDM, or copy managed.json
            to /Library/Application Support/PaperWalls/ on Macs without MDM. Either sets
            enforcedScreenSaverPath; the PaperWalls manage LaunchAgent (in the PaperWalls pkg)
            applies it at login and hourly. To apply it immediately, run this as the user:
              paperwallscli screensaver enforce
            Needs PaperWalls 0.3.3 or later on the Mac. Apple's own com.apple.screensaver
            profile keys don't select third-party savers on macOS 14 and later.

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
