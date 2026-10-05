import XCTest

// MARK: - Scene bundles: naming and identity (spec §10)

final class SceneBundleSpecTests: XCTestCase {
    private let id = "9BF01BF4-AFC4-4567-AF74-281FB1FABF61"

    func testNamesFollowThePrefixConvention() {
        let spec = SceneBundleSpec(sceneID: id, name: "Bouncing Clock", isManaged: false)
        XCTAssertEqual(spec.bundleName, "PaperWalls – Bouncing Clock.saver")
        XCTAssertEqual(spec.displayName, "PaperWalls – Bouncing Clock")
        XCTAssertTrue(SceneBundleSpec.isGeneratedBundleName(spec.bundleName))
        XCTAssertFalse(SceneBundleSpec.isGeneratedBundleName("PaperWalls.saver"))
        XCTAssertFalse(SceneBundleSpec.isGeneratedBundleName("Aerial.saver"))
    }

    func testManagedSceneIsMarkedSoItCannotCollideWithAUserScene() {
        let managed = SceneBundleSpec(sceneID: ScreenSaverSceneStore.managedSceneID, name: "Lobby", isManaged: true)
        let mine = SceneBundleSpec(sceneID: id, name: "Lobby", isManaged: false)
        XCTAssertEqual(managed.bundleName, "PaperWalls – Lobby (Managed).saver")
        XCTAssertNotEqual(managed.bundleName, mine.bundleName)
        XCTAssertNotEqual(managed.principalClassName, mine.principalClassName)
    }

    func testIdentifierRoundTripsTheSceneID() {
        let spec = SceneBundleSpec(sceneID: id, name: "x", isManaged: false)
        XCTAssertEqual(spec.bundleIdentifier, "com.herojoneslabs.paperwalls.saver.scene." + id.lowercased())
        XCTAssertEqual(SceneBundleSpec.sceneID(fromBundleIdentifier: spec.bundleIdentifier), id.lowercased())
        XCTAssertNil(SceneBundleSpec.sceneID(fromBundleIdentifier: "com.herojoneslabs.paperwalls.saver"))
        XCTAssertNil(SceneBundleSpec.sceneID(fromBundleIdentifier: SceneBundleSpec.identifierPrefix))
    }

    func testPrincipalClassNameIsStableUniqueAndValid() {
        let a = SceneBundleSpec(sceneID: id, name: "A", isManaged: false)
        let again = SceneBundleSpec(sceneID: id.lowercased(), name: "Renamed", isManaged: false)
        let b = SceneBundleSpec(sceneID: UUID().uuidString, name: "A", isManaged: false)
        XCTAssertEqual(a.principalClassName, again.principalClassName, "depends on the ID only")
        XCTAssertNotEqual(a.principalClassName, b.principalClassName)
        XCTAssertTrue(a.principalClassName.hasPrefix("PaperWallsScene_"))
        XCTAssertEqual(a.principalClassName.count, "PaperWallsScene_".count + 8)
        XCTAssertTrue(a.principalClassName.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" })
    }

    func testTitlesAreFilesystemSafe() {
        XCTAssertEqual(SceneBundleSpec.sanitizedTitle("Front / Desk: Clock"), "Front Desk Clock")
        XCTAssertEqual(SceneBundleSpec.sanitizedTitle("  spaced   out  "), "spaced out")
        XCTAssertEqual(SceneBundleSpec.sanitizedTitle(".hidden"), "hidden")
        XCTAssertEqual(SceneBundleSpec.sanitizedTitle(""), "Untitled")
        XCTAssertEqual(SceneBundleSpec.sanitizedTitle("tab\there"), "tab here")
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(SceneBundleSpec.sanitizedTitle(long).count, SceneBundleSpec.maximumTitleLength)
    }

    func testInfoDictionaryKeepsEverythingElseFromTheTemplate() {
        let spec = SceneBundleSpec(sceneID: id, name: "Bouncing Clock", isManaged: false)
        let template: [String: Any] = [
            "CFBundleName": "PaperWalls", "CFBundleIdentifier": "com.herojoneslabs.paperwalls.saver",
            "NSPrincipalClass": "PaperWallsSaverView", "CFBundleVersion": "18",
            "CFBundleExecutable": "PaperWalls", "LSMinimumSystemVersion": "26.0",
        ]
        let info = spec.infoDictionary(fromTemplate: template)
        XCTAssertEqual(info["CFBundleName"] as? String, "PaperWalls – Bouncing Clock")
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "PaperWalls – Bouncing Clock")
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, spec.bundleIdentifier)
        XCTAssertEqual(info["NSPrincipalClass"] as? String, spec.principalClassName)
        // Untouched: the executable name, version, and minimum OS.
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "PaperWalls")
        XCTAssertEqual(info["CFBundleVersion"] as? String, "18")
        XCTAssertEqual(info["LSMinimumSystemVersion"] as? String, "26.0")
    }
}

