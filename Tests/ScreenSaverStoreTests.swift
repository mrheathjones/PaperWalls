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
