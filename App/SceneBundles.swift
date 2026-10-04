import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import os

/// Keeps `~/Library/Screen Savers` in step with the scenes that should have
/// their own tile in System Settings (spec §10; see `SceneBundleSpec`).
///
/// Each listed scene gets a copy of the embedded PaperWalls.saver, renamed
/// and re-identified for that scene, carrying the scene's snapshot and a
/// thumbnail rendered from it, re-signed ad hoc. A copy is regenerated
/// when its snapshot or the template version changes, and removed when
/// the scene is unlisted, deleted, or no longer allowed by policy.
final class SceneBundleManager {
    static let log = Logger(subsystem: ManagedPreferences.domain, category: "scenebundles")

    /// What one listed scene should be on disk.
    struct Desired {
        let spec: SceneBundleSpec
        let snapshot: ScreenSaverSnapshot
    }

    /// The user's screen saver folder (real home, even if the app were
    /// ever sandboxed).
    static let directory = ScreenSaverSnapshot.realHomeDirectory
        .appendingPathComponent("Library/Screen Savers", isDirectory: true)

    /// The saver built into the app — the template every copy starts from.
    static var templateURL: URL? {
        Bundle.main.url(forResource: "PaperWalls", withExtension: "saver")
    }

    static let systemSaverURL = URL(fileURLWithPath: "/Library/Screen Savers/PaperWalls.saver")
    static var userSaverURL: URL { directory.appendingPathComponent("PaperWalls.saver") }

    private var isSyncing = false
    private var queued: [Desired]?
    private var pending: DispatchWorkItem?

    // MARK: - Scheduling

    /// Debounced: bursts of changes (a slider drag that republishes, a
    /// rescan) collapse into one pass.
    func schedule(_ desired: [Desired]) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.sync(desired) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    @MainActor
    func sync(_ desired: [Desired]) async {
        guard !isSyncing else {
            queued = desired          // the newest wins; run again after
            return
        }
        isSyncing = true
        await performSync(desired)
        isSyncing = false
        if let next = queued {
            queued = nil
            await sync(next)
        }
    }

