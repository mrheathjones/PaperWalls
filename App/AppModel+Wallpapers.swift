import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Studio › Wallpapers: the design library and the save-as-wallpaper flow.
// A design is a scene; saving renders one frame at the chosen pixel size
// into the Personal folder, where it is a wallpaper like any other.
extension AppModel {
    // MARK: - Library

    func reloadWallpaperDesigns() {
        wallpaperDesigns = WallpaperDesignStore.loadAll()
        refreshWallpaperDesignThumbnails()
    }

    func wallpaperDesign(withID id: String) -> StoredWallpaperDesign? {
        wallpaperDesigns.first { $0.id == id }
    }

    /// Connected displays' pixel sizes, main display first.
    var displayPixelSizes: [CGSize] {
        let main = NSScreen.main
        let ordered = (main.map { [$0] } ?? []) + screens.filter { $0 != main }
        return ordered.map { screen in
            CGSize(width: (screen.frame.width * screen.backingScaleFactor).rounded(),
                   height: (screen.frame.height * screen.backingScaleFactor).rounded())
        }
    }

    /// Where renders go: the Personal folder (app-managed by default).
    private var wallpaperExportFolder: URL? {
        guard let path = prefs.effectivePersonalFolderPath, !path.isEmpty else { return nil }
        if prefs.personalFolderSource == .appManaged {
            PersonalFolder.ensureAppManagedFolderExists()
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The rendered file of a design's last save, if it still exists.
    func exportedImageURL(for design: StoredWallpaperDesign) -> URL? {
        guard let filename = design.exportedFilename, let folder = wallpaperExportFolder else { return nil }
        let url = folder.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The library entry a design's last render became, if it still exists.
    func exportedWallpaper(for design: StoredWallpaperDesign) -> CuratedWallpaper? {
        guard let filename = design.exportedFilename else { return nil }
        return library.personal.first { $0.filename == filename }
    }

    // MARK: - Studio navigation

    /// Opens a design in the composer. If the composer holds unsaved
    /// changes to another design, the caller confirms first (`force`).
    func openWallpaperDesign(_ design: StoredWallpaperDesign) {
        studio.wallpaperDraft = SceneDraft(editingID: design.id, name: design.name, scene: design.scene)
        studio.wallpaperPixelSize = design.pixelSize
        studioTab = .wallpapers
        page = .studio
    }

    // MARK: - Save

    /// Renders the draft and writes it to the Personal folder, then saves
    /// the design and re-bases the draft on it. Nothing is written if the
    /// render fails.
    @discardableResult
    func saveWallpaperDraft() async throws -> StoredWallpaperDesign? {
        guard var draft = studio.wallpaperDraft else { return nil }
        for index in draft.scene.layers.indices {
            if case .text(var text) = draft.scene.layers[index].content {
                text.segments = text.segments.normalized
                draft.scene.layers[index].content = .text(text)
            }
        }
        guard let folder = wallpaperExportFolder else { throw WallpaperDesignError.noPersonalFolder }
        let pixelSize = studio.wallpaperPixelSize
        guard let image = await WallpaperRenderer.render(draft.scene, resources: sceneResources,
                                                         pixelSize: pixelSize) else {
            throw WallpaperDesignError.renderFailed
        }

        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var design: StoredWallpaperDesign
        if let id = draft.sceneID, let existing = wallpaperDesign(withID: id) {
            design = existing
            if name != existing.name {
                design.name = WallpaperDesignStore.uniqueName(
                    name, existing: wallpaperDesigns.filter { $0.id != id }.map(\.name))
            }
            design.scene = draft.scene
            design.modifiedAt = Date()
        } else {
            design = StoredWallpaperDesign(
                name: WallpaperDesignStore.uniqueName(name, existing: wallpaperDesigns.map(\.name)),
                scene: draft.scene)
        }
        design.pixelSize = pixelSize

        // A re-save replaces the previous file so the library doesn't fill
        // with versions; a first save picks a name that isn't taken.
        let filename: String
        if let previous = design.exportedFilename,
           FileManager.default.fileExists(atPath: folder.appendingPathComponent(previous).path) {
            filename = previous
        } else {
            let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
                .map { $0.lowercased() } ?? [])
            filename = PersonalFolder.uniqueFilename(WallpaperDesignStore.exportFilename(for: design.name),
                                                     existingLowercased: existing)
        }
        try WallpaperRenderer.writePNG(image, to: folder.appendingPathComponent(filename))
        design.exportedFilename = filename
        try WallpaperDesignStore.save(design)

        studio.wallpaperDraft = SceneDraft(editingID: design.id, name: design.name, scene: design.scene)
        reloadWallpaperDesigns()
        rescan()
        return design
    }

    func renameWallpaperDesign(id: String, to newName: String) throws {
        guard var design = wallpaperDesign(withID: id) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != design.name else { return }
        design.name = WallpaperDesignStore.uniqueName(
            trimmed, existing: wallpaperDesigns.filter { $0.id != id }.map(\.name))
        try WallpaperDesignStore.save(design)
        if studio.wallpaperDraft?.sceneID == id {
            studio.wallpaperDraft = SceneDraft(editingID: design.id, name: design.name, scene: design.scene)
        }
        reloadWallpaperDesigns()
    }

    /// Deletes the design; `removingImage` also moves its rendered
    /// wallpaper to the Trash.
    func deleteWallpaperDesign(id: String, removingImage: Bool) throws {
        guard let design = wallpaperDesign(withID: id) else { return }
        if removingImage, let url = exportedImageURL(for: design) {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        try WallpaperDesignStore.delete(id: id)
        if studio.wallpaperDraft?.sceneID == id {
            studio.wallpaperDraft = nil
        }
        wallpaperDesignThumbnails[id] = nil
        reloadWallpaperDesigns()
        if removingImage {
            rescan()
        }
    }

    func revealExportedImage(for design: StoredWallpaperDesign) {
        guard let url = exportedImageURL(for: design) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Thumbnails

    /// Card thumbnails, cached beside the designs and re-rendered when a
    /// design changes. Rendered at the design's own aspect ratio.
    func refreshWallpaperDesignThumbnails() {
        let liveIDs = Set(wallpaperDesigns.map(\.id))
        for id in wallpaperDesignThumbnails.keys where !liveIDs.contains(id) {
            wallpaperDesignThumbnails[id] = nil
        }
        let resources = sceneResources
        for design in wallpaperDesigns {
            let url = WallpaperDesignStore.thumbnailURL(forID: design.id)
            let cachedDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let cachedDate, cachedDate >= design.modifiedAt {
                if wallpaperDesignThumbnails[design.id] == nil, let image = NSImage(contentsOf: url) {
                    wallpaperDesignThumbnails[design.id] = image
                }
                continue
            }
            let size = WallpaperRenderer.thumbnailPointSize(for: design.pixelSize)
            Task { @MainActor [weak self] in
                guard let image = await ScreenSaverThumbnailer.render(design.scene, resources: resources,
                                                                      size: size) else { return }
                ScreenSaverThumbnailer.writePNG(image, to: url)
                self?.wallpaperDesignThumbnails[design.id] = NSImage(cgImage: image, size: size)
            }
        }
    }
}

/// Renders a scene as a still wallpaper image.
@MainActor
enum WallpaperRenderer {
    /// One frame at `pixelSize`: the scene is laid out at half that size in
    /// points and rendered at 2x, so relative layer sizes match the
    /// preview exactly and images are decoded at full target resolution.
    static func render(_ scene: ScreenSaverScene, resources: SceneResources, pixelSize: CGSize) async -> CGImage? {
        guard pixelSize.width >= 2, pixelSize.height >= 2 else { return nil }
        let scale: CGFloat = 2
        let points = CGSize(width: (pixelSize.width / scale).rounded(),
                            height: (pixelSize.height / scale).rounded())
        return await ScreenSaverThumbnailer.render(scene, resources: resources, scale: scale, size: points,
                                                   maxImagePixels: Int(max(pixelSize.width, pixelSize.height)))
    }

    /// Card thumbnail size (points) at the wallpaper's aspect ratio.
    static func thumbnailPointSize(for pixelSize: CGSize) -> CGSize {
        let width: CGFloat = 480
        guard pixelSize.width > 0, pixelSize.height > 0 else { return CGSize(width: width, height: 300) }
        return CGSize(width: width, height: (width * pixelSize.height / pixelSize.width).rounded())
    }

    /// Atomic PNG write (temp file + swap), throwing on failure.
    static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp")
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL,
                                                                UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
}
