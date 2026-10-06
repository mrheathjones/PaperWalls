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

    func testEnforcementProfileForcesTheDeployedSaver() throws {
        let bundle = SceneBundleSpec(deployedSceneID: id, displayName: "Acme – Lobby")
        let profile = DeploymentEnforcement.profile(bundle: bundle, packageIdentifier: "com.example.savers",
                                                    organization: "Acme")
        let payload = try XCTUnwrap((profile["PayloadContent"] as? [[String: Any]])?.first)
        XCTAssertEqual(payload["PayloadType"] as? String, "com.apple.ManagedClient.preferences")
        let domain = try XCTUnwrap((payload["PayloadContent"] as? [String: Any])?["com.herojoneslabs.paperwalls"] as? [String: Any])
        let settings = try XCTUnwrap(((domain["Forced"] as? [[String: Any]])?.first)?["mcx_preference_settings"] as? [String: Any])
        XCTAssertEqual(settings["enforcedScreenSaverPath"] as? String, "/Library/Screen Savers/Acme – Lobby.saver")
        XCTAssertEqual(profile["PayloadOrganization"] as? String, "Acme")
        XCTAssertNoThrow(try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0))

        let json = DeploymentEnforcement.managedJSON(bundle: bundle)
        let parsed = try XCTUnwrap(LocalManagedConfig.parse(data: Data(json.utf8)))
        XCTAssertEqual(parsed.forced["enforcedScreenSaverPath"] as? String, "/Library/Screen Savers/Acme – Lobby.saver")
    }

    func testLockProfileForcesOnlyModuleName() throws {
        let bundle = SceneBundleSpec(deployedSceneID: id, displayName: "Mountain at Dusk")
        XCTAssertEqual(DeploymentEnforcement.moduleName(for: bundle), "Mountain at Dusk")
        let profile = DeploymentEnforcement.lockProfile(bundle: bundle, packageIdentifier: "com.example.savers",
                                                        organization: "")
        let payload = try XCTUnwrap((profile["PayloadContent"] as? [[String: Any]])?.first)
        XCTAssertEqual(payload["PayloadType"] as? String, "com.apple.screensaver")
        XCTAssertEqual(payload["moduleName"] as? String, "Mountain at Dusk")
        XCTAssertNil(payload["modulePath"])
        XCTAssertNil(payload["idleTime"], "idle time is left to the admin's own profile")
        XCTAssertEqual(profile["PayloadScope"] as? String, "System")
        XCTAssertEqual(profile["PayloadOrganization"] as? String, "YourOrg")
        XCTAssertNoThrow(try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0))
    }

    func testEnforcementProfileCanCarryTheClockPolicy() throws {
        let bundle = SceneBundleSpec(deployedSceneID: id, displayName: "Acme – Lobby")
        let plain = DeploymentEnforcement.profile(bundle: bundle, packageIdentifier: "com.example.savers", organization: "")
        let withClock = DeploymentEnforcement.profile(bundle: bundle, packageIdentifier: "com.example.savers",
                                                      organization: "", hideSystemClock: true)
        func settings(_ profile: [String: Any]) throws -> [String: Any] {
            let payload = try XCTUnwrap((profile["PayloadContent"] as? [[String: Any]])?.first)
            let domain = try XCTUnwrap((payload["PayloadContent"] as? [String: Any])?["com.herojoneslabs.paperwalls"] as? [String: Any])
            return try XCTUnwrap(((domain["Forced"] as? [[String: Any]])?.first)?["mcx_preference_settings"] as? [String: Any])
        }
        XCTAssertNil(try settings(plain)["hideSystemSaverClock"])
        XCTAssertEqual(try settings(withClock)["hideSystemSaverClock"] as? String, "whenSceneHasClock")
        XCTAssertEqual(try settings(withClock)["enforcedScreenSaverPath"] as? String, "/Library/Screen Savers/Acme – Lobby.saver")

        let json = DeploymentEnforcement.managedJSON(bundle: bundle, hideSystemClock: true)
        let parsed = try XCTUnwrap(LocalManagedConfig.parse(data: Data(json.utf8)))
        XCTAssertEqual(parsed.forced["hideSystemSaverClock"] as? String, "whenSceneHasClock")
        XCTAssertEqual(parsed.forced["enforcedScreenSaverPath"] as? String, "/Library/Screen Savers/Acme – Lobby.saver")
        XCTAssertNil(LocalManagedConfig.parse(data: Data(DeploymentEnforcement.managedJSON(bundle: bundle).utf8))?
            .forced["hideSystemSaverClock"])
    }

    func testStandaloneClockPolicyProfileAndJSON() throws {
        let profile = DeploymentEnforcement.clockPolicyProfile(packageIdentifier: "com.example.savers", organization: "Acme")
        let payload = try XCTUnwrap((profile["PayloadContent"] as? [[String: Any]])?.first)
        XCTAssertEqual(payload["PayloadType"] as? String, "com.apple.ManagedClient.preferences")
        XCTAssertEqual(payload["PayloadIdentifier"] as? String, "com.example.savers.clock.mcx")
        let domain = try XCTUnwrap((payload["PayloadContent"] as? [String: Any])?["com.herojoneslabs.paperwalls"] as? [String: Any])
        let settings = try XCTUnwrap(((domain["Forced"] as? [[String: Any]])?.first)?["mcx_preference_settings"] as? [String: Any])
        XCTAssertEqual(settings as? [String: String], ["hideSystemSaverClock": "whenSceneHasClock"])
        XCTAssertEqual(profile["PayloadIdentifier"] as? String, "com.example.savers.clock")
        XCTAssertEqual(profile["PayloadScope"] as? String, "System")
        XCTAssertNoThrow(try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0))

        let parsed = try XCTUnwrap(LocalManagedConfig.parse(data: Data(DeploymentEnforcement.clockPolicyManagedJSON().utf8)))
        XCTAssertEqual(parsed.forced as? [String: String], ["hideSystemSaverClock": "whenSceneHasClock"])

        // Leaving the lock screen alone is an explicit opt-out (the key defaults to true).
        let saverOnly = try XCTUnwrap(LocalManagedConfig.parse(
            data: Data(DeploymentEnforcement.clockPolicyManagedJSON(includeLockScreen: false).utf8)))
        XCTAssertEqual(saverOnly.forced["hideSystemSaverClock"] as? String, "whenSceneHasClock")
        XCTAssertEqual(saverOnly.forced["hideSystemSaverClockOnLockScreen"] as? Bool, false)
        XCTAssertEqual(DeploymentEnforcement.clockPolicySettings(includeLockScreen: true).count, 1)
    }

    func testHideClockProfileForcesOnlyTheClockKeys() throws {
        let profile = DeploymentEnforcement.hideClockProfile(packageIdentifier: "com.example.savers", organization: "")
        let payloads = try XCTUnwrap(profile["PayloadContent"] as? [[String: Any]])
        XCTAssertEqual(payloads.count, 2, "screen saver half + lock screen half")
        let payload = payloads[0]
        XCTAssertEqual(payload["PayloadType"] as? String, "com.apple.screensaver")
        XCTAssertEqual(payload["showClock"] as? Bool, false)
        XCTAssertNil(payload["moduleName"], "selection and locking stay in their own profiles")
        XCTAssertNil(payload["idleTime"])
        XCTAssertEqual(payload["PayloadIdentifier"] as? String, "com.example.savers.hideclock.screensaver")
        let lockScreen = payloads[1]
        XCTAssertEqual(lockScreen["PayloadType"] as? String, "com.apple.loginwindow")
        XCTAssertEqual(lockScreen["UsesLargeDateTime"] as? Bool, false)
        XCTAssertEqual(lockScreen["PayloadIdentifier"] as? String, "com.example.savers.hideclock.loginwindow")
        XCTAssertNil(lockScreen["LoginwindowText"])

        let saverOnly = DeploymentEnforcement.hideClockProfile(packageIdentifier: "com.example.savers", organization: "",
                                                               includeLockScreen: false)
        XCTAssertEqual((saverOnly["PayloadContent"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(profile["PayloadScope"] as? String, "System")
        XCTAssertEqual(profile["PayloadOrganization"] as? String, "YourOrg")
        XCTAssertNoThrow(try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0))
    }

    func testIdentityListParsing() {
        let output = """
          1) 0123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Example Org (ABCDE12345)"
          2) 89ABCDEF0123456789ABCDEF0123456789ABCDEF "Developer ID Installer: Example Org (ABCDE12345)"
          3) 0123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Example Org (ABCDE12345)"
             3 valid identities found
        """
        XCTAssertEqual(SceneDeployment.identityNames(fromFindIdentityOutput: output), [
            "Developer ID Application: Example Org (ABCDE12345)",
            "Developer ID Installer: Example Org (ABCDE12345)",
        ])
    }
}

// MARK: - Screen saver selection (macOS 14+ wallpaper store)

final class ScreenSaverSelectionTests: XCTestCase {
    private let saver = "/Library/Screen Savers/Acme – Lobby.saver"

    private func bplist(_ object: Any) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
    }

    private func idle(provider: String, configuration: [String: Any]) -> [String: Any] {
        ["Content": ["Choices": [["Provider": provider, "Files": [Any](), "Configuration": bplist(configuration)]],
                     "EncodedOptionValues": bplist(["values": [String: Any]()]),
                     "Shuffle": "$null"],
         "LastSet": Date(timeIntervalSince1970: 0),
         "LastUse": Date(timeIntervalSince1970: 1)]
    }

    private func aerial() -> [String: Any] {
        idle(provider: "com.apple.wallpaper.choice.aerials", configuration: ["assetID": "17647EAB"])
    }

    private func saverIdle(_ path: String) -> [String: Any] {
        idle(provider: ScreenSaverSelection.screenSaverProvider,
             configuration: ["module": ["relative": ScreenSaverSelection.moduleURLString(forSaverAt: path)]])
    }

    /// Shaped like a real store: system default, displays, Spaces with a
    /// default and per-display entries, and desktop entries alongside.
    private func store(systemDefault: [String: Any]? = nil) -> [String: Any] {
        let desktop: [String: Any] = ["Content": ["Choices": [["Provider": "com.apple.wallpaper.choice.image"]]]]
        return [
            "AllSpacesAndDisplays": ["Type": "individual"],
            "SystemDefault": ["Type": "individual", "Desktop": desktop,
                              "Idle": systemDefault ?? saverIdle("/System/Library/ExtensionKit/Extensions/Computer Name.appex")],
            "Displays": ["D1": ["Type": "individual", "Desktop": desktop, "Idle": aerial()],
                         "D2": ["Type": "individual", "Idle": aerial()]],
            "Spaces": ["S1": ["Default": ["Type": "individual", "Idle": aerial()],
                              "Displays": ["D1": ["Type": "individual", "Idle": aerial()]]]],
        ]
    }

    func testModuleURLMatchesWhatSystemSettingsWrites() {
        XCTAssertEqual(ScreenSaverSelection.moduleURLString(forSaverAt: "/Library/Screen Savers/PaperWalls.saver"),
                       "file:///Library/Screen%20Savers/PaperWalls.saver")
        XCTAssertEqual(ScreenSaverSelection.saverPath(fromModuleURLString: "file:///Library/Screen%20Savers/Acme%20%E2%80%93%20Lobby.saver"),
                       saver)
        XCTAssertNil(ScreenSaverSelection.saverPath(fromModuleURLString: "https://example.com/x.saver"))
    }

    func testReadsEveryIdleEntry() throws {
        let entries = try ScreenSaverSelection.idleEntries(in: store())
        XCTAssertEqual(entries.map(\.location),
                       ["Displays/D1", "Displays/D2", "Spaces/S1/Default", "Spaces/S1/Displays/D1", "SystemDefault"])
        XCTAssertEqual(entries.last?.saverPath, "/System/Library/ExtensionKit/Extensions/Computer Name.appex")
        XCTAssertEqual(entries.first?.provider, "com.apple.wallpaper.choice.aerials")
        XCTAssertNil(entries.first?.saverPath)
    }

    func testEnforcingRewritesEveryIdleEntryAndNothingElse() throws {
        let original = store()
        let now = Date(timeIntervalSince1970: 1_000)
        let (updated, changed) = try ScreenSaverSelection.enforcing(saver, in: original, now: now)
        XCTAssertEqual(changed, 5)
        XCTAssertTrue(try ScreenSaverSelection.isEnforced(saver, in: updated))
        XCTAssertFalse(try ScreenSaverSelection.isEnforced(saver, in: original))

        let system = try XCTUnwrap(updated["SystemDefault"] as? [String: Any])
        let idle = try XCTUnwrap(system["Idle"] as? [String: Any])
        XCTAssertEqual(idle["LastSet"] as? Date, now)
        XCTAssertEqual(idle["LastUse"] as? Date, Date(timeIntervalSince1970: 1), "LastUse is kept")
        // Desktop entries and other keys are untouched.
        XCTAssertEqual(NSDictionary(dictionary: system["Desktop"] as? [String: Any] ?? [:]),
                       NSDictionary(dictionary: (original["SystemDefault"] as? [String: Any])?["Desktop"] as? [String: Any] ?? [:]))
        XCTAssertEqual(updated["AllSpacesAndDisplays"] as? [String: String], ["Type": "individual"])
    }

    func testWrittenContentMatchesSystemSettingsShape() throws {
        let content = try ScreenSaverSelection.selectionContent(for: saver)
        let choice = try XCTUnwrap((content["Choices"] as? [[String: Any]])?.first)
        XCTAssertEqual(choice["Provider"] as? String, "com.apple.wallpaper.choice.screen-saver")
        XCTAssertEqual((choice["Files"] as? [Any])?.count, 0)
        let configuration = try PropertyListSerialization.propertyList(
            from: try XCTUnwrap(choice["Configuration"] as? Data), format: nil) as? [String: Any]
        XCTAssertEqual((configuration?["module"] as? [String: String])?["relative"],
                       "file:///Library/Screen%20Savers/Acme%20%E2%80%93%20Lobby.saver")
        let options = try PropertyListSerialization.propertyList(
            from: try XCTUnwrap(content["EncodedOptionValues"] as? Data), format: nil) as? [String: Any]
        XCTAssertEqual((options?["values"] as? [String: Any])?.count, 0)
        XCTAssertEqual(content["Shuffle"] as? String, "$null")
    }

    func testAlreadyEnforcedEntriesAreLeftAlone() throws {
        let (once, _) = try ScreenSaverSelection.enforcing(saver, in: store())
        let (twice, changed) = try ScreenSaverSelection.enforcing(saver, in: once)
        XCTAssertEqual(changed, 0)
        XCTAssertEqual(NSDictionary(dictionary: twice), NSDictionary(dictionary: once))

        let (_, partly) = try ScreenSaverSelection.enforcing(saver, in: store(systemDefault: saverIdle(saver)))
        XCTAssertEqual(partly, 4)
    }

    func testUnrecognizedLayoutChangesNothing() {
        var broken = store()
        broken["Displays"] = ["D1": ["Idle": ["Content": ["NoChoices": true]]]]
        XCTAssertThrowsError(try ScreenSaverSelection.enforcing(saver, in: broken)) { error in
            guard case ScreenSaverSelection.SelectionError.unexpectedFormat = error else {
                return XCTFail("expected unexpectedFormat, got \(error)")
            }
        }
        var notADictionary = store()
        notADictionary["SystemDefault"] = ["Idle": "x"]
        XCTAssertThrowsError(try ScreenSaverSelection.enforcing(saver, in: notADictionary))
    }

    func testEnforceOnAFileBacksUpWritesAndVerifies() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Index.plist")
        let backup = folder.appendingPathComponent("backup.plist")
        try bplist(store()).write(to: url)

        XCTAssertEqual(try ScreenSaverSelection.enforce(saver, storeURL: url, backupURL: backup, restartAgent: false), .enforced(changed: 5))
        XCTAssertFalse(try ScreenSaverSelection.isEnforced(saver, in: ScreenSaverSelection.readStore(at: backup)),
                       "the backup holds the store as it was")
        XCTAssertTrue(try ScreenSaverSelection.isEnforced(saver, in: ScreenSaverSelection.readStore(at: url)))
        XCTAssertEqual(try ScreenSaverSelection.enforce(saver, storeURL: url, backupURL: backup, restartAgent: false), .alreadyEnforced)
        var format = PropertyListSerialization.PropertyListFormat.xml
        _ = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: &format)
        XCTAssertEqual(format, .binary)
    }
}

