import Foundation
import os

/// Studio › Package › Wallpapers (admin mode): builds a deployable folder
/// of wallpapers from library images. One run produces a folder:
///
///     <Name>-<version>/
///       <Name>-<version>.pkg        installs every image to the install folder
///       Wallpapers/<name>.<ext>     the same files, for other delivery tools
///       Configure/                  optional: PaperWalls profile + managed.json that
///                                   point the Managed source at the folder (and set
///                                   a default, a lock tier, an allow-list)
///       DEPLOY.txt                  what's here and how to ship it
///
/// The files are copied byte for byte, so the content IDs computed here
/// (`file:<hash>`) are the ones every target Mac resolves.
enum WallpaperPackager {
    static let log = Logger(subsystem: ManagedPreferences.domain, category: "packager")

    struct Item: Identifiable {
        let wallpaper: CuratedWallpaper
        /// This Mac's copy of the image.
        let source: URL
        /// The name on target Macs (what the Managed source shows), with
        /// the source file's extension.
        let filename: String

        var id: String { wallpaper.id }
    }

    /// What Configure/ should force, by item.
    struct Configuration {
        /// Applied as `selectedWallpaperID`; nil leaves the desktop alone.
        var defaultItemID: String?
        /// nil leaves each Mac's lock tier alone.
        var lockMode: LockMode?
        /// `allowedWallpaperIDs` = the packaged set.
        var restrictToPackaged: Bool
    }

    struct Request {
        var package: DeploymentPackageSpec
        var items: [Item]
        var installDirectory: String
        var outputDirectory: URL
        /// "Developer ID Installer: …"; nil leaves the pkg unsigned.
        var installerIdentity: String?
        /// nil skips Configure/.
        var configuration: Configuration?
        var organization: String
    }

    struct Result {
        let folder: URL
        let pkg: URL
        /// The Configure/ profile, when one was requested.
        let profiles: [URL]
    }

    enum PackagingError: LocalizedError {
        case nothingSelected
        case invalidPackage
        case invalidInstallDirectory
        case duplicateFilenames([String])
        case unreadable(name: String, path: String)
        case unidentifiable(name: String)

        var errorDescription: String? {
            switch self {
            case .nothingSelected:
                return "Choose at least one wallpaper to package."
            case .invalidPackage:
                return "The package needs a name and a version like 1.0."
            case .invalidInstallDirectory:
                return "The install folder must be an absolute path outside any user's home folder, like \(WallpaperDeployment.defaultInstallDirectory)."
            case .duplicateFilenames(let names):
                return "Two wallpapers would share a file name: \(names.joined(separator: ", ")). Rename one."
            case .unreadable(let name, let path):
                return "“\(name)” can't be read: \(path)"
            case .unidentifiable(let name):
                return "“\(name)” couldn't be fingerprinted for its wallpaper ID."
            }
        }
    }

    // MARK: - Build

    @MainActor
    static func build(_ request: Request, progress: @escaping (String) -> Void) async throws -> Result {
        guard !request.items.isEmpty else { throw PackagingError.nothingSelected }
        guard request.package.isValid else { throw PackagingError.invalidPackage }
        guard WallpaperDeployment.isValidInstallDirectory(request.installDirectory) else {
            throw PackagingError.invalidInstallDirectory
        }
        let names = request.items.map { $0.filename.lowercased() }
        let duplicates = Set(names.filter { name in names.filter { $0 == name }.count > 1 })
        guard duplicates.isEmpty else { throw PackagingError.duplicateFilenames(duplicates.sorted()) }

        return try await Task.detached(priority: .userInitiated) {
            try assemble(request) { message in
                Task { @MainActor in progress(message) }
            }
        }.value
    }

