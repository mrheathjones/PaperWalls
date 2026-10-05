import XCTest

// MARK: - Deployment packaging: wallpapers (Studio › Package › Wallpapers)

final class WallpaperDeploymentTests: XCTestCase {
    func testFilenameUsesTheTitleRulesAndALowercaseExtension() {
        XCTAssertEqual(WallpaperDeployment.filename(name: "Aurora Veil", sourcePath: "/Apps/01-aurora-veil.HEIC"),
                       "Aurora Veil.heic")
        XCTAssertEqual(WallpaperDeployment.filename(name: " Front / Desk: v2 ", sourcePath: "/x/photo.jpg"),
                       "Front Desk v2.jpg")
        XCTAssertEqual(WallpaperDeployment.filename(name: "", sourcePath: "/x/photo.png"), "Untitled.png")
        XCTAssertEqual(WallpaperDeployment.filename(name: "Raw", sourcePath: "/x/noext"), "Raw")
    }

    func testUniqueFilenamesResolveClashesCaseInsensitivelyInOrder() {
        XCTAssertEqual(WallpaperDeployment.uniqueFilenames(["Sky.jpg", "sky.JPG", "Sky.jpg", "Sea.png"]),
                       ["Sky.jpg", "sky 2.JPG", "Sky 3.jpg", "Sea.png"])
        XCTAssertEqual(WallpaperDeployment.uniqueFilenames([]), [])
    }

    func testInstallDirectoryValidation() {
        for good in [WallpaperDeployment.defaultInstallDirectory, "/Library/CompanyWallpapers",
                     "/Users/Shared/Wallpapers", "/Library/Desktop Pictures/Acme/", "  /Library/W  "] {
            XCTAssertTrue(WallpaperDeployment.isValidInstallDirectory(good), good)
        }
        for bad in ["", "/", "Library/W", "~/Wallpapers", "/Users/me/Pictures", "/Users/Shared", "/System/Library/W",
                    "/private/tmp/w", "/usr/local/w", "/tmp/w", "/Library/../etc", "/Library//W", "/Library/./W"] {
            XCTAssertFalse(WallpaperDeployment.isValidInstallDirectory(bad), bad)
        }
        XCTAssertEqual(WallpaperDeployment.normalizedInstallDirectory("  /Library/Acme/  "), "/Library/Acme")
        XCTAssertEqual(WallpaperDeployment.normalizedInstallDirectory("/"), "/")
        XCTAssertEqual(WallpaperDeployment.installedPath(for: .init(source: "/x/a.jpg", filename: "A.jpg"),
                                                         installDirectory: "/Library/Acme/"),
                       "/Library/Acme/A.jpg")
    }

    func testPackageIdentifierFollowsTheKind() {
        let savers = DeploymentPackageSpec(name: "Acme Lobby", version: "1.2")
        let wallpapers = DeploymentPackageSpec(name: "Acme Lobby", version: "1.2", kind: .wallpapers)
        XCTAssertEqual(savers.identifier, "com.herojoneslabs.paperwalls.savers.acme-lobby")
        XCTAssertEqual(wallpapers.identifier, "com.herojoneslabs.paperwalls.wallpapers.acme-lobby")
        XCTAssertEqual(wallpapers.pkgFilename, "Acme Lobby-1.2.pkg")
        XCTAssertNotEqual(savers.identifier, wallpapers.identifier, "same name, different receipts")
    }

    func testSettingsForceOnlyTheFolderByDefault() {
        let settings = WallpaperDeploymentSettings(installDirectory: "/Library/Acme/")
        let forced = settings.preferenceSettings
        XCTAssertEqual(forced.count, 1)
        XCTAssertEqual(forced["externalWallpaperFolderPath"] as? String, "/Library/Acme")

        // Empty optionals are the same as absent ones.
        let empty = WallpaperDeploymentSettings(installDirectory: "/Library/Acme", defaultWallpaperID: "",
                                                lockMode: nil, allowedWallpaperIDs: [])
        XCTAssertEqual(empty.preferenceSettings.count, 1)
    }

    func testSettingsCarryDefaultLockAndAllowList() {
        let settings = WallpaperDeploymentSettings(installDirectory: "/Library/Acme",
                                                   defaultWallpaperID: "file:0123456789abcdef",
                                                   lockMode: .soft,
                                                   allowedWallpaperIDs: ["file:0123456789abcdef", "file:fedcba9876543210"])
        let forced = settings.preferenceSettings
        XCTAssertEqual(forced["selectedWallpaperID"] as? String, "file:0123456789abcdef")
        XCTAssertEqual(forced["lockMode"] as? String, "soft")
        XCTAssertEqual(forced["lockSelection"] as? Bool, true, "legacy key keeps older builds locked too")
        XCTAssertEqual(forced["allowedWallpaperIDs"] as? [String], ["file:0123456789abcdef", "file:fedcba9876543210"])

        var unlocked = settings
        unlocked.lockMode = .off
        XCTAssertEqual(unlocked.preferenceSettings["lockSelection"] as? Bool, false)
    }

