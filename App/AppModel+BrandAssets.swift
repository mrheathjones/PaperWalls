import AppKit
import Foundation

// MARK: - Brand assets (Studio › Assets)

/// What happened to a batch of files dropped on, or chosen for, the
/// library.
struct BrandAssetImportResult: Equatable {
    var added: [BrandAsset] = []
    /// Files already in the library (same image bytes), by file name.
    var duplicates: [String] = []
    /// Files that aren't supported images, by file name.
    var rejected: [String] = []
}

/// Where one asset's image is drawn right now.
struct BrandAssetUsage: Equatable {
    var screenSavers = 0
    var wallpaperDesigns = 0
    var otherAssets = 0
    var inOpenDraft = false

    var isEmpty: Bool {
        screenSavers == 0 && wallpaperDesigns == 0 && otherAssets == 0 && !inOpenDraft
    }
}

extension AppModel {
    func reloadBrandAssets() {
        brandAssets = BrandAssetStore.loadAll()
    }

    func brandAsset(withID id: String) -> BrandAsset? {
        brandAssets.first { $0.id == id }
    }

    /// The library entry for an image a scene refers to, if the image came
    /// from the library (or is byte-identical to one that did).
    func brandAsset(forAssetName name: String) -> BrandAsset? {
        brandAssets.first { $0.assetName == name }
    }

    func brandAssetURL(_ asset: BrandAsset) -> URL? {
        ScreenSaverSceneStore.assetURL(named: asset.assetName)
    }

    /// Copies each image into the Studio asset store and adds a library
    /// entry named after the file. A file whose bytes are already in the
    /// library is reported as a duplicate, not added twice.
    @discardableResult
    func addBrandAssets(from urls: [URL]) -> BrandAssetImportResult {
        var result = BrandAssetImportResult()
        guard prefs.adminModeEnabled else {
            result.rejected = urls.map(\.lastPathComponent)
            return result
        }
        var names = brandAssets.map(\.name)
        var assetNames = Set(brandAssets.map(\.assetName))
        for url in urls {
            do {
                let assetName = try ScreenSaverSceneStore.importAsset(from: url)
                guard !assetNames.contains(assetName) else {
                    result.duplicates.append(url.lastPathComponent)
                    continue
                }
                let stem = url.deletingPathExtension().lastPathComponent
                let asset = BrandAsset(name: BrandAssetStore.uniqueName(BrandAssetStore.suggestedName(forFileStem: stem),
                                                                        existing: names),
                                       kind: .suggested(forFileStem: stem),
                                       assetName: assetName)
                try BrandAssetStore.save(asset)
                names.append(asset.name)
                assetNames.insert(assetName)
                result.added.append(asset)
            } catch {
                result.rejected.append(url.lastPathComponent)
            }
        }
        if !result.added.isEmpty {
            reloadBrandAssets()
        }
        return result
    }

    func renameBrandAsset(id: String, to newName: String) throws {
        guard prefs.adminModeEnabled, var asset = brandAsset(withID: id) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != asset.name else { return }
        asset.name = BrandAssetStore.uniqueName(trimmed, existing: brandAssets.filter { $0.id != id }.map(\.name))
        asset.modifiedAt = Date()
        try BrandAssetStore.save(asset)
        reloadBrandAssets()
    }

    func setBrandAssetKind(id: String, kind: BrandAssetKind) throws {
        guard prefs.adminModeEnabled, var asset = brandAsset(withID: id), asset.kind != kind else { return }
        asset.kind = kind
        asset.modifiedAt = Date()
        try BrandAssetStore.save(asset)
        reloadBrandAssets()
    }

    /// Removes the library entry. The image file is removed too, but only
    /// when nothing else draws it — a scene that used the asset keeps
    /// working, it just loses the library name.
    func deleteBrandAsset(id: String) throws {
        guard prefs.adminModeEnabled, let asset = brandAsset(withID: id) else { return }
        try BrandAssetStore.delete(id: id)
        reloadBrandAssets()
        if brandAssetUsage(asset).isEmpty, let url = brandAssetURL(asset) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func revealBrandAsset(_ asset: BrandAsset) {
        guard let url = brandAssetURL(asset) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Counts the saved screen savers and wallpaper designs that draw the
    /// asset's image, plus other library entries and open drafts.
    func brandAssetUsage(_ asset: BrandAsset) -> BrandAssetUsage {
        let name = asset.assetName
        var usage = BrandAssetUsage()
        usage.screenSavers = allScreenSavers.filter { $0.scene.referencedAssetNames.contains(name) }.count
        usage.wallpaperDesigns = wallpaperDesigns.filter { $0.scene.referencedAssetNames.contains(name) }.count
        usage.otherAssets = brandAssets.filter { $0.id != asset.id && $0.assetName == name }.count
        usage.inOpenDraft = [studio.draft, studio.wallpaperDraft]
            .contains { $0?.scene.referencedAssetNames.contains(name) == true }
        return usage
    }
}
