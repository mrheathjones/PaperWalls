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