final class SystemSaverClockTests: XCTestCase {
    /// An in-memory preference layer: macOS's showClock + PaperWalls' note.
    private final class FakePrefs {
        var showClock: Bool?
        var forced = false
        var restore: String?
        var writes: [String] = []

        var store: SystemSaverClock.Store {
            SystemSaverClock.Store(
                showClock: { self.showClock },
                isForced: { self.forced },
                setShowClock: { self.showClock = $0; self.writes.append("showClock=\(SystemSaverClock.restoreToken(for: $0))") },
                restoreValue: { self.restore },
                setRestoreValue: { self.restore = $0; self.writes.append("restore=\($0 ?? "nil")") })
        }
    }

    private func scene(withClock: Bool) -> ScreenSaverScene {
        ScreenSaverScene(layers: withClock ? [SceneLayer.icon(), SceneLayer.clock()] : [SceneLayer.icon()])
    }

    private func snapshot(_ state: ScreenSaverSnapshot.State, scene: ScreenSaverScene? = nil) -> ScreenSaverSnapshot {
        ScreenSaverSnapshot(state: state, sceneID: nil, sceneName: nil, scene: scene)
    }

    func testSceneKnowsWhetherItDrawsAClock() {
        XCTAssertTrue(scene(withClock: true).hasClock)
        XCTAssertFalse(scene(withClock: false).hasClock)
        XCTAssertFalse(ScreenSaverScene().hasClock)
    }