// MARK: - Listed flag on stored scenes

final class StoredScreenSaverListingTests: XCTestCase {
    func testListedFlagRoundTripsAndDefaultsOff() throws {
        var saver = StoredScreenSaver(name: "Clock", scene: ScreenSaverPreset.minimalClock.scene)
        XCTAssertFalse(saver.isListedInSystemSettings)
        saver.listedInSystemSettings = true

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StoredScreenSaver.self, from: encoder.encode(saver))
        XCTAssertTrue(decoded.listedInSystemSettings)

        // A file written before the flag existed has no such key.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(saver)) as? [String: Any])
        object["listedInSystemSettings"] = nil
        let older = try decoder.decode(StoredScreenSaver.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(older.listedInSystemSettings)
    }

    func testManagedSceneIsAlwaysListed() {
        var managed = StoredScreenSaver(name: "Lobby", scene: ScreenSaverScene())
        managed.id = ScreenSaverSceneStore.managedSceneID
        XCTAssertTrue(managed.isListedInSystemSettings)
    }

    func testPerSceneSnapshotCarriesTheSceneRegardlessOfPolicy() {
        var saver = StoredScreenSaver(name: "Wall", scene: ScreenSaverScene(
            background: SceneBackground(source: .wallpaper(id: "bundled-dune")), layers: [.clock()]))
        saver.listedInSystemSettings = true
        let snapshot = ScreenSaverSnapshot.forScene(saver, companyName: "Acme", assetsDirectory: "/a",
                                                    wallpaperPath: { $0 == "bundled-dune" ? "/w/dune.png" : nil },
                                                    rotationPaths: { ["/never"] })
        XCTAssertEqual(snapshot.state, .active)
        XCTAssertEqual(snapshot.sceneID, saver.id)
        XCTAssertEqual(snapshot.scene, saver.scene)
        XCTAssertEqual(snapshot.wallpaperPaths, ["bundled-dune": "/w/dune.png"])
        XCTAssertTrue(snapshot.rotationPaths.isEmpty)
    }
}

// MARK: - Deployment packaging (Studio › Package)

final class SceneDeploymentTests: XCTestCase {
    private let id = "9BF01BF4-AFC4-4567-AF74-281FB1FABF61"

    func testDeployedBundleNeverCollidesWithAUserTile() {
        let deployed = SceneBundleSpec(deployedSceneID: id, displayName: "Acme – Lobby")
        let tile = SceneBundleSpec(sceneID: id, name: "Lobby", isManaged: false)
        XCTAssertEqual(deployed.bundleName, "Acme – Lobby.saver")
        XCTAssertEqual(deployed.displayName, "Acme – Lobby")
        XCTAssertEqual(deployed.bundleIdentifier, "com.herojoneslabs.paperwalls.saver.deployed." + id.lowercased())
        XCTAssertNotEqual(deployed.bundleIdentifier, tile.bundleIdentifier)
        XCTAssertNotEqual(deployed.principalClassName, tile.principalClassName)
        XCTAssertTrue(deployed.principalClassName.hasPrefix("PaperWallsDeployed_"))
        // The user-tile manager must never adopt (or delete) a deployed bundle.
        XCTAssertNil(SceneBundleSpec.sceneID(fromBundleIdentifier: deployed.bundleIdentifier))
    }

    func testDeployedNameIsSanitized() {
        let spec = SceneBundleSpec(deployedSceneID: id, displayName: " Front / Desk ")
        XCTAssertEqual(spec.bundleName, "Front Desk.saver")
    }

    private func snapshot(wallpapers: [String: String] = [:], rotation: [String] = [],
                          assetNames: [String?] = []) -> ScreenSaverSnapshot {
        var scene = ScreenSaverScene()
        scene.layers = assetNames.map { name in
            var icon = IconLayer()
            icon.imageAssetName = name
            return SceneLayer(content: .icon(icon), size: 0.1)
        }
        var snapshot = ScreenSaverSnapshot(state: .active, sceneID: id, sceneName: "Lobby", scene: scene)
        snapshot.wallpaperPaths = wallpapers
        snapshot.rotationPaths = rotation
        snapshot.assetsDirectory = "/Users/me/Library/Application Support/PaperWalls/Studio/Assets"
        return snapshot
    }

