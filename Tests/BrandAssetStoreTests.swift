import XCTest

// MARK: - Brand asset library (Studio › Assets)

final class BrandAssetStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperWallsBrandAssetTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeAsset(name: String = "Logo", kind: BrandAssetKind = .logo,
                           assetName: String = "abc123.png",
                           modifiedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> BrandAsset {
        BrandAsset(name: name, kind: kind, assetName: assetName,
                   createdAt: Date(timeIntervalSince1970: 1_600_000_000), modifiedAt: modifiedAt)
    }

    func testSaveAndLoadRoundTrips() throws {
        let asset = makeAsset()
        try BrandAssetStore.save(asset, in: directory)
        XCTAssertEqual(BrandAssetStore.loadAll(in: directory), [asset])
    }

    func testMissingDirectoryLoadsEmpty() {
        XCTAssertTrue(BrandAssetStore.loadAll(in: directory).isEmpty)
    }

    func testLoadSortsNewestFirst() throws {
        try BrandAssetStore.save(makeAsset(name: "Older", modifiedAt: Date(timeIntervalSince1970: 1_000)), in: directory)
        try BrandAssetStore.save(makeAsset(name: "Newer", modifiedAt: Date(timeIntervalSince1970: 2_000)), in: directory)
        XCTAssertEqual(BrandAssetStore.loadAll(in: directory).map(\.name), ["Newer", "Older"])
    }

    func testSavingAgainReplacesTheEntry() throws {
        var asset = makeAsset()
        try BrandAssetStore.save(asset, in: directory)
        asset.name = "Wordmark"
        asset.kind = .icon
        try BrandAssetStore.save(asset, in: directory)
        let loaded = BrandAssetStore.loadAll(in: directory)
        XCTAssertEqual(loaded.map(\.name), ["Wordmark"])
        XCTAssertEqual(loaded.first?.kind, .icon)
    }

    func testDeleteRemovesOnlyTheEntry() throws {
        let keep = makeAsset(name: "Keep")
        let drop = makeAsset(name: "Drop")
        try BrandAssetStore.save(keep, in: directory)
        try BrandAssetStore.save(drop, in: directory)
        try BrandAssetStore.delete(id: drop.id, in: directory)
        XCTAssertEqual(BrandAssetStore.loadAll(in: directory), [keep])
    }

    func testCorruptAndMisnamedFilesAreSkipped() throws {
        let good = makeAsset()
        try BrandAssetStore.save(good, in: directory)
        try Data("{ nope".utf8).write(to: BrandAssetStore.fileURL(forID: UUID().uuidString, in: directory))
        // A copy under another file name must not shadow the original.
        try FileManager.default.copyItem(at: BrandAssetStore.fileURL(forID: good.id, in: directory),
                                         to: BrandAssetStore.fileURL(forID: UUID().uuidString, in: directory))
        XCTAssertEqual(BrandAssetStore.loadAll(in: directory), [good])
    }

    func testUnknownKindDecodesAsImage() throws {
        let id = UUID().uuidString
        let json = """
        {"schemaVersion": 1, "id": "\(id)", "name": "Thing", "kind": "hologram", "assetName": "a.png"}
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: BrandAssetStore.fileURL(forID: id, in: directory))
        let loaded = BrandAssetStore.loadAll(in: directory)
        XCTAssertEqual(loaded.map(\.kind), [.image])
        XCTAssertEqual(loaded.first?.name, "Thing")
    }

    func testNewerSchemaIsSkipped() throws {
        let id = UUID().uuidString
        let json = """
        {"schemaVersion": 99, "id": "\(id)", "name": "Future", "kind": "logo", "assetName": "a.png"}
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: BrandAssetStore.fileURL(forID: id, in: directory))
        XCTAssertTrue(BrandAssetStore.loadAll(in: directory).isEmpty)
    }

    func testEntryWithPathLikeImageNameIsRejected() throws {
        XCTAssertThrowsError(try BrandAssetStore.save(makeAsset(assetName: "../escape.png"), in: directory))
        XCTAssertThrowsError(try BrandAssetStore.save(makeAsset(assetName: ""), in: directory))
    }

    // MARK: Naming

    func testSuggestedNameCleansFileStems() {
        XCTAssertEqual(BrandAssetStore.suggestedName(forFileStem: "acme-logo_white"), "Acme Logo White")
        XCTAssertEqual(BrandAssetStore.suggestedName(forFileStem: "ACME.logo.dark"), "ACME Logo Dark")
        XCTAssertEqual(BrandAssetStore.suggestedName(forFileStem: "iPhone-icon"), "iPhone Icon")
        XCTAssertEqual(BrandAssetStore.suggestedName(forFileStem: "___"), "Untitled")
    }

    func testSuggestedKindFromFileStem() {
        XCTAssertEqual(BrandAssetKind.suggested(forFileStem: "acme-logo-white"), .logo)
        XCTAssertEqual(BrandAssetKind.suggested(forFileStem: "Wordmark"), .logo)
        XCTAssertEqual(BrandAssetKind.suggested(forFileStem: "app-icon"), .icon)
        XCTAssertEqual(BrandAssetKind.suggested(forFileStem: "hero-photo"), .image)
    }

    func testUniqueNameNumbersDuplicates() {
        XCTAssertEqual(BrandAssetStore.uniqueName("Logo", existing: ["logo", "Logo 2"]), "Logo 3")
        XCTAssertEqual(BrandAssetStore.uniqueName("Logo", existing: []), "Logo")
    }

    // MARK: Managed folder (brandAssetsFolderPath)

    private func makeManagedFolder(_ files: [String: String]) throws -> URL {
        let folder = directory.appendingPathComponent("Brand", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, contents) in files {
            try Data(contents.utf8).write(to: folder.appendingPathComponent(name))
        }
        return folder
    }

    func testManagedFolderScanListsImagesSortedWithNamesAndKinds() throws {
        let folder = try makeManagedFolder(["zeta-icon.png": "z", "acme-logo-white.png": "a", "notes.txt": "n", "hero.jpeg": "h"])
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try Data("s".utf8).write(to: folder.appendingPathComponent("Sub/inner-logo.png"))
        let scanned = BrandAssetStore.scanManagedFolder(folder.path)
        XCTAssertEqual(scanned.assets.map(\.name), ["Acme Logo White", "Hero", "Zeta Icon"])
        XCTAssertEqual(scanned.assets.map(\.kind), [.logo, .image, .icon])
        XCTAssertTrue(scanned.assets.allSatisfy(\.isManaged))
        XCTAssertEqual(scanned.sources.count, 3)
        XCTAssertEqual(scanned.sources[scanned.assets[0].assetName]?.lastPathComponent, "acme-logo-white.png")
    }

    func testManagedAssetNameMatchesTheStoreImportName() throws {
        let folder = try makeManagedFolder(["logo.png": "same bytes"])
        let scanned = BrandAssetStore.scanManagedFolder(folder.path)
        let imported = try ScreenSaverSceneStore.importAsset(from: folder.appendingPathComponent("logo.png"),
                                                             in: directory.appendingPathComponent("Store"))
        XCTAssertEqual(scanned.assets.first?.assetName, imported)
        XCTAssertEqual(scanned.assets.first?.id, BrandAsset.managedIDPrefix + imported)
    }

    func testManagedFolderListsIdenticalBytesOnceAndNumbersClashingNames() throws {
        // logo-copy.png sorts first, so it is the listed copy of the shared bytes.
        let folder = try makeManagedFolder(["logo.png": "same", "logo-copy.png": "same",
                                            "mark.png": "m1", "mark.jpg": "m2"])
        let scanned = BrandAssetStore.scanManagedFolder(folder.path)
        XCTAssertEqual(scanned.assets.count, 3)
        XCTAssertEqual(Set(scanned.assets.map(\.name)), ["Logo Copy", "Mark", "Mark 2"])
    }

    func testMissingOrBlankManagedFolderIsEmpty() {
        XCTAssertTrue(BrandAssetStore.scanManagedFolder("").isEmpty)
        XCTAssertTrue(BrandAssetStore.scanManagedFolder("   ").isEmpty)
        XCTAssertTrue(BrandAssetStore.scanManagedFolder(directory.appendingPathComponent("nope").path).isEmpty)
    }

    func testManagedEntriesAreNeverSaved() {
        XCTAssertThrowsError(try BrandAssetStore.save(BrandAsset(id: BrandAsset.managedIDPrefix + "a.png", name: "A", assetName: "a.png"),
                                                      in: directory))
    }

    func testMergedListsLibraryFirstAndSkipsManagedDuplicates() {
        let mine = makeAsset(name: "Mine", assetName: "shared.png")
        let managedDup = BrandAsset(id: "managed:shared.png", name: "Theirs", assetName: "shared.png")
        let managedNew = BrandAsset(id: "managed:new.png", name: "New", assetName: "new.png")
        let merged = BrandAssetStore.merged(library: [mine], managed: [managedDup, managedNew])
        XCTAssertEqual(merged.map(\.name), ["Mine", "New"])
    }

    // MARK: Scene references

    func testReferencedAssetNamesCoverBackgroundAndIcons() {
        var scene = ScreenSaverScene()
        XCTAssertTrue(scene.referencedAssetNames.isEmpty)
        scene.background.source = .image(assetName: "bg.png")
        var icon = IconLayer(symbolName: "sparkles")
        icon.imageAssetName = "logo.png"
        scene.layers = [SceneLayer(content: .icon(icon), size: 0.1),
                        SceneLayer.icon(symbolName: "star.fill")]
        XCTAssertEqual(scene.referencedAssetNames, ["bg.png", "logo.png"])
    }
}