    func testDecision() {
        XCTAssertFalse(SystemSaverClock.shouldHide(policy: .never, sceneHasClock: true))
        XCTAssertTrue(SystemSaverClock.shouldHide(policy: .whenSceneHasClock, sceneHasClock: true))
        XCTAssertFalse(SystemSaverClock.shouldHide(policy: .whenSceneHasClock, sceneHasClock: false))
        XCTAssertTrue(SystemSaverClock.shouldHide(policy: .always, sceneHasClock: false))
    }

    func testHidesThenRestoresWhatItReplaced() {
        let prefs = FakePrefs()   // unset: macOS shows the clock
        XCTAssertEqual(SystemSaverClock.apply(policy: .whenSceneHasClock, sceneHasClock: true, store: prefs.store), .hidden)
        XCTAssertEqual(prefs.showClock, false)
        XCTAssertEqual(prefs.restore, "unset")
        XCTAssertEqual(SystemSaverClock.apply(policy: .whenSceneHasClock, sceneHasClock: true, store: prefs.store), .alreadyHidden)
        XCTAssertEqual(prefs.writes.count, 2, "a second run writes nothing")

        // The clock scene goes away: back to unset, note cleared.
        XCTAssertEqual(SystemSaverClock.apply(policy: .whenSceneHasClock, sceneHasClock: false, store: prefs.store), .restored(nil))
        XCTAssertNil(prefs.showClock)
        XCTAssertNil(prefs.restore)
        XCTAssertEqual(SystemSaverClock.apply(policy: .whenSceneHasClock, sceneHasClock: false, store: prefs.store), .leftAlone)
    }

