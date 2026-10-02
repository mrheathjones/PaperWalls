import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Screen saver library + Studio navigation (spec §10). The ScreenSavers
// page and Studio never talk to each other directly — both go through
// these members and the published state on AppModel.
extension AppModel {
    // MARK: - Policy

    var screenSaverPolicy: ScreenSaverPolicy {
        ScreenSaverPolicy(enabled: prefs.screenSaverEnabled,
                          lockMode: lockState.mode,
                          activeID: prefs.activeScreenSaverSceneID,
                          activeIDForced: prefs.isForced(.activeScreenSaverSceneID),
                          allowedIDs: prefs.allowedScreenSaverSceneIDs,
                          allowCreation: prefs.allowScreenSaverCreation)
    }

    /// The managed entry (when provisioned) followed by the user's scenes.
    var allScreenSavers: [StoredScreenSaver] {
        (managedScreenSaver.map { [$0] } ?? []) + screenSavers
    }

    /// The scene the saver runs right now (badged ACTIVE), after the
    /// lock tier and allow-list are applied.
    var activeScreenSaverID: String? {
        screenSaverPolicy.effectiveActiveID(availableIDs: allScreenSavers.map(\.id))
    }

    func screenSaver(withID id: String) -> StoredScreenSaver? {
        allScreenSavers.first { $0.id == id }
    }

    // MARK: - Visibility / navigation

    var visibleStudioTabs: [StudioTab] {
        StudioTab.visibleTabs(showStudio: prefs.showStudio,
                              showWallpapersTab: prefs.showStudioWallpapersTab,
                              showScreenSaverTab: prefs.showStudioScreenSaverTab,
                              canCreate: screenSaverPolicy.canCreate)
    }

    /// True when the Scene Composer can be reached (Studio visible with
    /// its ScreenSaver tab). "Edit"/"New" entry points hide without it.
    var canOpenComposer: Bool {
        visibleStudioTabs.contains(.screenSaver)
    }

    /// Source-specific pages hide when their source is off: Collections is
    /// bundled-only, macOS follows showSystemWallpapers; the spec-§10
    /// pages follow their own gates.
    func isPageVisible(_ page: LibraryPage) -> Bool {
        switch page {
        case .collections: return prefs.showBundledWallpapers
        case .system: return prefs.showSystemWallpapers
        case .screenSavers: return prefs.showScreenSaversPage
        case .studio: return !visibleStudioTabs.isEmpty
        default: return true
        }
    }

    /// Never leave the user on a page (or Studio tab) whose gate flipped
    /// off mid-session — route to Browse.
    func enforcePageVisibility() {
        if !isPageVisible(page) {
            page = .browse
        }
        let tabs = visibleStudioTabs
        if !tabs.contains(studioTab), let first = tabs.first {
            studioTab = first
        }
    }

    /// Opens Studio's ScreenSaver tab with a request ("Edit" on a library
    /// card, "Create in Studio"). A no-op when the composer is hidden or
    /// creation is disabled — callers hide those controls in that case.
    func openStudio(_ request: StudioRequest) {
        guard canOpenComposer else { return }
        studioTab = .screenSaver
        studioRequest = request
        page = .studio
    }

    // MARK: - Library

    func reloadScreenSavers() {
        screenSavers = ScreenSaverSceneStore.loadAll()
        managedScreenSaver = ScreenSaverSceneStore.managedScene(
            defaultName: "\(prefs.companyDisplayName) Screen Saver")
        refreshScreenSaverThumbnails()
    }

    /// Saves a new scene (or a new version of `id`) and returns the entry.
    @discardableResult
    func saveScreenSaver(name: String, scene: ScreenSaverScene, replacing id: String? = nil) throws -> StoredScreenSaver {
        guard screenSaverPolicy.canCreate else { throw ScreenSaverLibraryError.creationDisabled }
        var stored: StoredScreenSaver
        if let id, let existing = screenSavers.first(where: { $0.id == id }) {
            stored = existing
            stored.name = name
            stored.scene = scene
            stored.modifiedAt = Date()
        } else {
            stored = StoredScreenSaver(
                name: ScreenSaverSceneStore.uniqueName(name, existing: allScreenSavers.map(\.name)),
                scene: scene)
        }
        try ScreenSaverSceneStore.save(stored)
        reloadScreenSavers()
        return stored
    }

