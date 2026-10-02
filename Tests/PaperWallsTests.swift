import CryptoKit
import XCTest

// MARK: - Resolver precedence (spec §2)

final class PreferenceResolverTests: XCTestCase {
    private func makeResolver(mdm: [String: Any] = [:],
                              user: [String: Any] = [:],
                              localForced: [String: Any] = [:],
                              localDefaults: [String: Any] = [:]) -> PreferenceResolver {
        PreferenceResolver(mdmForcedValue: { mdm[$0] },
                           userValue: { user[$0] },
                           localForced: localForced,
                           localDefaults: localDefaults)
    }

    func testMDMForcedBeatsEverything() {
        let resolver = makeResolver(mdm: ["k": "mdm"],
                                    user: ["k": "user"],
                                    localForced: ["k": "localF"],
                                    localDefaults: ["k": "localD"])
        XCTAssertEqual(resolver.value(forKey: "k") as? String, "mdm")
    }

    func testLocalForcedBeatsUserAndDefaults() {
        let resolver = makeResolver(user: ["k": "user"],
                                    localForced: ["k": "localF"],
                                    localDefaults: ["k": "localD"])
        XCTAssertEqual(resolver.value(forKey: "k") as? String, "localF")
    }

    func testUserBeatsLocalDefaults() {
        let resolver = makeResolver(user: ["k": "user"],
                                    localDefaults: ["k": "localD"])
        XCTAssertEqual(resolver.value(forKey: "k") as? String, "user")
    }

    func testLocalDefaultsUsedLast() {
        let resolver = makeResolver(localDefaults: ["k": "localD"])
        XCTAssertEqual(resolver.value(forKey: "k") as? String, "localD")
    }

    func testNilWhenUnsetEverywhere() {
        XCTAssertNil(makeResolver().value(forKey: "k"))
    }

    func testIsForcedForMDMAndLocalForcedOnly() {
        XCTAssertTrue(makeResolver(mdm: ["k": 1]).isForced("k"))
        XCTAssertTrue(makeResolver(localForced: ["k": 1]).isForced("k"))
        XCTAssertFalse(makeResolver(user: ["k": 1]).isForced("k"))
        XCTAssertFalse(makeResolver(localDefaults: ["k": 1]).isForced("k"))
    }
}

// MARK: - Local config parsing (spec §2)

final class LocalManagedConfigTests: XCTestCase {
    func testParsesJSON() throws {
        let json = """
        {"forced": {"lockMode": "hard"}, "defaults": {"autoRotateIntervalMinutes": 30}}
        """
        let config = try XCTUnwrap(LocalManagedConfig.parse(data: Data(json.utf8)))
        XCTAssertEqual(config.forced["lockMode"] as? String, "hard")
        XCTAssertEqual((config.defaults["autoRotateIntervalMinutes"] as? NSNumber)?.intValue, 30)
    }