    func testRestoresAnExplicitTrue() {
        let prefs = FakePrefs()
        prefs.showClock = true
        XCTAssertEqual(SystemSaverClock.apply(policy: .always, sceneHasClock: false, store: prefs.store), .hidden)
        XCTAssertEqual(prefs.restore, "true")
        XCTAssertEqual(SystemSaverClock.apply(policy: .never, sceneHasClock: false, store: prefs.store), .restored(true))
        XCTAssertEqual(prefs.showClock, true)
        XCTAssertNil(prefs.restore)
    }

    func testNeverTouchesAValueTheUserTurnedOffThemselves() {
        let prefs = FakePrefs()
        prefs.showClock = false
        XCTAssertEqual(SystemSaverClock.apply(policy: .whenSceneHasClock, sceneHasClock: true, store: prefs.store), .alreadyHidden)
        XCTAssertNil(prefs.restore, "nothing was replaced, so nothing to restore")
        XCTAssertEqual(SystemSaverClock.apply(policy: .whenSceneHasClock, sceneHasClock: false, store: prefs.store), .leftAlone)
        XCTAssertEqual(prefs.showClock, false)
        XCTAssertTrue(prefs.writes.isEmpty)
    }

    func testKeepsTheUsersChoiceIfTheyTurnedItBackOn() {
        let prefs = FakePrefs()
        XCTAssertEqual(SystemSaverClock.apply(policy: .always, sceneHasClock: false, store: prefs.store), .hidden)
        prefs.showClock = true   // the user re-enabled it in System Settings
        XCTAssertEqual(SystemSaverClock.apply(policy: .never, sceneHasClock: false, store: prefs.store), .leftAlone)
        XCTAssertEqual(prefs.showClock, true)
        XCTAssertNil(prefs.restore, "the note is cleared either way")
    }