    nonisolated private static func assemble(_ request: Request, progress: @escaping (String) -> Void) throws -> Result {
        let fileManager = FileManager.default
        let installDirectory = WallpaperDeployment.normalizedInstallDirectory(request.installDirectory)
        // Stage outside iCloud Drive — its extended attributes break signing.
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("PaperWallsPackage-\(UUID().uuidString)", isDirectory: true)
        let root = scratch.appendingPathComponent("root", isDirectory: true)
        let payload = URL(fileURLWithPath: root.path + installDirectory, isDirectory: true)
        try fileManager.createDirectory(at: payload, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        // 1. The images, plus the ID each one has once installed.
        var contentIDs: [String: String] = [:]
        for item in request.items {
            progress("Copying “\(item.wallpaper.displayName)”…")
            guard fileManager.isReadableFile(atPath: item.source.path) else {
                throw PackagingError.unreadable(name: item.wallpaper.displayName, path: item.source.path)
            }
            let staged = payload.appendingPathComponent(item.filename)
            try fileManager.copyItem(at: item.source, to: staged)
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: staged.path)
            guard let id = WallpaperContentID.id(forFileAt: staged) else {
                throw PackagingError.unidentifiable(name: item.wallpaper.displayName)
            }
            contentIDs[item.id] = id
        }
        try ProcessRunner.run("/usr/bin/xattr", ["-cr", root.path])

        // 2. The pkg
        progress("Building the installer package…")
        let builtPkg = try InstallerBuilder.build(root: root, scratch: scratch, package: request.package,
                                                  installerIdentity: request.installerIdentity)

        // 3. The output folder, swapped in whole
        progress("Writing the deployment folder…")
        let staging = scratch.appendingPathComponent("out", isDirectory: true)
        let wallpapers = staging.appendingPathComponent("Wallpapers", isDirectory: true)
        try fileManager.createDirectory(at: wallpapers, withIntermediateDirectories: true)
        try fileManager.copyItem(at: builtPkg, to: staging.appendingPathComponent(builtPkg.lastPathComponent))
        for item in request.items {
            try fileManager.copyItem(at: payload.appendingPathComponent(item.filename),
                                     to: wallpapers.appendingPathComponent(item.filename))
        }
        var settings: WallpaperDeploymentSettings?
        if let configuration = request.configuration {
            let resolved = WallpaperDeploymentSettings(
                installDirectory: installDirectory,
                defaultWallpaperID: configuration.defaultItemID.flatMap { contentIDs[$0] },
                lockMode: configuration.lockMode,
                allowedWallpaperIDs: configuration.restrictToPackaged
                    ? request.items.compactMap { contentIDs[$0.id] } : nil)
            settings = resolved
            let configure = staging.appendingPathComponent("Configure", isDirectory: true)
            try fileManager.createDirectory(at: configure, withIntermediateDirectories: true)
            let profile = WallpaperDeploymentProfile.profile(settings: resolved, packageName: request.package.name,
                                                             packageIdentifier: request.package.identifier,
                                                             organization: request.organization)
            try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
                .write(to: configure.appendingPathComponent(profileFilename(for: request.package)))
            try Data(WallpaperDeploymentProfile.managedJSON(settings: resolved).utf8)
                .write(to: configure.appendingPathComponent("managed.json"))
        }
        try Data(deployNotes(request, installDirectory: installDirectory, contentIDs: contentIDs, settings: settings).utf8)
            .write(to: staging.appendingPathComponent("DEPLOY.txt"))

        let folderName = (request.package.pkgFilename as NSString).deletingPathExtension
        let folder = request.outputDirectory.appendingPathComponent(folderName, isDirectory: true)
        if fileManager.fileExists(atPath: folder.path) {
            try fileManager.trashItem(at: folder, resultingItemURL: nil)
        }
        try fileManager.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        try fileManager.moveItem(at: staging, to: folder)
        log.info("Packaged \(request.items.count) wallpaper(s) as \(request.package.identifier, privacy: .public) \(request.package.version, privacy: .public)")
        let profiles = settings == nil
            ? []
            : [folder.appendingPathComponent("Configure", isDirectory: true).appendingPathComponent(profileFilename(for: request.package))]
        return Result(folder: folder, pkg: folder.appendingPathComponent(builtPkg.lastPathComponent), profiles: profiles)
    }

    /// "Acme Wallpapers – Configure PaperWalls.mobileconfig"
    nonisolated static func profileFilename(for package: DeploymentPackageSpec) -> String {
        "\(SceneBundleSpec.sanitizedTitle(package.name)) – Configure PaperWalls.mobileconfig"
    }

    // MARK: - DEPLOY.txt