    func renameScreenSaver(id: String, to newName: String) throws {
        guard screenSaverPolicy.canCreate else { throw ScreenSaverLibraryError.creationDisabled }
        guard var stored = screenSavers.first(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != stored.name else { return }
        stored.name = ScreenSaverSceneStore.uniqueName(
            trimmed, existing: allScreenSavers.filter { $0.id != id }.map(\.name))
        stored.modifiedAt = Date()
        try ScreenSaverSceneStore.save(stored)
        reloadScreenSavers()
    }

    /// Duplicating the managed entry produces a personal, editable copy.
    func duplicateScreenSaver(_ source: StoredScreenSaver) throws {
        try saveScreenSaver(name: "\(source.name) Copy", scene: source.scene)
    }

    func deleteScreenSaver(id: String) throws {
        guard screenSaverPolicy.canCreate else { throw ScreenSaverLibraryError.creationDisabled }
        try ScreenSaverSceneStore.delete(id: id)
        if prefs.activeScreenSaverSceneID == id {
            prefs.activeScreenSaverSceneID = nil
        }
        screenSaverThumbnails[id] = nil
        reloadScreenSavers()
    }

    func setActiveScreenSaver(id: String) {
        guard screenSaverPolicy.canSetActive(id) else { return }
        prefs.activeScreenSaverSceneID = id
    }

    /// Fullscreen, exactly as the saver draws it; any key or click exits.
    func previewScreenSaver(_ stored: StoredScreenSaver) {
        ScenePreviewPresenter.show(scene: stored.scene, resources: sceneResources,
                                   title: stored.name, fullscreen: true)
    }

    /// Copies the JSON an admin pastes into `managedScreenSaverScene`.
    func copyManagedSceneJSON(for stored: StoredScreenSaver) {
        guard let json = ScreenSaverSceneStore.managedSceneJSON(for: stored) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
    }

    // MARK: - Thumbnails

    /// Loads cached card thumbnails and (re)renders the missing or stale
    /// ones. The managed entry has no modification date, so it re-renders
    /// on every reload.
    func refreshScreenSaverThumbnails() {
        let entries = allScreenSavers
        let liveIDs = Set(entries.map(\.id))
        for id in screenSaverThumbnails.keys where !liveIDs.contains(id) {
            screenSaverThumbnails[id] = nil
        }

        let resources = sceneResources
        for entry in entries {
            let url = ScreenSaverSceneStore.thumbnailURL(forID: entry.id)
            let cachedDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if !entry.isManaged, let cachedDate, cachedDate >= entry.modifiedAt {
                if screenSaverThumbnails[entry.id] == nil, let image = NSImage(contentsOf: url) {
                    screenSaverThumbnails[entry.id] = image
                }
                continue
            }
            Task { @MainActor [weak self] in
                guard let image = await ScreenSaverThumbnailer.render(entry.scene, resources: resources) else { return }
                ScreenSaverThumbnailer.writePNG(image, to: url)
                self?.screenSaverThumbnails[entry.id] = NSImage(
                    cgImage: image, size: ScreenSaverThumbnailer.size)
            }
        }
    }
}

enum ScreenSaverLibraryError: LocalizedError {
    case creationDisabled

    var errorDescription: String? {
        switch self {
        case .creationDisabled:
            return "Creating and editing screen savers is turned off by your organization."
        }
    }
}

/// Renders a scene's card thumbnail: one `SceneFrameView` frame at the
/// scene's starting instant, snapshotted with `ImageRenderer`.
@MainActor
enum ScreenSaverThumbnailer {
    /// Card aspect (16:10), in points; rendered at 2x.
    static let size = CGSize(width: 480, height: 300)

    private struct ImageBox: @unchecked Sendable {
        let image: CGImage?
    }

    static func render(_ scene: ScreenSaverScene, resources: SceneResources) async -> CGImage? {
        var background = SceneFrameBackground()
        if let url = backgroundURL(for: scene, resources: resources) {
            background.current = await Task.detached(priority: .utility) {
                ImageBox(image: SceneImageLoader.downsampledImage(at: url, maxPixelSize: 960))
            }.value.image
        }
        let renderer = ImageRenderer(content: SceneFrameView(scene: scene,
                                                             date: Date(),
                                                             time: 0,
                                                             size: size,
                                                             background: background,
                                                             tokens: resources.tokens))
        renderer.scale = 2
        return renderer.cgImage
    }

    /// The image a thumbnail stands on: the scene's own background, or the
    /// first of a rotating pool.
    private static func backgroundURL(for scene: ScreenSaverScene, resources: SceneResources) -> URL? {
        switch scene.background.source {
        case .currentDesktop: return resources.currentDesktopURL()
        case .wallpaper(let id): return resources.wallpaperURL(id)
        case .rotatingPool: return resources.rotationURLs().first
        case .solid, .gradient, .unsupported: return nil
        }
    }

    static func writePNG(_ image: CGImage, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // Write beside the target, then swap in — never a half-written PNG.
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp")
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL,
                                                                UTType.png.identifier as CFString, 1, nil) else {
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
}