    func testAProfileOwnsAForcedKey() {
        let prefs = FakePrefs()
        prefs.forced = true
        XCTAssertEqual(SystemSaverClock.apply(policy: .always, sceneHasClock: true, store: prefs.store), .managedByProfile)
        XCTAssertTrue(prefs.writes.isEmpty)
    }

    func testNeedsAdminWhenItCannotWriteTheLayer() {
        let prefs = FakePrefs()
        var store = prefs.store
        store.canWrite = { false }
        XCTAssertEqual(SystemSaverClock.apply(policy: .always, sceneHasClock: false, store: store), .needsAdmin)
        XCTAssertTrue(prefs.writes.isEmpty, "decides only; never pretends to write")
        XCTAssertTrue(SystemSaverClock.Outcome.needsAdmin.isPending)

        // Hidden by PaperWalls (as root, earlier); now the policy is off but
        // this process can't restore it either.
        prefs.showClock = false
        prefs.restore = "true"
        XCTAssertEqual(SystemSaverClock.apply(policy: .never, sceneHasClock: false, store: store), .needsAdmin)
        XCTAssertEqual(prefs.restore, "true", "the note survives until someone who can write runs")
        // …unless the user already turned it back on: nothing owed.
        prefs.showClock = true
        XCTAssertEqual(SystemSaverClock.apply(policy: .never, sceneHasClock: false, store: store), .leftAlone)
        XCTAssertTrue(prefs.writes.isEmpty)
    }