    func testParsesPlist() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>forced</key>
            <dict><key>lockMode</key><string>soft</string></dict>
        </dict>
        </plist>
        """
        let config = try XCTUnwrap(LocalManagedConfig.parse(data: Data(plist.utf8)))
        XCTAssertEqual(config.forced["lockMode"] as? String, "soft")
        XCTAssertTrue(config.defaults.isEmpty)
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(LocalManagedConfig.parse(data: Data("not a config".utf8)))
    }

    func testMissingSectionsAreEmpty() throws {
        let config = try XCTUnwrap(LocalManagedConfig.parse(data: Data("{}".utf8)))
        XCTAssertTrue(config.forced.isEmpty)
        XCTAssertTrue(config.defaults.isEmpty)
    }
}

// MARK: - Lock tier mapping (spec §1)

final class LockModeMappingTests: XCTestCase {
    func testExplicitLockModeWinsOverLegacy() {
        let mode = LockMode.resolveConfigured(lockModeRaw: "enforcedRotation",
                                              lockSelection: true,
                                              allowLockExit: false,
                                              allowLockExitForced: true)
        XCTAssertEqual(mode, .enforcedRotation)
    }

    func testExplicitOffOverridesLegacyLockSelection() {
        let mode = LockMode.resolveConfigured(lockModeRaw: "off",
                                              lockSelection: true,
                                              allowLockExit: true,
                                              allowLockExitForced: false)
        XCTAssertEqual(mode, .off)
    }

    func testLegacyLockSelectionMapsToSoft() {
        let mode = LockMode.resolveConfigured(lockModeRaw: nil,
                                              lockSelection: true,
                                              allowLockExit: true,
                                              allowLockExitForced: false)
        XCTAssertEqual(mode, .soft)
    }

    func testLegacyForcedNoExitMapsToHard() {
        let mode = LockMode.resolveConfigured(lockModeRaw: nil,
                                              lockSelection: true,
                                              allowLockExit: false,
                                              allowLockExitForced: true)
        XCTAssertEqual(mode, .hard)
    }

    func testUnforcedNoExitStaysSoft() {
        // A locally-set allowLockExit=false must not hard-trap the user;
        // only the FORCED historical signal maps to hard.
        let mode = LockMode.resolveConfigured(lockModeRaw: nil,
                                              lockSelection: true,
                                              allowLockExit: false,
                                              allowLockExitForced: false)
        XCTAssertEqual(mode, .soft)
    }

    func testDefaultIsOff() {
        let mode = LockMode.resolveConfigured(lockModeRaw: nil,
                                              lockSelection: false,
                                              allowLockExit: true,
                                              allowLockExitForced: false)
        XCTAssertEqual(mode, .off)
    }
}

// MARK: - Pre-apply guard (spec §1)

final class ApplyGuardTests: XCTestCase {
    func testOffAllowsEverything() {
        XCTAssertNil(WallpaperApplyGuard.refusalReason(forApplying: "anything",
                                                       mode: .off, osEnforced: false,
                                                       managedSelectionID: nil, allowedIDs: nil))
    }

    func testSoftAllowsOnlyManagedSelection() {
        XCTAssertNil(WallpaperApplyGuard.refusalReason(forApplying: "pinned",
                                                       mode: .soft, osEnforced: false,
                                                       managedSelectionID: "pinned", allowedIDs: nil))
        XCTAssertNotNil(WallpaperApplyGuard.refusalReason(forApplying: "other",
                                                          mode: .soft, osEnforced: false,
                                                          managedSelectionID: "pinned", allowedIDs: nil))
    }

    func testSoftRefusesUnidentifiedApplies() {
        // CLI `set <path>` has no wallpaper ID — restrictive tiers refuse it.
        XCTAssertNotNil(WallpaperApplyGuard.refusalReason(forApplying: nil,
                                                          mode: .soft, osEnforced: false,
                                                          managedSelectionID: "pinned", allowedIDs: nil))
    }

    func testHardRefusesEverythingIncludingManagedSelection() {
        XCTAssertNotNil(WallpaperApplyGuard.refusalReason(forApplying: "pinned",
                                                          mode: .hard, osEnforced: true,
                                                          managedSelectionID: "pinned", allowedIDs: nil))
    }

    func testEnforcedRotationAllowsApprovedOnly() {
        let allowed = ["a", "b"]
        XCTAssertNil(WallpaperApplyGuard.refusalReason(forApplying: "a",
                                                       mode: .enforcedRotation, osEnforced: false,
                                                       managedSelectionID: nil, allowedIDs: allowed))
        XCTAssertNotNil(WallpaperApplyGuard.refusalReason(forApplying: "c",
                                                          mode: .enforcedRotation, osEnforced: false,
                                                          managedSelectionID: nil, allowedIDs: allowed))
        XCTAssertNotNil(WallpaperApplyGuard.refusalReason(forApplying: nil,
                                                          mode: .enforcedRotation, osEnforced: false,
                                                          managedSelectionID: nil, allowedIDs: allowed))
    }

    func testEnforcedRotationFallsBackToRotationPool() {
        // Spec §4: with no explicit allow-list, the resolved rotation pool
        // is the approved set.
        XCTAssertNil(WallpaperApplyGuard.refusalReason(forApplying: "in-pool",
                                                       mode: .enforcedRotation, osEnforced: false,
                                                       managedSelectionID: nil, allowedIDs: nil,
                                                       rotationPoolIDs: ["in-pool"]))
        XCTAssertNotNil(WallpaperApplyGuard.refusalReason(forApplying: "outsider",
                                                          mode: .enforcedRotation, osEnforced: false,
                                                          managedSelectionID: nil, allowedIDs: nil,
                                                          rotationPoolIDs: ["in-pool"]))
    }

    func testEnforcedRotationRefusesUnidentifiedApplies() {
        // CLI `set <path>` has no wallpaper ID — always refused under the
        // restrictive tier, even when no lists are resolvable.
        XCTAssertNotNil(WallpaperApplyGuard.refusalReason(forApplying: nil,
                                                          mode: .enforcedRotation, osEnforced: false,
                                                          managedSelectionID: nil, allowedIDs: nil))
    }

    func testEnforcedRotationWithoutAnyListAllowsIdentified() {
        // No allow-list and no resolvable pool (e.g. CLI without a library):
        // identified applies pass through.
        XCTAssertNil(WallpaperApplyGuard.refusalReason(forApplying: "anything",
                                                       mode: .enforcedRotation, osEnforced: false,
                                                       managedSelectionID: nil, allowedIDs: nil))
    }
}

// MARK: - Unified rotation pool (spec §4)

final class RotationPoolTests: XCTestCase {
    private func wallpaper(_ id: String, source: CuratedWallpaper.Source = .bundled) -> CuratedWallpaper {
        CuratedWallpaper(id: id, filename: "\(id).jpg", displayName: id, source: source)
    }

    private let allGates: Set<RotationPoolMember> = [.bundled, .orgFolder, .personal]

    private func sources() -> [RotationPoolMember: [CuratedWallpaper]] {
        [.bundled: [wallpaper("b1"), wallpaper("b2")],
         .orgFolder: [wallpaper("o1", source: .external)],
         .personal: [wallpaper("p1", source: .personal)]]
    }

    func testUnionInMemberOrder() {
        let pool = RotationPool.resolve(members: ["personal", "bundled"],
                                        gates: allGates, sources: sources(),
                                        favorites: [], lockMode: .off, allowedIDs: nil)
        XCTAssertEqual(pool.map(\.id), ["p1", "b1", "b2"])
    }

    func testGateOffExcludesSource() {
        let pool = RotationPool.resolve(members: ["bundled", "orgFolder"],
                                        gates: [.orgFolder], sources: sources(),
                                        favorites: [], lockMode: .off, allowedIDs: nil)
        XCTAssertEqual(pool.map(\.id), ["o1"])
    }

    func testFavoritesAsSoleMemberSpansAllGatedSources() {
        let pool = RotationPool.resolve(members: ["favorites"],
                                        gates: allGates, sources: sources(),
                                        favorites: ["b2", "p1"], lockMode: .off, allowedIDs: nil)
        XCTAssertEqual(Set(pool.map(\.id)), ["b2", "p1"])
    }

    func testFavoritesFiltersOtherMembers() {
        let pool = RotationPool.resolve(members: ["favorites", "bundled"],
                                        gates: allGates, sources: sources(),
                                        favorites: ["b2", "p1"], lockMode: .off, allowedIDs: nil)
        // p1 is hearted but personal isn't in the pool — favorites narrows,
        // never widens.
        XCTAssertEqual(pool.map(\.id), ["b2"])
    }

    func testHardLockEmptiesPool() {
        let pool = RotationPool.resolve(members: ["bundled"],
                                        gates: allGates, sources: sources(),
                                        favorites: [], lockMode: .hard, allowedIDs: nil)
        XCTAssertTrue(pool.isEmpty)
    }

    func testEnforcedRotationIntersectsAllowList() {
        let pool = RotationPool.resolve(members: ["bundled", "orgFolder"],
                                        gates: allGates, sources: sources(),
                                        favorites: [], lockMode: .enforcedRotation,
                                        allowedIDs: ["b1", "o1"])
        XCTAssertEqual(pool.map(\.id), ["b1", "o1"])
    }

    func testEmptyMembersIsDefinedNoOp() {
        let pool = RotationPool.resolve(members: [],
                                        gates: allGates, sources: sources(),
                                        favorites: [], lockMode: .off, allowedIDs: nil)
        XCTAssertTrue(pool.isEmpty)
    }

    func testDuplicateContentIDsCollapse() {
        // The same image (same content ID) in two folders appears once.
        let duplicated: [RotationPoolMember: [CuratedWallpaper]] = [
            .orgFolder: [wallpaper("file:same", source: .external)],
            .personal: [wallpaper("file:same", source: .personal)],
        ]
        let pool = RotationPool.resolve(members: ["orgFolder", "personal"],
                                        gates: allGates, sources: duplicated,
                                        favorites: [], lockMode: .off, allowedIDs: nil)
        XCTAssertEqual(pool.count, 1)
    }

    func testDefaultPoolCoversAllRealSources() {
        XCTAssertEqual(RotationPoolMember.defaultPool,
                       ["bundled", "system", "appCurated", "orgRemote", "orgFolder", "personal"])
    }

    func testUnknownMembersIgnored() {
        let pool = RotationPool.resolve(members: ["iCloudPhotos", "bundled"],
                                        gates: allGates, sources: sources(),
                                        favorites: [], lockMode: .off, allowedIDs: nil)
        XCTAssertEqual(pool.map(\.id), ["b1", "b2"])
    }
}

// MARK: - Tier-3 watch policy (spec §7)

final class WatchPolicyTests: XCTestCase {
    private func wallpaper(_ id: String, legacyID: String? = nil) -> CuratedWallpaper {
        CuratedWallpaper(id: id, filename: "\(id).jpg", displayName: id,
                         source: .personal, legacyID: legacyID)
    }

    func testCompliance() {
        XCTAssertTrue(WatchPolicy.isCompliant(currentPath: "/w/a.jpg", approvedPaths: ["/w/a.jpg"]))
        XCTAssertFalse(WatchPolicy.isCompliant(currentPath: "/w/rogue.jpg", approvedPaths: ["/w/a.jpg"]))
        // Unreadable current picture → treat as drifted and restore.
        XCTAssertFalse(WatchPolicy.isCompliant(currentPath: nil, approvedPaths: ["/w/a.jpg"]))
    }

    func testRevertPrefersLastApprovedSelection() {
        let pool = [wallpaper("a"), wallpaper("b")]
        XCTAssertEqual(WatchPolicy.revertTarget(pool: pool, selectedID: "b")?.id, "b")
    }

    func testRevertHonorsLegacySelectionID() {
        let pool = [wallpaper("a"), wallpaper("file:new", legacyID: "external-old")]
        XCTAssertEqual(WatchPolicy.revertTarget(pool: pool, selectedID: "external-old")?.id, "file:new")
    }

    func testRevertFallsBackToFirstPoolEntry() {
        let pool = [wallpaper("a"), wallpaper("b")]
        XCTAssertEqual(WatchPolicy.revertTarget(pool: pool, selectedID: "gone")?.id, "a")
        XCTAssertEqual(WatchPolicy.revertTarget(pool: pool, selectedID: nil)?.id, "a")
        XCTAssertNil(WatchPolicy.revertTarget(pool: [], selectedID: "a"))
    }
}

// MARK: - Legacy rotation keys → rotationPool (spec §4)

final class RotationPoolMigrationTests: XCTestCase {
    func testFavoritesSourceMapsToFavoritesOnly() {
        XCTAssertEqual(RotationPoolMigration.derive(source: "favorites",
                                                    includeBundled: true,
                                                    includePersonal: nil,
                                                    includeManaged: nil),
                       ["favorites"])
    }

    func testManagedSourceMapsToOrgFolder() {
        XCTAssertEqual(RotationPoolMigration.derive(source: "managed",
                                                    includeBundled: nil,
                                                    includePersonal: nil,
                                                    includeManaged: nil),
                       ["orgFolder"])
    }

    func testAllHonorsExplicitFalseFlags() {
        XCTAssertEqual(RotationPoolMigration.derive(source: "all",
                                                    includeBundled: false,
                                                    includePersonal: true,
                                                    includeManaged: nil),
                       ["orgFolder", "personal"])
    }

    func testIncludeFlagsAloneImplyAll() {
        // Old default source was "all"; a user who only ever touched an
        // include toggle still gets migrated.
        XCTAssertEqual(RotationPoolMigration.derive(source: nil,
                                                    includeBundled: nil,
                                                    includePersonal: false,
                                                    includeManaged: nil),
                       ["bundled", "orgFolder"])
    }

    func testNothingSetMeansNoMigration() {
        XCTAssertNil(RotationPoolMigration.derive(source: nil,
                                                  includeBundled: nil,
                                                  includePersonal: nil,
                                                  includeManaged: nil))
    }

    func testUnknownSourceLeftUnmigrated() {
        XCTAssertNil(RotationPoolMigration.derive(source: "everything",
                                                  includeBundled: true,
                                                  includePersonal: true,
                                                  includeManaged: true))
    }
}

// MARK: - Content-derived folder IDs (spec §6)

final class ContentIDTests: XCTestCase {
    private var tempDir: URL!
    private var originalCache: ContentIDCache!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PaperWallsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // Never touch the user's real hash cache from tests.
        originalCache = WallpaperCatalog.contentIDCache
        WallpaperCatalog.contentIDCache = ContentIDCache(
            cacheFileURL: tempDir.appendingPathComponent("content-id-cache.json"))
    }

    override func tearDownWithError() throws {
        WallpaperCatalog.contentIDCache = originalCache
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeFile(_ name: String, bytes: Data) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private var sampleBytes: Data {
        Data((0..<4096).map { UInt8($0 % 251) })
    }

    func testSameBytesGetSameIDAtDifferentPaths() throws {
        let original = try writeFile("original.jpg", bytes: sampleBytes)
        let moved = try writeFile("renamed-and-moved.jpg", bytes: sampleBytes)
        let originalID = try XCTUnwrap(WallpaperContentID.id(forFileAt: original))
        XCTAssertEqual(originalID, WallpaperContentID.id(forFileAt: moved))
        // The whole point of §6: the path-derived IDs for the same two files
        // do NOT survive the move.
        XCTAssertNotEqual(WallpaperCatalog.legacyPathID(forPath: original.path),
                          WallpaperCatalog.legacyPathID(forPath: moved.path))
    }

    func testDifferentBytesGetDifferentIDs() throws {
        let a = try writeFile("a.jpg", bytes: sampleBytes)
        let b = try writeFile("b.jpg", bytes: sampleBytes + Data([0xFF]))
        XCTAssertNotEqual(WallpaperContentID.id(forFileAt: a),
                          WallpaperContentID.id(forFileAt: b))
    }

    func testIDUsesFilePrefix() throws {
        let url = try writeFile("prefixed.jpg", bytes: sampleBytes)
        let id = try XCTUnwrap(WallpaperContentID.id(forFileAt: url))
        XCTAssertTrue(WallpaperContentID.isContentID(id))
        XCTAssertFalse(WallpaperContentID.isLegacyPathID(id))
    }

    func testCacheDetectsContentChange() throws {
        let cache = ContentIDCache(cacheFileURL: tempDir.appendingPathComponent("cache2.json"))
        let url = try writeFile("changing.jpg", bytes: sampleBytes)
        let before = try XCTUnwrap(cache.contentID(forFileAt: url))
        XCTAssertEqual(before, cache.contentID(forFileAt: url))   // cache hit

        try (sampleBytes + Data([1, 2, 3])).write(to: url)        // new size ⇒ new key
        let after = try XCTUnwrap(cache.contentID(forFileAt: url))
        XCTAssertNotEqual(before, after)
    }

    func testScanFolderAssignsContentAndLegacyIDs() throws {
        let url = try writeFile("scanned.jpg", bytes: sampleBytes)
        let scanned = WallpaperCatalog.scanFolder(at: tempDir, source: .personal)
        let wallpaper = try XCTUnwrap(scanned.first)
        XCTAssertEqual(scanned.count, 1)
        XCTAssertEqual(wallpaper.id, WallpaperContentID.id(forFileAt: url))
        // The legacy ID must come from the same enumeration the migration
        // mapping uses (directory listings resolve /var → /private/var, so a
        // hand-built path would hash differently).
        let listedURL = try XCTUnwrap(WallpaperCatalog.imageFiles(in: tempDir).first)
        XCTAssertEqual(wallpaper.legacyID, WallpaperCatalog.legacyPathID(forPath: listedURL.path))

        // Old profiles pinning the path-derived ID still resolve.
        var library = WallpaperLibrary()
        library.personal = scanned
        XCTAssertEqual(library.wallpaper(withID: wallpaper.legacyID!)?.id, wallpaper.id)
    }
}

// MARK: - Remote catalog (spec §4)

final class RemoteManifestTests: XCTestCase {
    private let validJSON = """
    {"version": 2, "wallpapers": [
      {"id": "w1", "displayName": "One", "collection": "Seasons",
       "image": "assets/aa.jpg", "thumbnail": "thumbs/aa.jpg",
       "sha256": "aa", "size": 100, "minAppVersion": null},
      {"id": "w2", "displayName": "Two", "collection": null,
       "image": "assets/bb.jpg", "thumbnail": null,
       "sha256": "bb", "size": 200, "minAppVersion": "1.5"}
    ]}
    """

    func testParsesV2() throws {
        let manifest = try XCTUnwrap(RemoteManifest.parse(data: Data(validJSON.utf8)))
        XCTAssertEqual(manifest.wallpapers.count, 2)
        XCTAssertEqual(manifest.wallpapers[0].id, "w1")
    }

    func testRejectsOtherVersionsAndGarbage() {
        XCTAssertNil(RemoteManifest.parse(data: Data("{\"version\": 1, \"wallpapers\": []}".utf8)))
        XCTAssertNil(RemoteManifest.parse(data: Data("not json".utf8)))
        XCTAssertNil(RemoteManifest.parse(data: Data()))
    }

    func testMinAppVersionFilter() throws {
        let manifest = try XCTUnwrap(RemoteManifest.parse(data: Data(validJSON.utf8)))
        XCTAssertEqual(manifest.entries(forAppVersion: "1.0").map(\.id), ["w1"])
        XCTAssertEqual(manifest.entries(forAppVersion: "1.5").map(\.id), ["w1", "w2"])
    }

    func testNumericVersionCompare() {
        XCTAssertTrue(RemoteManifest.version("1.10", isAtLeast: "1.9"))
        XCTAssertFalse(RemoteManifest.version("1.9", isAtLeast: "1.10"))
        XCTAssertTrue(RemoteManifest.version("1.0", isAtLeast: "1.0"))
        XCTAssertTrue(RemoteManifest.version("2", isAtLeast: "1.9.9"))
    }

    func testFeedNamespacing() {
        XCTAssertEqual(RemoteFeed.appCurated.namespacedID("sunset"), "app:sunset")
        XCTAssertEqual(RemoteFeed.appCurated.namespacedID("app:sunset"), "app:sunset")
        let org = RemoteFeed.org(urlString: "https://example.com/catalog.json", publicKeyBase64: "aa")
        XCTAssertEqual(org?.namespacedID("logo"), "org:logo")
    }

    func testOrgFeedRequiresBothURLAndKey() {
        XCTAssertNil(RemoteFeed.org(urlString: nil, publicKeyBase64: "aa"))
        XCTAssertNil(RemoteFeed.org(urlString: "https://example.com/c.json", publicKeyBase64: nil))
        XCTAssertNil(RemoteFeed.org(urlString: "not a url", publicKeyBase64: "aa"))
        XCTAssertNotNil(RemoteFeed.org(urlString: "https://example.com/c.json", publicKeyBase64: "aa"))
    }

    func testEvictionKeepsOnlyReferencedFiles() {
        XCTAssertEqual(RemoteCatalog.filesToEvict(existing: ["a.jpg", "b.jpg", "stale.jpg"],
                                                  referenced: ["a.jpg", "b.jpg"]),
                       ["stale.jpg"])
    }
}

final class RemoteManifestSignatureTests: XCTestCase {
    func testRoundTripAndTamperRejection() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKeyBase64 = key.publicKey.rawRepresentation.base64EncodedString()
        let manifest = Data("{\"version\": 2, \"wallpapers\": []}".utf8)
        let signature = try key.signature(for: manifest)

        // Raw signature bytes and base64 text both verify.
        XCTAssertTrue(RemoteManifestVerifier.verify(manifestData: manifest,
                                                    signature: signature,
                                                    publicKeyBase64: publicKeyBase64))
        XCTAssertTrue(RemoteManifestVerifier.verify(manifestData: manifest,
                                                    signature: Data(signature.base64EncodedString().utf8),
                                                    publicKeyBase64: publicKeyBase64))

        // Tampered manifest, wrong key, garbage key: all rejected.
        XCTAssertFalse(RemoteManifestVerifier.verify(manifestData: manifest + Data([0x20]),
                                                     signature: signature,
                                                     publicKeyBase64: publicKeyBase64))
        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertFalse(RemoteManifestVerifier.verify(manifestData: manifest,
                                                     signature: signature,
                                                     publicKeyBase64: otherKey))
        XCTAssertFalse(RemoteManifestVerifier.verify(manifestData: manifest,
                                                     signature: signature,
                                                     publicKeyBase64: "not base64!"))
    }

    func testBakedInAppFeedKeyIsValid() {
        // The baked-in constant must always decode to a usable key.
        let keyData = Data(base64Encoded: RemoteFeed.appCurated.publicKeyBase64)
        XCTAssertNotNil(keyData)
        XCTAssertEqual(keyData?.count, 32)
        XCTAssertNotNil(try? Curve25519.Signing.PublicKey(rawRepresentation: keyData!))
    }
}

final class RemoteCatalogCacheTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PaperWallsFeed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        RemoteCatalog.cacheRootOverride = tempDir
    }

    override func tearDownWithError() throws {
        RemoteCatalog.cacheRootOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testLoadCachedMapsOnlyPresentAssets() throws {
        let feedDir = tempDir.appendingPathComponent("appCurated", isDirectory: true)
        try FileManager.default.createDirectory(at: feedDir.appendingPathComponent("assets"),
                                                withIntermediateDirectories: true)
        let manifest = """
        {"version": 2, "wallpapers": [
          {"id": "here", "displayName": "Here", "collection": null,
           "image": "assets/aa.jpg", "thumbnail": null, "sha256": "aa", "size": 1, "minAppVersion": null},
          {"id": "missing", "displayName": "Missing", "collection": null,
           "image": "assets/bb.jpg", "thumbnail": null, "sha256": "bb", "size": 1, "minAppVersion": null}
        ]}
        """
        try Data(manifest.utf8).write(to: feedDir.appendingPathComponent("manifest.json"))
        try Data([1]).write(to: feedDir.appendingPathComponent("assets/aa.jpg"))

        let cached = RemoteCatalog.loadCached(feed: .appCurated, appVersion: "1.0")
        XCTAssertEqual(cached.wallpapers.map(\.id), ["app:here"])
        XCTAssertEqual(cached.wallpapers.first?.filename, "assets/aa.jpg")
        XCTAssertEqual(cached.wallpapers.first?.source, .appCurated)
    }

    func testLoadCachedEmptyWhenNoManifest() {
        let cached = RemoteCatalog.loadCached(feed: .appCurated, appVersion: "1.0")
        XCTAssertTrue(cached.wallpapers.isEmpty)
    }
}

// MARK: - macOS on-demand wallpapers

final class SystemWallpaperStoreTests: XCTestCase {
    func testParsesMadesktopDescriptor() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>mobileAssetID</key><string>Big Sur</string>
            <key>thumbnailPath</key><string>/System/Library/Desktop Pictures/.thumbnails/Big Sur.heic</string>
            <key>isDynamic</key><true/>
        </dict>
        </plist>
        """
        let parsed = try XCTUnwrap(SystemWallpaperStore.parseDescriptor(data: Data(plist.utf8)))
        XCTAssertEqual(parsed.assetID, "Big Sur")
        XCTAssertEqual(parsed.thumbnailPath, "/System/Library/Desktop Pictures/.thumbnails/Big Sur.heic")
        XCTAssertNil(SystemWallpaperStore.parseDescriptor(data: Data("junk".utf8)))
    }

    func testParsesMobileAssetCatalog() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict><key>Assets</key><array>
            <dict>
                <key>DesktopPictureID</key><string>Big Sur</string>
                <key>__BaseURL</key><string>https://updates.cdn-apple.com/x/</string>
                <key>__RelativePath</key><string>a/b.zip</string>
                <key>_DownloadSize</key><integer>12345</integer>
            </dict>
            <dict><key>DesktopPictureID</key><string>Broken (no URL)</string></dict>
        </array></dict>
        </plist>
        """
        let map = SystemWallpaperStore.parseCatalog(data: Data(plist.utf8))
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map["Big Sur"]?.url.absoluteString, "https://updates.cdn-apple.com/x/a/b.zip")
        XCTAssertEqual(map["Big Sur"]?.size, 12345)
        XCTAssertTrue(SystemWallpaperStore.parseCatalog(data: Data("junk".utf8)).isEmpty)
    }

    func testAbsoluteFilenamesResolveOutsideSourceFolder() {
        var library = WallpaperLibrary()
        library.systemFolderURL = URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true)
        let cached = CuratedWallpaper(id: "macos:Big Sur",
                                      filename: "/Users/x/Library/Application Support/PaperWalls/SystemWallpapers/Big Sur.heic",
                                      displayName: "Big Sur",
                                      thumbnailFilename: "/System/Library/Desktop Pictures/.thumbnails/Big Sur.heic",
                                      source: .system)
        let flat = CuratedWallpaper(id: "file:abc", filename: "Sonoma.heic",
                                    displayName: "Sonoma", source: .system)
        library.system = [cached, flat]
        XCTAssertEqual(library.fileURL(for: cached)?.path,
                       "/Users/x/Library/Application Support/PaperWalls/SystemWallpapers/Big Sur.heic")
        XCTAssertEqual(library.thumbnailURL(for: cached)?.path,
                       "/System/Library/Desktop Pictures/.thumbnails/Big Sur.heic")
        XCTAssertEqual(library.fileURL(for: flat)?.path,
                       "/System/Library/Desktop Pictures/Sonoma.heic")
    }
}

// MARK: - Personal folder source (spec §5)

final class PersonalFolderSourceTests: XCTestCase {
    func testExplicitKeyWins() {
        XCTAssertEqual(PersonalFolderSource.resolve(raw: "appManaged", userDefinedPath: "/some/folder"),
                       .appManaged)
        XCTAssertEqual(PersonalFolderSource.resolve(raw: "userDefined", userDefinedPath: nil),
                       .userDefined)
    }

    func testExistingUserFolderStaysUserDefined() {
        // Legacy compat: a configured personal folder keeps working even
        // though fresh setups default to app-managed.
        XCTAssertEqual(PersonalFolderSource.resolve(raw: nil, userDefinedPath: "/some/folder"),
                       .userDefined)
    }

    func testFreshSetupDefaultsToAppManaged() {
        XCTAssertEqual(PersonalFolderSource.resolve(raw: nil, userDefinedPath: nil), .appManaged)
        XCTAssertEqual(PersonalFolderSource.resolve(raw: nil, userDefinedPath: ""), .appManaged)
    }

    func testUnknownRawValueFallsBackToResolution() {
        XCTAssertEqual(PersonalFolderSource.resolve(raw: "cloud", userDefinedPath: "/f"), .userDefined)
        XCTAssertEqual(PersonalFolderSource.resolve(raw: "cloud", userDefinedPath: nil), .appManaged)
    }

    func testEffectivePath() {
        XCTAssertEqual(PersonalFolder.effectivePath(source: .appManaged, userDefinedPath: "/f"),
                       PersonalFolder.appManagedPath)
        XCTAssertEqual(PersonalFolder.effectivePath(source: .userDefined, userDefinedPath: "/f"), "/f")
        XCTAssertNil(PersonalFolder.effectivePath(source: .userDefined, userDefinedPath: ""))
        XCTAssertNil(PersonalFolder.effectivePath(source: .userDefined, userDefinedPath: nil))
    }

    func testUniqueFilenameDeDupes() {
        XCTAssertEqual(PersonalFolder.uniqueFilename("photo.jpg", existingLowercased: []),
                       "photo.jpg")
        XCTAssertEqual(PersonalFolder.uniqueFilename("photo.jpg", existingLowercased: ["photo.jpg"]),
                       "photo 2.jpg")
        // Case-insensitive like the file system, preserving the dropped name.
        XCTAssertEqual(PersonalFolder.uniqueFilename("Photo.JPG",
                                                     existingLowercased: ["photo.jpg", "photo 2.jpg"]),
                       "Photo 3.JPG")
    }
}

// MARK: - One-time path-ID → content-ID remap (spec §6)

final class ContentIDMigrationTests: XCTestCase {
    func testRemapRewritesMappedIDsInPlace() {
        let remapped = ContentIDMigration.remap(
            ids: ["bundled-aurora-veil", "external-aaaa", "external-bbbb"],
            mapping: ["external-aaaa": "file:1111", "external-bbbb": "file:2222"])
        XCTAssertEqual(remapped, ["bundled-aurora-veil", "file:1111", "file:2222"])
    }

    func testRemapKeepsUnmappedIDs() {
        // A legacy ID whose file is gone (or whose folder is offline) stays
        // put so a later launch can retry the remap.
        let remapped = ContentIDMigration.remap(ids: ["external-gone"], mapping: [:])
        XCTAssertEqual(remapped, ["external-gone"])
    }

    func testRemapCollapsesDuplicateContentIDs() {
        // Two paths that held byte-identical files map to one content ID.
        let remapped = ContentIDMigration.remap(
            ids: ["external-aaaa", "external-bbbb"],
            mapping: ["external-aaaa": "file:same", "external-bbbb": "file:same"])
        XCTAssertEqual(remapped, ["file:same"])
    }
}
