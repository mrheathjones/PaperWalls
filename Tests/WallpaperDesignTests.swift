import XCTest

// MARK: - Wallpaper design store (Studio › Wallpapers)

final class WallpaperDesignStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperWallsDesignStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeDesign(name: String = "Badge",
                            modifiedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> StoredWallpaperDesign {
        StoredWallpaperDesign(name: name,
                              createdAt: Date(timeIntervalSince1970: 1_600_000_000),
                              modifiedAt: modifiedAt,
                              scene: WallpaperPreset.companyBadge.scene,
                              pixelWidth: 3840, pixelHeight: 2160,
                              exportedFilename: "Badge.png")
    }

    func testSaveAndLoadRoundTrips() throws {
        let design = makeDesign()
        try WallpaperDesignStore.save(design, in: directory)
        XCTAssertEqual(WallpaperDesignStore.loadAll(in: directory), [design])
    }

    func testMissingDirectoryLoadsEmpty() {
        XCTAssertTrue(WallpaperDesignStore.loadAll(in: directory).isEmpty)
    }

    func testLoadSortsNewestFirst() throws {
        try WallpaperDesignStore.save(makeDesign(name: "Older", modifiedAt: Date(timeIntervalSince1970: 1_000)), in: directory)
        try WallpaperDesignStore.save(makeDesign(name: "Newer", modifiedAt: Date(timeIntervalSince1970: 2_000)), in: directory)
        XCTAssertEqual(WallpaperDesignStore.loadAll(in: directory).map(\.name), ["Newer", "Older"])
    }

    func testDeleteRemovesTheEntryAndItsThumbnail() throws {
        let design = makeDesign()
        try WallpaperDesignStore.save(design, in: directory)
        let thumbnail = WallpaperDesignStore.thumbnailURL(forID: design.id, in: directory)
        try FileManager.default.createDirectory(at: thumbnail.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x89, 0x50]).write(to: thumbnail)
        try WallpaperDesignStore.delete(id: design.id, in: directory)
        XCTAssertTrue(WallpaperDesignStore.loadAll(in: directory).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnail.path))
    }

    func testCorruptFileIsSkippedNotFatal() throws {
        let good = makeDesign()
        try WallpaperDesignStore.save(good, in: directory)
        try Data("{ nope".utf8).write(to: WallpaperDesignStore.fileURL(forID: UUID().uuidString, in: directory))
        XCTAssertEqual(WallpaperDesignStore.loadAll(in: directory), [good])
    }

    func testOlderFileWithoutSizeFieldsDecodesWithDefaults() throws {
        let id = UUID().uuidString
        let json = """
        {"schemaVersion": 1, "id": "\(id)", "name": "Plain",
         "createdAt": "2026-10-01T00:00:00Z", "modifiedAt": "2026-10-02T00:00:00Z",
         "scene": {"background": {"source": {"kind": "solid", "colorHex": "112233"}}, "layers": []}}
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: WallpaperDesignStore.fileURL(forID: id, in: directory))
        let loaded = try XCTUnwrap(WallpaperDesignStore.loadAll(in: directory).first)
        XCTAssertEqual(loaded.pixelSize, CGSize(width: 2560, height: 1600))
        XCTAssertNil(loaded.exportedFilename)
        XCTAssertEqual(loaded.scene.background.source, .solid(colorHex: "112233"))
    }

    func testInvalidIDCannotBeSaved() {
        var design = makeDesign()
        design.id = "not-a-uuid"
        XCTAssertThrowsError(try WallpaperDesignStore.save(design, in: directory))
    }
}

// MARK: - Export naming

final class WallpaperExportNamingTests: XCTestCase {
    func testFilenameIsTheNameMadeSafe() {
        XCTAssertEqual(WallpaperDesignStore.exportFilename(for: "Team / Q4: Launch"), "Team - Q4- Launch.png")
        XCTAssertEqual(WallpaperDesignStore.exportFilename(for: "  Spaced  "), "Spaced.png")
    }

    func testEmptyOrHiddenNamesGetAFallback() {
        XCTAssertEqual(WallpaperDesignStore.exportFilename(for: ""), "Wallpaper.png")
        XCTAssertEqual(WallpaperDesignStore.exportFilename(for: "..."), "Wallpaper.png")
        XCTAssertEqual(WallpaperDesignStore.exportFilename(for: "..hidden"), "hidden.png")
    }

    func testLongNamesAreTruncated() {
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(WallpaperDesignStore.exportFilename(for: long).count, 80 + ".png".count)
    }
}

// MARK: - Render sizes

final class WallpaperRenderSizeTests: XCTestCase {
    func testDisplaysComeFirstAndCoveredPresetsAreDropped() {
        let options = WallpaperRenderSize.options(displayPixelSizes: [CGSize(width: 2560, height: 1600),
                                                                      CGSize(width: 5120, height: 2880)])
        XCTAssertEqual(options.map(\.label).prefix(2), ["Main display (2560 × 1600)", "Display 2 (5120 × 2880)"])
        XCTAssertEqual(options.filter(\.isDisplay).count, 2)
        XCTAssertEqual(options.count, 2 + WallpaperRenderSize.presets.count - 2)
        XCTAssertFalse(options.dropFirst(2).contains { $0.pixelSize == CGSize(width: 5120, height: 2880) })
    }

    func testDuplicateAndEmptyDisplaysAreIgnored() {
        let options = WallpaperRenderSize.options(displayPixelSizes: [.zero, CGSize(width: 1920, height: 1080),
                                                                      CGSize(width: 1920, height: 1080)])
        XCTAssertEqual(options.filter(\.isDisplay).count, 1)
    }

    func testDefaultIsTheMainDisplayElseAPreset() {
        XCTAssertEqual(WallpaperRenderSize.defaultPixelSize(displayPixelSizes: [CGSize(width: 3024, height: 1964)]),
                       CGSize(width: 3024, height: 1964))
        XCTAssertEqual(WallpaperRenderSize.defaultPixelSize(displayPixelSizes: []), CGSize(width: 2560, height: 1600))
    }
}

// MARK: - Image background source

final class SceneScaleModeTests: XCTestCase {
    func testFitBlurRoundTripsAndUnknownModesFallBackToFill() throws {
        var treatment = SceneBackgroundTreatment()
        treatment.scaleMode = .fitBlur
        let data = try JSONEncoder().encode(treatment)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"fitBlur\""))
        XCTAssertEqual(try JSONDecoder().decode(SceneBackgroundTreatment.self, from: data).scaleMode, .fitBlur)
        let future = Data(#"{"scaleMode": "hologram"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(SceneBackgroundTreatment.self, from: future).scaleMode, .fill)
    }
}

final class ImageBackgroundSourceTests: XCTestCase {
    func testImageBackgroundRoundTrips() throws {
        var scene = ScreenSaverScene()
        scene.background.source = .image(assetName: "abc123.png")
        let data = try JSONEncoder().encode(scene)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"kind\":\"image\""))
        XCTAssertEqual(try JSONDecoder().decode(ScreenSaverScene.self, from: data), scene)
    }

    func testImageBackgroundShipsInsideADeployedBundle() throws {
        let assets = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperWallsImageBackground-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: assets) }
        try Data([0x89]).write(to: assets.appendingPathComponent("bg.png"))

        var scene = ScreenSaverScene()
        scene.background.source = .image(assetName: "bg.png")
        let snapshot = ScreenSaverSnapshot(state: .active, scene: scene, assetsDirectory: assets.path)
        let (portable, media) = SceneDeployment.portable(snapshot)
        XCTAssertEqual(media.map(\.destination), ["Media/Assets/bg.png"])
        XCTAssertEqual(portable.assetsDirectory, "Media/Assets")
    }
}

// MARK: - Presets

final class WallpaperPresetTests: XCTestCase {
    func testPresetsAreStillImages() {
        for preset in WallpaperPreset.allCases {
            XCTAssertTrue(preset.scene.layers.allSatisfy { $0.motion.kind == .still }, preset.rawValue)
        }
        XCTAssertTrue(WallpaperPreset.blankScene.layers.isEmpty)
    }

    func testPresetsRoundTripThroughJSON() throws {
        for preset in WallpaperPreset.allCases {
            let scene = preset.scene   // each call mints fresh layer IDs
            let data = try JSONEncoder().encode(scene)
            XCTAssertEqual(try JSONDecoder().decode(ScreenSaverScene.self, from: data), scene, preset.rawValue)
        }
    }
}