    func testLockScreenHalfFollowsTheOptOut() {
        XCTAssertEqual(SystemSaverClock.lockScreenPolicy(.always, coversLockScreen: true), .always)
        XCTAssertEqual(SystemSaverClock.lockScreenPolicy(.always, coversLockScreen: false), .never,
                       "opting the lock screen out also restores it")
        XCTAssertEqual(SystemSaverClock.lockScreenPolicy(.never, coversLockScreen: true), .never)
    }

    func testRestoreTokens() {
        for value in [true, false, nil] as [Bool?] {
            XCTAssertEqual(SystemSaverClock.restoredValue(from: SystemSaverClock.restoreToken(for: value)), value)
        }
        XCTAssertNil(SystemSaverClock.restoredValue(from: "garbage"))
    }

    func testSnapshotMirrorsWhatTheSaverShows() {
        XCTAssertTrue(SystemSaverClock.snapshotHasClock(snapshot(.active, scene: scene(withClock: true))))
        XCTAssertFalse(SystemSaverClock.snapshotHasClock(snapshot(.active, scene: scene(withClock: false))))
        XCTAssertTrue(SystemSaverClock.snapshotHasClock(snapshot(.active)), "no scene → the saver's Minimal Clock fallback")
        XCTAssertTrue(SystemSaverClock.snapshotHasClock(snapshot(.noneSelected)), "built-in Minimal Clock")
        XCTAssertFalse(SystemSaverClock.snapshotHasClock(snapshot(.disabled)))
        XCTAssertFalse(SystemSaverClock.snapshotHasClock(snapshot(.hardLock)))
    }

