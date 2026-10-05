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

    /// Rescans the organization's folder (`brandAssetsFolderPath`). Called
    /// with every managed-config reload, so a folder deployed after launch
    /// shows up on the next activation.
    func reloadManagedBrandAssets() {
        let folder = BrandAssetStore.scanManagedFolder(prefs.brandAssetsFolderPath)
        if folder != managedBrandAssets {
            managedBrandAssets = folder
        }
    }

    /// What the composer offers: the user's library, then the
    /// organization's assets not already in it.
    var allBrandAssets: [BrandAsset] {
        BrandAssetStore.merged(library: brandAssets, managed: managedBrandAssets.assets)
    }

    func brandAsset(withID id: String) -> BrandAsset? {
        allBrandAssets.first { $0.id == id }
    }

    /// The entry for an image a scene refers to, if the image came from the
    /// library or the organization's folder (or is byte-identical to one
    /// that did).
    func brandAsset(forAssetName name: String) -> BrandAsset? {
        allBrandAssets.first { $0.assetName == name }
    }

    /// The image file: the Studio asset store's copy when there is one,
    /// otherwise the organization folder's original.
    func brandAssetURL(_ asset: BrandAsset) -> URL? {
        if let stored = ScreenSaverSceneStore.assetURL(named: asset.assetName),
           FileManager.default.fileExists(atPath: stored.path) {
            return stored
        }
        return managedBrandAssets.sources[asset.assetName]
    }

    /// Makes the asset's image available to scenes and returns the name a
    /// scene refers to it by. A managed asset is copied into the Studio
    /// asset store the first time it is used, so the scene keeps working
    /// (and packages embed it) even if the folder later goes away.
    func useBrandAsset(_ asset: BrandAsset) -> String? {
        if let stored = ScreenSaverSceneStore.assetURL(named: asset.assetName),
           FileManager.default.fileExists(atPath: stored.path) {
            return asset.assetName
        }
        guard let source = managedBrandAssets.sources[asset.assetName] else { return nil }
        do {
            return try ScreenSaverSceneStore.importAsset(from: source)
        } catch {
            BrandAssetStore.log.error("Cannot copy managed brand asset \(source.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Copies an organization asset into the user's own library, so it can
    /// be renamed or re-sorted and stays if the folder changes.
    func addManagedBrandAssetToLibrary(_ asset: BrandAsset) throws {
        guard prefs.adminModeEnabled, asset.isManaged,
              !brandAssets.contains(where: { $0.assetName == asset.assetName }),
              let assetName = useBrandAsset(asset) else { return }
        let entry = BrandAsset(name: BrandAssetStore.uniqueName(asset.name, existing: brandAssets.map(\.name)),
                               kind: asset.kind,
                               assetName: assetName)
        try BrandAssetStore.save(entry)
        reloadBrandAssets()
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
        guard prefs.adminModeEnabled, var asset = brandAsset(withID: id), !asset.isManaged else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != asset.name else { return }
        asset.name = BrandAssetStore.uniqueName(trimmed, existing: brandAssets.filter { $0.id != id }.map(\.name))
        asset.modifiedAt = Date()
        try BrandAssetStore.save(asset)
        reloadBrandAssets()
    }

    func setBrandAssetKind(id: String, kind: BrandAssetKind) throws {
        guard prefs.adminModeEnabled, var asset = brandAsset(withID: id), !asset.isManaged, asset.kind != kind else { return }
        asset.kind = kind
        asset.modifiedAt = Date()
        try BrandAssetStore.save(asset)
        reloadBrandAssets()
    }

    /// Removes the library entry. The image file is removed too, but only
    /// when nothing else draws it — a scene that used the asset keeps
    /// working, it just loses the library name.
    func deleteBrandAsset(id: String) throws {
        guard prefs.adminModeEnabled, let asset = brandAsset(withID: id), !asset.isManaged else { return }
        try BrandAssetStore.delete(id: id)
        reloadBrandAssets()
        // Only the store's copy — never the organization folder's original.
        if brandAssetUsage(asset).isEmpty,
           let stored = ScreenSaverSceneStore.assetURL(named: asset.assetName),
           FileManager.default.fileExists(atPath: stored.path) {
            try? FileManager.default.removeItem(at: stored)
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