    func testProfileForcesTheSettingsInThePaperWallsDomain() throws {
        let settings = WallpaperDeploymentSettings(installDirectory: "/Library/Acme",
                                                   defaultWallpaperID: "file:0123456789abcdef", lockMode: .hard,
                                                   allowedWallpaperIDs: nil)
        let profile = WallpaperDeploymentProfile.profile(settings: settings, packageName: "Acme Wallpapers",
                                                         packageIdentifier: "com.example.wallpapers",
                                                         organization: "Acme")
        let payload = try XCTUnwrap((profile["PayloadContent"] as? [[String: Any]])?.first)
        XCTAssertEqual(payload["PayloadType"] as? String, "com.apple.ManagedClient.preferences")
        XCTAssertEqual(payload["PayloadIdentifier"] as? String, "com.example.wallpapers.configure.mcx")
        let domain = try XCTUnwrap((payload["PayloadContent"] as? [String: Any])?["com.herojoneslabs.paperwalls"] as? [String: Any])
        let forced = try XCTUnwrap(((domain["Forced"] as? [[String: Any]])?.first)?["mcx_preference_settings"] as? [String: Any])
        XCTAssertEqual(forced["externalWallpaperFolderPath"] as? String, "/Library/Acme")
        XCTAssertEqual(forced["selectedWallpaperID"] as? String, "file:0123456789abcdef")
        XCTAssertEqual(forced["lockMode"] as? String, "hard")
        XCTAssertNil(forced["allowedWallpaperIDs"])
        XCTAssertEqual(profile["PayloadIdentifier"] as? String, "com.example.wallpapers.configure")
        XCTAssertEqual(profile["PayloadDisplayName"] as? String, "Acme Wallpapers Wallpapers")
        XCTAssertEqual(profile["PayloadOrganization"] as? String, "Acme")
        XCTAssertEqual(profile["PayloadScope"] as? String, "System")
        XCTAssertNoThrow(try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0))

        let anonymous = WallpaperDeploymentProfile.profile(settings: settings, packageName: "X",
                                                           packageIdentifier: "com.example.x", organization: "")
        XCTAssertEqual(anonymous["PayloadOrganization"] as? String, "YourOrg")
    }

    func testManagedJSONParsesBackToTheSameForcedKeys() throws {
        let settings = WallpaperDeploymentSettings(installDirectory: "/Library/Acme",
                                                   defaultWallpaperID: "file:0123456789abcdef", lockMode: nil,
                                                   allowedWallpaperIDs: ["file:0123456789abcdef"])
        let json = WallpaperDeploymentProfile.managedJSON(settings: settings)
        let parsed = try XCTUnwrap(LocalManagedConfig.parse(data: Data(json.utf8)))
        XCTAssertEqual(parsed.forced["externalWallpaperFolderPath"] as? String, "/Library/Acme")
        XCTAssertEqual(parsed.forced["selectedWallpaperID"] as? String, "file:0123456789abcdef")
        XCTAssertEqual(parsed.forced["allowedWallpaperIDs"] as? [String], ["file:0123456789abcdef"])
        XCTAssertNil(parsed.forced["lockMode"])
        XCTAssertTrue(json.contains("/Library/Acme"), "slashes stay readable")
    }

    func testDescriptionNamesWhatTheProfileDoes() {
        let folderOnly = WallpaperDeploymentSettings(installDirectory: "/Library/Acme")
        XCTAssertEqual(WallpaperDeploymentProfile.description(for: folderOnly, packageName: "Acme"),
                       "Shows the wallpapers installed by “Acme” in PaperWalls.")
        let everything = WallpaperDeploymentSettings(installDirectory: "/Library/Acme", defaultWallpaperID: "file:1",
                                                     lockMode: .soft, allowedWallpaperIDs: ["file:1"])
        let description = WallpaperDeploymentProfile.description(for: everything, packageName: "Acme")
        XCTAssertTrue(description.contains("default wallpaper"))
        XCTAssertTrue(description.contains("Soft Lock"))
        XCTAssertTrue(description.contains("Restricts"))
    }
}
