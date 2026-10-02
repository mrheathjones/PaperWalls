import XCTest

// MARK: - Scene store (spec §10)

final class ScreenSaverSceneStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperWallsSceneStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeSaver(name: String = "Clock", modifiedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> StoredScreenSaver {
        StoredScreenSaver(name: name,
                          createdAt: Date(timeIntervalSince1970: 1_600_000_000),
                          modifiedAt: modifiedAt,
                          scene: ScreenSaverPreset.bouncingClock.scene)
    }

    func testSaveAndLoadRoundTrips() throws {
        let saver = makeSaver()
        try ScreenSaverSceneStore.save(saver, in: directory)
        XCTAssertEqual(ScreenSaverSceneStore.loadAll(in: directory), [saver])
    }

    func testMissingDirectoryLoadsEmpty() {
        XCTAssertTrue(ScreenSaverSceneStore.loadAll(in: directory).isEmpty)
    }

    func testLoadSortsNewestFirst() throws {
        let older = makeSaver(name: "Older", modifiedAt: Date(timeIntervalSince1970: 1_000))
        let newer = makeSaver(name: "Newer", modifiedAt: Date(timeIntervalSince1970: 2_000))
        try ScreenSaverSceneStore.save(older, in: directory)
        try ScreenSaverSceneStore.save(newer, in: directory)
        XCTAssertEqual(ScreenSaverSceneStore.loadAll(in: directory).map(\.name), ["Newer", "Older"])
    }

    func testSavingAgainReplacesTheEntry() throws {
        var saver = makeSaver()
        try ScreenSaverSceneStore.save(saver, in: directory)
        saver.name = "Renamed"
        try ScreenSaverSceneStore.save(saver, in: directory)
        XCTAssertEqual(ScreenSaverSceneStore.loadAll(in: directory).map(\.name), ["Renamed"])
    }

    func testCorruptFileIsSkippedNotFatal() throws {
        let good = makeSaver()
        try ScreenSaverSceneStore.save(good, in: directory)
        try Data("{ this is not json".utf8)
            .write(to: ScreenSaverSceneStore.fileURL(forID: UUID().uuidString, in: directory))
        try Data(#"{"id": 5}"#.utf8)
            .write(to: ScreenSaverSceneStore.fileURL(forID: UUID().uuidString, in: directory))
        XCTAssertEqual(ScreenSaverSceneStore.loadAll(in: directory), [good])
    }

    func testFileWhoseNameDoesNotMatchItsIDIsSkipped() throws {
        let saver = makeSaver()
        try ScreenSaverSceneStore.save(saver, in: directory)
        // A Finder-duplicated file would otherwise shadow the original.
        try FileManager.default.copyItem(
            at: ScreenSaverSceneStore.fileURL(forID: saver.id, in: directory),
            to: ScreenSaverSceneStore.fileURL(forID: UUID().uuidString, in: directory))
        XCTAssertEqual(ScreenSaverSceneStore.loadAll(in: directory), [saver])
    }

    func testNewerSchemaIsSkipped() throws {
        var saver = makeSaver()
        try ScreenSaverSceneStore.save(saver, in: directory)
        let url = ScreenSaverSceneStore.fileURL(forID: saver.id, in: directory)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["schemaVersion"] = ScreenSaverScene.currentSchemaVersion + 1
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertTrue(ScreenSaverSceneStore.loadAll(in: directory).isEmpty)

        // …and saving always stamps the current schema.
        saver.schemaVersion = 0
        try ScreenSaverSceneStore.save(saver, in: directory)
        XCTAssertEqual(ScreenSaverSceneStore.loadAll(in: directory).first?.schemaVersion,
                       ScreenSaverScene.currentSchemaVersion)
    }

    func testMigrationHookStampsCurrentVersion() {
        let migrated = ScreenSaverSceneStore.migrate(["schemaVersion": 0, "name": "x"], from: 0)
        XCTAssertEqual(migrated["schemaVersion"] as? Int, ScreenSaverScene.currentSchemaVersion)
        XCTAssertEqual(migrated["name"] as? String, "x")
    }

    func testDeleteRemovesSceneAndThumbnail() throws {
        let saver = makeSaver()
        try ScreenSaverSceneStore.save(saver, in: directory)
        let thumbnail = ScreenSaverSceneStore.thumbnailURL(forID: saver.id, in: directory)
        try FileManager.default.createDirectory(at: thumbnail.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("png".utf8).write(to: thumbnail)

        try ScreenSaverSceneStore.delete(id: saver.id, in: directory)
        XCTAssertTrue(ScreenSaverSceneStore.loadAll(in: directory).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnail.path))
    }

    func testManagedEntryIsNeverWrittenOrDeleted() {
        var managed = makeSaver()
        managed.id = ScreenSaverSceneStore.managedSceneID
        XCTAssertTrue(managed.isManaged)
        XCTAssertThrowsError(try ScreenSaverSceneStore.save(managed, in: directory))
        XCTAssertThrowsError(try ScreenSaverSceneStore.delete(id: ScreenSaverSceneStore.managedSceneID, in: directory))
        // IDs are filenames — anything that isn't a UUID is refused.
        XCTAssertThrowsError(try ScreenSaverSceneStore.delete(id: "../../escape", in: directory))
    }

    func testUniqueNameAppendsACounter() {
        XCTAssertEqual(ScreenSaverSceneStore.uniqueName("Clock", existing: []), "Clock")
        XCTAssertEqual(ScreenSaverSceneStore.uniqueName("Clock", existing: ["clock"]), "Clock 2")
        XCTAssertEqual(ScreenSaverSceneStore.uniqueName("Clock", existing: ["Clock", "Clock 2"]), "Clock 3")
        XCTAssertEqual(ScreenSaverSceneStore.uniqueName("   ", existing: []), "Untitled")
    }

    // MARK: Image assets

    func testImportAssetCopiesOnceByContent() throws {
        let source = directory.appendingPathComponent("logo.PNG")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not really a png".utf8).write(to: source)

        let name = try ScreenSaverSceneStore.importAsset(from: source, in: directory)
        XCTAssertTrue(name.hasSuffix(".png"))
        let stored = try XCTUnwrap(ScreenSaverSceneStore.assetURL(named: name, in: directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))

        // Same bytes under another filename → same asset; the original
        // can go away without breaking the scene.
        let copy = directory.appendingPathComponent("renamed.png")
        try FileManager.default.copyItem(at: source, to: copy)
        XCTAssertEqual(try ScreenSaverSceneStore.importAsset(from: copy, in: directory), name)
        try FileManager.default.removeItem(at: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))
    }

    func testImportAssetRejectsNonImages() throws {
        let source = directory.appendingPathComponent("notes.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: source)
        XCTAssertThrowsError(try ScreenSaverSceneStore.importAsset(from: source, in: directory))
    }

    func testAssetNamesCannotEscapeTheAssetsFolder() {
        XCTAssertNil(ScreenSaverSceneStore.assetURL(named: "../secret.png", in: directory))
        XCTAssertNil(ScreenSaverSceneStore.assetURL(named: "/etc/hosts", in: directory))
        XCTAssertNil(ScreenSaverSceneStore.assetURL(named: "", in: directory))
        XCTAssertNotNil(ScreenSaverSceneStore.assetURL(named: "abc123.png", in: directory))
    }

    // MARK: Managed scene

    func testManagedSceneFromJSONString() throws {
        let json = #"{"name": "Acme Lobby", "scene": {"background": {"source": {"kind": "solid", "colorHex": "112233"}}, "layers": [{"content": {"kind": "clock"}}]}}"#
        let managed = try XCTUnwrap(ScreenSaverSceneStore.managedScene(from: json, defaultName: "Default"))
        XCTAssertEqual(managed.id, ScreenSaverSceneStore.managedSceneID)
        XCTAssertTrue(managed.isManaged)
        XCTAssertEqual(managed.name, "Acme Lobby")
        XCTAssertEqual(managed.scene.background.source, .solid(colorHex: "112233"))
        XCTAssertEqual(managed.scene.layers.count, 1)
    }

    func testManagedSceneFromInlineObjectAndBareScene() throws {
        // managed.json / plist: an inline object, here a bare scene.
        let object: [String: Any] = ["layers": [["content": ["kind": "text", "segments": [["text": "Hi"]]]]]]
        let managed = try XCTUnwrap(ScreenSaverSceneStore.managedScene(from: object, defaultName: "Acme Screen Saver"))
        XCTAssertEqual(managed.name, "Acme Screen Saver")
        XCTAssertEqual(managed.scene.layers.count, 1)
    }

    func testManagedSceneRejectsGarbage() {
        XCTAssertNil(ScreenSaverSceneStore.managedScene(from: nil, defaultName: "x"))
        XCTAssertNil(ScreenSaverSceneStore.managedScene(from: "not json", defaultName: "x"))
        XCTAssertNil(ScreenSaverSceneStore.managedScene(from: 42, defaultName: "x"))
        XCTAssertNil(ScreenSaverSceneStore.managedScene(from: "[1, 2]", defaultName: "x"))
    }

    func testExportForMDMRoundTripsThroughManagedParse() throws {
        let saver = makeSaver(name: "Lobby Clock")
        let json = try XCTUnwrap(ScreenSaverSceneStore.managedSceneJSON(for: saver))
        let managed = try XCTUnwrap(ScreenSaverSceneStore.managedScene(from: json, defaultName: "x"))
        XCTAssertEqual(managed.name, "Lobby Clock")
        XCTAssertEqual(managed.scene, saver.scene)
    }
}

// MARK: - Policy (spec §10)

final class ScreenSaverPolicyTests: XCTestCase {
    private let managed = ScreenSaverSceneStore.managedSceneID

    func testActiveSceneAppliesWhenUnrestricted() {
        let policy = ScreenSaverPolicy(activeID: "a")
        XCTAssertEqual(policy.effectiveActiveID(availableIDs: ["a", "b"]), "a")
        XCTAssertTrue(policy.canSetActive("b"))
        XCTAssertTrue(policy.canCreate)
        XCTAssertNil(policy.setActiveRefusalReason("b"))
    }

    func testMissingActiveSceneYieldsNothing() {
        XCTAssertNil(ScreenSaverPolicy(activeID: "gone").effectiveActiveID(availableIDs: ["a"]))
        XCTAssertNil(ScreenSaverPolicy(activeID: nil).effectiveActiveID(availableIDs: ["a"]))
    }

    func testDisabledShowsNothingAndBlocksSetActive() {
        let policy = ScreenSaverPolicy(enabled: false, activeID: "a")
        XCTAssertNil(policy.effectiveActiveID(availableIDs: ["a"]))
        XCTAssertFalse(policy.canSetActive("a"))
        XCTAssertNotNil(policy.setActiveRefusalReason("a"))
    }

    func testHardLockShowsNothingAndDisablesEditing() {
        let policy = ScreenSaverPolicy(lockMode: .hard, activeID: "a", activeIDForced: true)
        XCTAssertNil(policy.effectiveActiveID(availableIDs: ["a", managed]))
        XCTAssertFalse(policy.canSetActive("a"))
        XCTAssertFalse(policy.canCreate)
    }

    func testSoftLockPrefersForcedThenManaged() {
        let forced = ScreenSaverPolicy(lockMode: .soft, activeID: "a", activeIDForced: true)
        XCTAssertEqual(forced.effectiveActiveID(availableIDs: ["a", managed]), "a")

        let unforced = ScreenSaverPolicy(lockMode: .soft, activeID: "a")
        XCTAssertEqual(unforced.effectiveActiveID(availableIDs: ["a", managed]), managed)
        XCTAssertFalse(unforced.canSetActive("a"))
    }

    func testSoftLockWithNoAdminChoiceKeepsCurrentScene() {
        let policy = ScreenSaverPolicy(lockMode: .soft, activeID: "a")
        XCTAssertEqual(policy.effectiveActiveID(availableIDs: ["a", "b"]), "a")
        XCTAssertFalse(policy.canSetActive("b"))
        // Editing stays available under a soft lock; only selection locks.
        XCTAssertTrue(policy.canCreate)
    }

    func testForcedActiveSceneBlocksSetActive() {
        let policy = ScreenSaverPolicy(activeID: "a", activeIDForced: true)
        XCTAssertEqual(policy.effectiveActiveID(availableIDs: ["a", "b"]), "a")
        XCTAssertFalse(policy.canSetActive("b"))
    }

    func testAllowListRestrictsActiveScene() {
        let policy = ScreenSaverPolicy(activeID: "a", allowedIDs: ["b"])
        XCTAssertNil(policy.effectiveActiveID(availableIDs: ["a", "b"]))
        XCTAssertFalse(policy.canSetActive("a"))
        XCTAssertTrue(policy.canSetActive("b"))
        // An empty list allows everything.
        XCTAssertTrue(ScreenSaverPolicy(allowedIDs: []).canSetActive("a"))
    }

    func testCreationSwitch() {
        XCTAssertFalse(ScreenSaverPolicy(allowCreation: false).canCreate)
        // Browse + Set Active still work with creation off.
        XCTAssertTrue(ScreenSaverPolicy(allowCreation: false).canSetActive("a"))
    }

    func testEnforcedRotationBehavesLikeUnlockedForScenes() {
        let policy = ScreenSaverPolicy(lockMode: .enforcedRotation, activeID: "a")
        XCTAssertEqual(policy.effectiveActiveID(availableIDs: ["a"]), "a")
        XCTAssertTrue(policy.canSetActive("a"))
    }
}

// MARK: - Studio tab hide logic (spec §10)

final class StudioTabVisibilityTests: XCTestCase {
    private func tabs(studio: Bool = true, wallpapers: Bool = true,
                      screenSaver: Bool = true, canCreate: Bool = true) -> [StudioTab] {
        StudioTab.visibleTabs(showStudio: studio, showWallpapersTab: wallpapers,
                              showScreenSaverTab: screenSaver, canCreate: canCreate)
    }

    func testBothTabsByDefault() {
        XCTAssertEqual(tabs(), [.wallpapers, .screenSaver])
    }

    func testHidingStudioHidesEverything() {
        XCTAssertTrue(tabs(studio: false).isEmpty)
    }

    func testSingleTabRemains() {
        XCTAssertEqual(tabs(wallpapers: false), [.screenSaver])
        XCTAssertEqual(tabs(screenSaver: false), [.wallpapers])
    }

    func testBothTabsHiddenHidesStudio() {
        XCTAssertTrue(tabs(wallpapers: false, screenSaver: false).isEmpty)
    }

    func testComposerTabNeedsCreation() {
        XCTAssertEqual(tabs(canCreate: false), [.wallpapers])
        XCTAssertTrue(tabs(wallpapers: false, canCreate: false).isEmpty)
    }
}

// MARK: - Composer draft (spec §10)

final class SceneDraftTests: XCTestCase {
    func testNewDraftIsCleanButSavable() {
        let draft = SceneDraft(newNamed: "Bouncing Clock",
                               scene: ScreenSaverPreset.bouncingClock.scene,
                               presetName: "Bouncing Clock")
        XCTAssertTrue(draft.isNew)
        XCTAssertFalse(draft.isDirty)
        XCTAssertTrue(draft.canSave)
        XCTAssertEqual(draft.resetLabel, "Reset to Preset")
    }

    func testEditingDraftSavesOnlyWhenChanged() {
        let stored = StoredScreenSaver(name: "Lobby", scene: ScreenSaverPreset.minimalClock.scene)
        var draft = SceneDraft(editing: stored)
        XCTAssertFalse(draft.isNew)
        XCTAssertFalse(draft.isDirty)
        XCTAssertFalse(draft.canSave)
        XCTAssertEqual(draft.resetLabel, "Revert to Saved")

        draft.scene.background.treatment.dim = 0.7
        XCTAssertTrue(draft.isDirty)
        XCTAssertTrue(draft.canSave)
    }

    func testRenameAloneIsAChange() {
        var draft = SceneDraft(editing: StoredScreenSaver(name: "Lobby", scene: ScreenSaverScene()))
        draft.name = "Front Desk"
        XCTAssertTrue(draft.isDirty)
    }

    func testBlankNameCannotBeSaved() {
        var draft = SceneDraft(newNamed: "Untitled", scene: ScreenSaverScene())
        draft.name = "   "
        XCTAssertFalse(draft.canSave)
    }

    func testResetRestoresTheBaseline() {
        let scene = ScreenSaverPreset.floatingMessage.scene
        var draft = SceneDraft(newNamed: "Message", scene: scene, presetName: "Floating Message")
        draft.name = "Changed"
        draft.scene.layers.removeAll()
        draft.reset()
        XCTAssertEqual(draft.name, "Message")
        XCTAssertEqual(draft.scene, scene)
        XCTAssertFalse(draft.isDirty)
    }

    func testTextSegmentsNormalize() {
        let segments: [SceneTextSegment] = [.text("Hi "), .text(""), .text("there "), .token(.date), .text(""), .token(.computerName), .text("!")]
        XCTAssertEqual(segments.normalized,
                       [.text("Hi there "), .token(.date), .token(.computerName), .text("!")])
        XCTAssertTrue([SceneTextSegment.text("")].normalized.isEmpty)
    }
}

// MARK: - Saver snapshot (spec §10)

final class ScreenSaverSnapshotTests: XCTestCase {
    private func saver(_ name: String, source: SceneBackgroundSource = .currentDesktop) -> StoredScreenSaver {
        StoredScreenSaver(name: name, scene: ScreenSaverScene(background: SceneBackground(source: source),
                                                             layers: [.clock()]))
    }

    private func make(policy: ScreenSaverPolicy,
                      scenes: [StoredScreenSaver],
                      wallpaperPath: @escaping (String) -> String? = { _ in nil },
                      rotationPaths: @escaping () -> [String] = { [] }) -> ScreenSaverSnapshot {
        ScreenSaverSnapshot.make(policy: policy, scenes: scenes, companyName: "Acme",
                                 assetsDirectory: "/tmp/assets",
                                 wallpaperPath: wallpaperPath, rotationPaths: rotationPaths)
    }

    func testActiveSceneIsCarriedInFull() {
        let scene = saver("Lobby")
        let snapshot = make(policy: ScreenSaverPolicy(activeID: scene.id), scenes: [scene])
        XCTAssertEqual(snapshot.state, .active)
        XCTAssertEqual(snapshot.sceneID, scene.id)
        XCTAssertEqual(snapshot.sceneName, "Lobby")
        XCTAssertEqual(snapshot.scene, scene.scene)
        XCTAssertEqual(snapshot.companyName, "Acme")
    }

    func testNothingSelectedCarriesNoScene() {
        let snapshot = make(policy: ScreenSaverPolicy(activeID: nil), scenes: [saver("Lobby")])
        XCTAssertEqual(snapshot.state, .noneSelected)
        XCTAssertNil(snapshot.scene)
    }

    func testDisabledAndHardLockCarryNoScene() {
        let scene = saver("Lobby")
        XCTAssertEqual(make(policy: ScreenSaverPolicy(enabled: false, activeID: scene.id), scenes: [scene]).state,
                       .disabled)
        let locked = make(policy: ScreenSaverPolicy(lockMode: .hard, activeID: scene.id), scenes: [scene])
        XCTAssertEqual(locked.state, .hardLock)
        XCTAssertNil(locked.scene)
    }

    func testSoftLockPublishesTheManagedScene() {
        var managed = saver("Company")
        managed.id = ScreenSaverSceneStore.managedSceneID
        let mine = saver("Mine")
        let snapshot = make(policy: ScreenSaverPolicy(lockMode: .soft, activeID: mine.id),
                            scenes: [managed, mine])
        XCTAssertEqual(snapshot.sceneID, ScreenSaverSceneStore.managedSceneID)
    }

    func testOnlyTheUsedBackgroundIsResolved() {
        let wallpaper = saver("Wall", source: .wallpaper(id: "bundled-dune"))
        var rotationAsked = false
        let snapshot = make(policy: ScreenSaverPolicy(activeID: wallpaper.id), scenes: [wallpaper],
                            wallpaperPath: { $0 == "bundled-dune" ? "/w/dune.png" : nil },
                            rotationPaths: { rotationAsked = true; return ["/x"] })
        XCTAssertEqual(snapshot.wallpaperPaths, ["bundled-dune": "/w/dune.png"])
        XCTAssertTrue(snapshot.rotationPaths.isEmpty)
        XCTAssertFalse(rotationAsked)

        let rotating = saver("Rotate", source: .rotatingPool(intervalSeconds: 60))
        let rotated = make(policy: ScreenSaverPolicy(activeID: rotating.id), scenes: [rotating],
                           rotationPaths: { ["/a.png", "/b.png"] })
        XCTAssertEqual(rotated.rotationPaths, ["/a.png", "/b.png"])
    }

    func testWriteReadRoundTripAndSkipsUnchangedContent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperWallsSnapshotTests-\(UUID().uuidString)/Studio/ActiveScreenSaver.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }

        let scene = saver("Lobby")
        var snapshot = make(policy: ScreenSaverPolicy(activeID: scene.id), scenes: [scene])
        XCTAssertNil(ScreenSaverSnapshot.read(from: url))
        XCTAssertTrue(try snapshot.write(to: url))

        let loaded = try XCTUnwrap(ScreenSaverSnapshot.read(from: url))
        XCTAssertTrue(loaded.hasSameContent(as: snapshot))
        XCTAssertEqual(loaded.scene, scene.scene)

        // Same outcome later → the file is left alone.
        snapshot.generatedAt = Date().addingTimeInterval(3_600)
        XCTAssertFalse(try snapshot.write(to: url))
        // A different outcome → rewritten.
        snapshot.state = .disabled
        snapshot.scene = nil
        XCTAssertTrue(try snapshot.write(to: url))
        XCTAssertEqual(ScreenSaverSnapshot.read(from: url)?.state, .disabled)
    }

    func testGarbageOrNewerSnapshotReadsAsNil() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperWallsSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ActiveScreenSaver.json")

        try Data("nope".utf8).write(to: url)
        XCTAssertNil(ScreenSaverSnapshot.read(from: url))

        var future = ScreenSaverSnapshot(state: .disabled)
        future.version = ScreenSaverSnapshot.currentVersion + 1
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(future).write(to: url)
        XCTAssertNil(ScreenSaverSnapshot.read(from: url))
    }

    func testAssetURLsStayInsideTheAssetsFolder() {
        let snapshot = ScreenSaverSnapshot(state: .active, assetsDirectory: "/tmp/assets")
        XCTAssertEqual(snapshot.assetURL(named: "abc.png")?.path, "/tmp/assets/abc.png")
        XCTAssertNil(snapshot.assetURL(named: "../abc.png"))
        XCTAssertNil(ScreenSaverSnapshot(state: .active).assetURL(named: "abc.png"))
    }
}