    @MainActor
    private func performSync(_ desired: [Desired]) async {
        let existing = Self.scanExisting()
        guard let templateURL = Self.templateURL else {
            if !existing.isEmpty || !desired.isEmpty {
                Self.log.error("No embedded screen saver template; scene bundles can't be maintained")
            }
            return
        }
        let templateVersion = Self.bundleVersion(at: templateURL)

        var keep: Set<String> = []
        for item in desired {
            keep.insert(item.spec.bundleName)
            if let current = existing.first(where: { $0.bundleName == item.spec.bundleName }),
               current.templateVersion == templateVersion,
               let snapshot = current.snapshot, snapshot.hasSameContent(as: item.snapshot) {
                continue   // up to date
            }
            // Thumbnails render on the main actor; the file work doesn't.
            let thumbnails = await Self.renderThumbnails(for: item.snapshot)
            do {
                try await Self.generate(item, thumbnails: thumbnails, templateURL: templateURL)
                Self.log.info("Generated scene bundle \(item.spec.bundleName, privacy: .public)")
            } catch {
                Self.log.error("Could not generate \(item.spec.bundleName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        for stale in existing where !keep.contains(stale.bundleName) {
            do {
                try FileManager.default.removeItem(at: stale.url)
                Self.log.info("Removed scene bundle \(stale.bundleName, privacy: .public)")
            } catch {
                Self.log.error("Could not remove \(stale.bundleName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Existing bundles

    struct Existing {
        let url: URL
        let bundleName: String
        let templateVersion: String
        let snapshot: ScreenSaverSnapshot?
    }

    /// Bundles this feature generated earlier (by filename pattern and
    /// identifier — a user's own "PaperWalls – …" bundle is never touched).
    nonisolated static func scanExisting() -> [Existing] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.compactMap { name -> Existing? in
            guard SceneBundleSpec.isGeneratedBundleName(name) else { return nil }
            let url = directory.appendingPathComponent(name)
            guard let identifier = Bundle(url: url)?.bundleIdentifier,
                  SceneBundleSpec.sceneID(fromBundleIdentifier: identifier) != nil else { return nil }
            let snapshotURL = url.appendingPathComponent("Contents/Resources/\(ScreenSaverSnapshot.bundledFilename)")
            return Existing(url: url, bundleName: name, templateVersion: bundleVersion(at: url),
                            snapshot: ScreenSaverSnapshot.read(from: snapshotURL))
        }
    }

    nonisolated static func bundleVersion(at url: URL) -> String {
        Bundle(url: url)?.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    // MARK: - Generation

    struct Thumbnails {
        var oneX: Data?
        var twoX: Data?
    }

    @MainActor
    private static func renderThumbnails(for snapshot: ScreenSaverSnapshot) async -> Thumbnails {
        guard let scene = snapshot.scene else { return Thumbnails() }
        let resources = SceneResources(
            wallpaperURL: { id in snapshot.wallpaperPaths[id].map { URL(fileURLWithPath: $0) } },
            currentDesktopURL: {
                (NSScreen.main ?? NSScreen.screens.first).flatMap { WallpaperEngine.currentWallpaperURL(for: $0) }
            },
            rotationURLs: { snapshot.rotationPaths.map { URL(fileURLWithPath: $0) } },
            assetURL: { snapshot.assetURL(named: $0) },
            tokens: SceneTokenValues(companyName: snapshot.companyName))
        var thumbnails = Thumbnails()
        if let image = await ScreenSaverThumbnailer.render(scene, resources: resources, scale: 1) {
            thumbnails.oneX = ScreenSaverThumbnailer.pngData(image)
        }
        if let image = await ScreenSaverThumbnailer.render(scene, resources: resources, scale: 2) {
            thumbnails.twoX = ScreenSaverThumbnailer.pngData(image)
        }
        return thumbnails
    }

    /// Builds the copy in a scratch folder, then swaps it into place.
    nonisolated private static func generate(_ item: Desired, thumbnails: Thumbnails, templateURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let scratch = fileManager.temporaryDirectory
                .appendingPathComponent("PaperWallsSceneBundle-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: scratch) }

            let staged = scratch.appendingPathComponent(item.spec.bundleName)
            try fileManager.copyItem(at: templateURL, to: staged)

            // Identity
            let infoURL = staged.appendingPathComponent("Contents/Info.plist")
            let infoData = try Data(contentsOf: infoURL)
            guard let template = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            let info = item.spec.infoDictionary(fromTemplate: template)
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)

            // Content
            let resources = staged.appendingPathComponent("Contents/Resources", isDirectory: true)
            try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
            try item.snapshot.write(to: resources.appendingPathComponent(ScreenSaverSnapshot.bundledFilename))
            // The template's catalog also holds a "thumbnail"; the loose
            // PNGs must be the only one so the tile shows this scene.
            try? fileManager.removeItem(at: resources.appendingPathComponent("Assets.car"))
            if let data = thumbnails.oneX {
                try data.write(to: resources.appendingPathComponent("thumbnail.png"))
            }
            if let data = thumbnails.twoX {
                try data.write(to: resources.appendingPathComponent("thumbnail@2x.png"))
            }

            // The edits broke the template's signature; sign the copy ad hoc.
            try codesign(staged)

            let destination = directory.appendingPathComponent(item.spec.bundleName)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: staged, to: destination)
        }.value
    }

    nonisolated private static func codesign(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--deep", "--sign", "-", url.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "codesign", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: message.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
    }

    // MARK: - The plain saver

    enum InstallStatus: Equatable {
        case system     // /Library/Screen Savers (the pkg)
        case user       // ~/Library/Screen Savers (installed from the app)
        case notInstalled
    }

    static var installStatus: InstallStatus {
        if FileManager.default.fileExists(atPath: systemSaverURL.path) { return .system }
        if FileManager.default.fileExists(atPath: userSaverURL.path) { return .user }
        return .notInstalled
    }

    /// Copies the embedded saver (unchanged, so its signature stands) into
    /// the user's folder — for Macs that didn't get the pkg.
    static func installForCurrentUser() throws {
        guard let templateURL else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: userSaverURL.path) {
            try FileManager.default.removeItem(at: userSaverURL)
        }
        try FileManager.default.copyItem(at: templateURL, to: userSaverURL)
    }
}