    func testSaverHasClockResolvesBundledThenPublishedScene() {
        let deployed = "/Library/Screen Savers/Acme – Lobby.saver"
        let main = "/Library/Screen Savers/PaperWalls.saver"
        let other = "/System/Library/Screen Savers/Hello.saver"
        let source = SystemSaverClock.SceneSource(
            bundledSnapshot: { path in path == deployed ? self.snapshot(.active, scene: self.scene(withClock: true)) : nil },
            publishedSnapshot: { self.snapshot(.active, scene: self.scene(withClock: false)) },
            isPaperWallsSaver: { path in path == main || path == deployed })
        XCTAssertTrue(SystemSaverClock.saverHasClock(at: deployed, source: source), "the bundle's own scene")
        XCTAssertFalse(SystemSaverClock.saverHasClock(at: main, source: source), "the published scene has no clock")
        XCTAssertFalse(SystemSaverClock.saverHasClock(at: other, source: source), "not a PaperWalls saver")
        XCTAssertFalse(SystemSaverClock.saverHasClock(at: nil, source: source))

        let unpublished = SystemSaverClock.SceneSource(bundledSnapshot: { _ in nil }, publishedSnapshot: { nil },
                                                       isPaperWallsSaver: { _ in true })
        XCTAssertTrue(SystemSaverClock.saverHasClock(at: main, source: unpublished), "no snapshot yet → Minimal Clock")
    }

    func testEffectiveSaverPrefersEnforcedThenSystemDefault() throws {
        func idle(_ path: String) -> [String: Any] {
            let configuration: [String: Any] = ["module": ["relative": ScreenSaverSelection.moduleURLString(forSaverAt: path)]]
            return ["Content": ["Choices": [["Provider": ScreenSaverSelection.screenSaverProvider, "Files": [Any](),
                                             "Configuration": try! PropertyListSerialization.data(fromPropertyList: configuration, format: .binary, options: 0)]],
                                "EncodedOptionValues": Data(), "Shuffle": "$null"]]
        }
        let aerial: [String: Any] = ["Content": ["Choices": [["Provider": "com.apple.wallpaper.choice.aerials"]]]]
        let store: [String: Any] = [
            "SystemDefault": ["Idle": idle("/Library/Screen Savers/A.saver")],
            "Displays": ["D1": ["Idle": idle("/Library/Screen Savers/B.saver")], "D2": ["Idle": idle("/Library/Screen Savers/B.saver")]],
        ]
        XCTAssertEqual(SystemSaverClock.effectiveSaverPath(enforced: "/Library/Screen Savers/E.saver", store: store),
                       "/Library/Screen Savers/E.saver")
        XCTAssertEqual(SystemSaverClock.effectiveSaverPath(enforced: "  ", store: store), "/Library/Screen Savers/A.saver",
                       "the system default is what System Settings updates on every click")
        XCTAssertNil(SystemSaverClock.effectiveSaverPath(enforced: nil, store: ["SystemDefault": ["Idle": aerial]]),
                     "an aerial system default isn't a saver")
        XCTAssertEqual(SystemSaverClock.effectiveSaverPath(enforced: nil, store: ["Displays": store["Displays"]!]),
                       "/Library/Screen Savers/B.saver", "no system default → the most common choice")
        XCTAssertNil(SystemSaverClock.effectiveSaverPath(enforced: nil, store: nil))
    }
}