    func testPortableSnapshotCarriesEveryImageWithRelativePaths() {
        let source = snapshot(wallpapers: ["bundled-prism": "/Apps/Prism.HEIC"],
                              rotation: ["/a/one.jpg", "/b/two.png"],
                              assetNames: ["logo.png", nil, "logo.png", "badge.pdf"])
        let (portable, media) = SceneDeployment.portable(source)

        XCTAssertEqual(portable.wallpaperPaths, ["bundled-prism": "Media/wallpaper-1.heic"])
        XCTAssertEqual(portable.rotationPaths, ["Media/rotation-1.jpg", "Media/rotation-2.png"])
        XCTAssertEqual(portable.assetsDirectory, "Media/Assets")
        XCTAssertEqual(media, [
            .init(source: "/Apps/Prism.HEIC", destination: "Media/wallpaper-1.heic"),
            .init(source: "/a/one.jpg", destination: "Media/rotation-1.jpg"),
            .init(source: "/b/two.png", destination: "Media/rotation-2.png"),
            .init(source: source.assetsDirectory + "/badge.pdf", destination: "Media/Assets/badge.pdf"),
            .init(source: source.assetsDirectory + "/logo.png", destination: "Media/Assets/logo.png"),
        ])
        XCTAssertEqual(portable.scene, source.scene)
    }

    func testPortableSnapshotWithoutImagesCarriesNothing() {
        let (portable, media) = SceneDeployment.portable(snapshot())
        XCTAssertTrue(media.isEmpty)
        XCTAssertEqual(portable.assetsDirectory, "")
    }

    func testUnsafeAssetNamesAreNotCopied() {
        let (_, media) = SceneDeployment.portable(snapshot(assetNames: ["../../etc/passwd", ".hidden"]))
        XCTAssertTrue(media.isEmpty)
    }

    func testBundleRelativePathsResolveAgainstResources() {
        let (portable, _) = SceneDeployment.portable(
            snapshot(wallpapers: ["w": "/x/w.jpg"], rotation: ["/x/r.jpg"], assetNames: ["logo.png"]))
        let resources = URL(fileURLWithPath: "/Library/Screen Savers/Acme.saver/Contents/Resources")
        let resolved = portable.resolvingBundlePaths(in: resources)
        XCTAssertEqual(resolved.wallpaperPaths["w"], resources.path + "/Media/wallpaper-1.jpg")
        XCTAssertEqual(resolved.rotationPaths, [resources.path + "/Media/rotation-1.jpg"])
        XCTAssertEqual(resolved.assetURL(named: "logo.png")?.path, resources.path + "/Media/Assets/logo.png")
    }

    func testAbsolutePathsAreLeftAlone() {
        let source = snapshot(wallpapers: ["w": "/x/w.jpg"])
        let resolved = source.resolvingBundlePaths(in: URL(fileURLWithPath: "/tmp/R"))
        XCTAssertEqual(resolved.wallpaperPaths, source.wallpaperPaths)
        XCTAssertEqual(resolved.assetsDirectory, source.assetsDirectory)
    }

    func testPackageNaming() {
        let spec = DeploymentPackageSpec(name: "Acme Lobby Savers!", version: "1.2")
        XCTAssertEqual(spec.identifier, "com.herojoneslabs.paperwalls.savers.acme-lobby-savers")
        XCTAssertEqual(spec.pkgFilename, "Acme Lobby Savers!-1.2.pkg")
        XCTAssertTrue(spec.isValid)
        XCTAssertEqual(DeploymentPackageSpec.slug("Café — Écrans"), "caf-crans")
        XCTAssertEqual(DeploymentPackageSpec.slug("!!!"), "package")
    }

    func testVersionValidation() {
        for good in ["1", "1.0", "2026.10.4", "1.2.3.4"] {
            XCTAssertTrue(DeploymentPackageSpec.isValidVersion(good), good)
        }
        for bad in ["", "1.", ".1", "1..2", "v1", "1.2.3.4.5", "1.0b"] {
            XCTAssertFalse(DeploymentPackageSpec.isValidVersion(bad), bad)
        }
        XCTAssertFalse(DeploymentPackageSpec(name: " ", version: "1").isValid)
    }

    func testProfileSelectsTheDeployedBundle() {
        let bundle = SceneBundleSpec(deployedSceneID: id, displayName: "Acme – Lobby")
        let profile = DeploymentProfile.make(bundle: bundle, packageIdentifier: "com.example.savers",
                                             organization: "Acme")
        let payload = try? XCTUnwrap((profile["PayloadContent"] as? [[String: Any]])?.first)
        XCTAssertEqual(payload?["moduleName"] as? String, "Acme – Lobby")
        XCTAssertEqual(payload?["modulePath"] as? String, "/Library/Screen Savers/Acme – Lobby.saver")
        XCTAssertEqual(profile["PayloadOrganization"] as? String, "Acme")
        XCTAssertNoThrow(try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0))
    }
}