    nonisolated static func deployNotes(_ request: Request, installDirectory: String,
                                        contentIDs: [String: String], settings: WallpaperDeploymentSettings?) -> String {
        let package = request.package
        let fileLines = request.items
            .map { "  • \(installDirectory)/\($0.filename)" }
            .joined(separator: "\n")
        let idLines = request.items
            .map { "  \(contentIDs[$0.id] ?? "?")  \($0.filename)" }
            .joined(separator: "\n")
        let pkgSigned = request.installerIdentity.map { "Package signed with \($0)." }
            ?? "Package is unsigned. Jamf Pro installs it as-is; MDM InstallEnterpriseApplication needs a signed pkg."
        let count = request.items.count == 1 ? "1 wallpaper" : "\(request.items.count) wallpapers"
        var notes = """
        \(package.name) \(package.version)
        Built by PaperWalls on \(Date().formatted(date: .abbreviated, time: .shortened)).

        WHAT'S HERE
        \(package.pkgFilename)
          Identifier \(package.identifier), version \(package.version). Installs \(count):
        \(fileLines)
        Wallpapers/
          The same files, for tools that copy files instead of installing pkgs.


        """
        if settings != nil {
            notes += """
            Configure/
              "\(profileFilename(for: package))" and managed.json: PaperWalls
              settings that show the folder in the app (see CONFIGURE below).


            """
        }
        notes += """
        SIGNING
        \(pkgSigned)
        The images themselves aren't code; only the installer carries a signature.


        """
        if request.installerIdentity != nil {
            notes += """
            To notarize (uses the same keychain profile as Deployment/build-pkg.sh):
              xcrun notarytool submit "\(package.pkgFilename)" --keychain-profile "PaperWalls-Notary" --wait
              xcrun stapler staple "\(package.pkgFilename)"


            """
        }
        notes += """
        DEPLOYING
        1. Upload the pkg to Jamf Pro (or your MDM) and scope a policy to the target Macs.
           It only puts files in \(installDirectory); nothing changes on the desktop yet.
        2. Point PaperWalls at the folder: deploy Configure/ (below), or set
           externalWallpaperFolderPath = "\(installDirectory)" in the PaperWalls
           profile you already manage. The wallpapers then appear under the company
           source in Browse and the sidebar, and join the rotation pool's "\(RotationPoolMember.orgFolder.rawValue)".
        3. To ship a change, raise the version number and package again. Installing a
           newer version doesn't remove wallpapers that were dropped from the package.


        """
        if let settings {
            notes += """
            CONFIGURE (Configure/)
            Deploy the profile through your MDM, or copy managed.json to
            /Library/Application Support/PaperWalls/ on Macs without MDM. It forces:
              externalWallpaperFolderPath  \(installDirectory)


            """
            if let id = settings.defaultWallpaperID,
               let item = request.items.first(where: { contentIDs[$0.id] == id }) {
                notes += """
                  selectedWallpaperID          \(id)  (\(item.filename))
                    The PaperWalls manage LaunchAgent (in the PaperWalls pkg) applies it at
                    login and hourly. To apply it at once, run as the user:  paperwallscli manage


                """
            }
            if let lockMode = settings.lockMode {
                notes += "  lockMode                     \(lockMode.rawValue)  (\(lockMode.displayName))\n"
                switch lockMode {
                case .off:
                    notes += "    Users keep choosing their own wallpaper.\n"
                case .soft:
                    notes += "    Only the default can be applied; users can still browse.\n"
                case .hard:
                    notes += """
                        Nothing else can be applied in the app or CLI. For an OS-level lock as well,
                        see Deployment/com.herojoneslabs.paperwalls.lock.mobileconfig (Tier 2) and
                        point its override-picture-path at the default wallpaper's installed path.

                    """
                case .enforcedRotation:
                    notes += "    Rotation continues within the allow-list (or the rotation pool); the watch agent reverts strays.\n"
                }
                notes += "\n"
            }
            if settings.allowedWallpaperIDs?.isEmpty == false {
                notes += """
                  allowedWallpaperIDs          the packaged wallpapers only
                    Bundled, macOS, feed and personal wallpapers are hidden on target Macs.


                """
            }
            notes += """
            If an existing PaperWalls profile already forces any of these keys, merge the
            values into it instead — two profiles forcing the same key is a coin toss.


            """
        }
        notes += """
        WALLPAPER IDS
        Content-derived, so they're identical on every Mac with the same file. Use them
        in selectedWallpaperID and allowedWallpaperIDs (profile, managed.json, or CLI).
        \(idLines)

        REMOVING
          sudo rm -rf "\(installDirectory)"
          sudo pkgutil --forget \(package.identifier)
        Then remove the Configure/ profile (or its keys) so the app stops looking there.


        """
        return notes
    }
}
