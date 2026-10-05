import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Studio › Assets (admin mode): the organization's logos and icons.
/// Anything added here — or deployed to the folder `brandAssetsFolderPath`
/// names — shows up as a "Brand Assets" strip in the Scene Composer's Icon
/// and Background controls, so scenes can use the right variation (light,
/// dark, mono, square…) without hunting for files.
struct StudioAssetsTab: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: PreferencesStore

    @State private var filter: BrandAssetKind?
    @State private var isDropTargeted = false
    @State private var renaming: BrandAsset?
    @State private var renameText = ""
    @State private var deleting: BrandAsset?
    @State private var importSummary: String?
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 20)]

    private var filtered: [BrandAsset] {
        guard let filter else { return model.brandAssets }
        return model.brandAssets.filter { $0.kind == filter }
    }

    /// The organization's assets not already in the user's library.
    private var managed: [BrandAsset] {
        let taken = Set(model.brandAssets.map(\.assetName))
        let visible = model.managedBrandAssets.assets.filter { !taken.contains($0.assetName) }
        guard let filter else { return visible }
        return visible.filter { $0.kind == filter }
    }

    private var managedFolderPath: String {
        prefs.brandAssetsFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsFilter: Bool {
        !model.brandAssets.isEmpty || !model.managedBrandAssets.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsSection(label: "Brand assets") {
                SettingsCard {
                    SettingsRow(title: "Add images",
                                subtitle: "Logos, icons, and other artwork for screen savers and wallpapers. Keep every variation you need — light and dark, mono, square. PNG with transparency works best. You can also drop files or a folder anywhere on this tab") {
                        Button("Add Images…", action: chooseImages)
                    }
                }
            }

            if showsFilter {
                SegmentedPills(options: filterOptions, selection: $filter)
            }

            SettingsSection(label: libraryLabel) {
                if model.brandAssets.isEmpty && !model.managedBrandAssets.isEmpty {
                    // The organization's assets are the main event below;
                    // keep the empty library to one line.
                    SettingsCard {
                        SettingsRow(title: "Nothing of your own yet",
                                    subtitle: "Add images above, or choose Add to My Library on an organization asset to get an editable copy") {
                            EmptyView()
                        }
                    }
                } else if model.brandAssets.isEmpty {
                    SettingsCard {
                        EmptyStateView(systemImage: "seal",
                                       title: "No brand assets yet",
                                       message: "Add your organization's logos and icons here. They appear as Brand Assets in the composer's Icon and Background sections.",
                                       actionLabel: "Add Images…",
                                       action: chooseImages)
                    }
                } else if filtered.isEmpty {
                    EmptyStateView(systemImage: "line.3.horizontal.decrease.circle",
                                   title: "No \(filter?.pluralName.lowercased() ?? "assets") yet",
                                   message: "Change an asset's kind from its menu, or add more images.")
                } else {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(filtered) { asset in
                            BrandAssetCard(asset: asset,
                                           onRename: {
                                               renameText = asset.name
                                               renaming = asset
                                           },
                                           onDelete: { deleting = asset },
                                           onAddToLibrary: nil)
                        }
                    }
                }
            }

            if !managedFolderPath.isEmpty {
                SettingsSection(label: "Organization assets") {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 8) {
                            ManagedBadge()
                            Text(managedFolderPath)
                                .font(Theme.pathMono)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if model.managedBrandAssets.isEmpty {
                            SettingsCard {
                                EmptyStateView(systemImage: "folder.badge.questionmark",
                                               title: "No images in the managed folder",
                                               message: "The folder is missing, unreadable, or has no PNG, JPEG, HEIC, TIFF, or GIF files. It's checked again each time PaperWalls becomes active.")
                            }
                        } else if managed.isEmpty {
                            EmptyStateView(systemImage: "line.3.horizontal.decrease.circle",
                                           title: filter == nil ? "All managed assets are in your library" : "No managed \(filter?.pluralName.lowercased() ?? "")",
                                           message: filter == nil
                                               ? "Each one already has a copy under Library, so it's listed there."
                                               : "Managed assets are sorted by their file names.")
                        } else {
                            LazyVGrid(columns: columns, spacing: 20) {
                                ForEach(managed) { asset in
                                    BrandAssetCard(asset: asset,
                                                   onRename: {},
                                                   onDelete: {},
                                                   onAddToLibrary: {
                                                       perform { try model.addManagedBrandAssetToLibrary(asset) }
                                                   })
                                }
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                    .padding(-12)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
        } isTargeted: { targeting in
            isDropTargeted = targeting
        }
        .alert("Rename Asset", isPresented: renamePresented) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let asset = renaming {
                    perform { try model.renameBrandAsset(id: asset.id, to: renameText) }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) {
                renaming = nil
            }
        } message: {
            Text("Scenes already using this image aren't affected.")
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?",
                            isPresented: deletePresented, titleVisibility: .visible) {
            if let asset = deleting {
                Button("Delete Asset", role: .destructive) {
                    perform { try model.deleteBrandAsset(id: asset.id) }
                    deleting = nil
                }
            }
            Button("Cancel", role: .cancel) {
                deleting = nil
            }
        } message: {
            Text(deleteMessage)
        }
        .alert("Images Added", isPresented: summaryPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importSummary ?? "")
        }
        .alert("Something Went Wrong", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var filterOptions: [(label: String, value: BrandAssetKind?)] {
        var options: [(label: String, value: BrandAssetKind?)] = [(label: "All", value: nil)]
        for kind in BrandAssetKind.allCases {
            options.append((label: kind.pluralName, value: kind))
        }
        return options
    }

    private var libraryLabel: String {
        let count = model.brandAssets.count
        return count == 0 ? "Library" : "Library · \(count) \(count == 1 ? "asset" : "assets")"
    }

    private var deleteMessage: String {
        guard let asset = deleting else { return "" }
        let usage = model.brandAssetUsage(asset)
        var parts: [String] = []
        if usage.screenSavers > 0 {
            parts.append("\(usage.screenSavers) screen saver\(usage.screenSavers == 1 ? "" : "s")")
        }
        if usage.wallpaperDesigns > 0 {
            parts.append("\(usage.wallpaperDesigns) wallpaper design\(usage.wallpaperDesigns == 1 ? "" : "s")")
        }
        if usage.inOpenDraft {
            parts.append("the scene you're composing")
        }
        let stillManaged = model.managedBrandAssets.sources[asset.assetName] != nil
        if parts.isEmpty {
            return stillManaged
                ? "Your copy is removed. The image stays available from your organization's folder."
                : "The image is removed from your Mac. This can't be undone."
        }
        return "Used by \(parts.joined(separator: " and ")). They keep the image; it just leaves the library."
    }

    // MARK: - Adding

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .folder]
        panel.prompt = "Add"
        panel.message = "Choose logo and icon images, or a folder of them."
        guard panel.runModal() == .OK else { return }
        _ = add(panel.urls)
    }

    /// Files are added as they are; a folder contributes its image files
    /// (one level deep, so a dropped "Brand" folder just works).
    @discardableResult
    private func add(_ urls: [URL]) -> Bool {
        let files = StudioAssetsTab.imageFiles(in: urls)
        guard !files.isEmpty else { return false }
        let result = model.addBrandAssets(from: files)
        var lines: [String] = []
        if !result.added.isEmpty {
            lines.append("Added \(result.added.count) image\(result.added.count == 1 ? "" : "s").")
        }
        if !result.duplicates.isEmpty {
            lines.append("Already in the library: \(result.duplicates.joined(separator: ", ")).")
        }
        if !result.rejected.isEmpty {
            lines.append("Couldn't add \(result.rejected.joined(separator: ", ")) — choose PNG, JPEG, HEIC, TIFF, or GIF images.")
        }
        // Silent on the plain success path; the grid is the confirmation.
        if !result.duplicates.isEmpty || !result.rejected.isEmpty {
            importSummary = lines.joined(separator: " ")
        }
        return true
    }

    static func imageFiles(in urls: [URL]) -> [URL] {
        let fileManager = FileManager.default
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let children = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                     options: [.skipsHiddenFiles])) ?? []
                files += children
                    .filter { ScreenSaverSceneStore.assetExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else {
                files.append(url)
            }
        }
        return files
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var summaryPresented: Binding<Bool> {
        Binding(get: { importSummary != nil }, set: { if !$0 { importSummary = nil } })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}

// MARK: - Card

struct BrandAssetCard: View {
    @EnvironmentObject private var model: AppModel

    let asset: BrandAsset
    let onRename: () -> Void
    let onDelete: () -> Void
    /// Managed (read-only) assets offer this instead of rename/delete.
    var onAddToLibrary: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            BrandAssetImage(url: model.brandAssetURL(asset), maxPixelSize: 600)
                .padding(22)
                .frame(maxWidth: .infinity)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .background(BrandAssetBackdrop())
            Divider()
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(asset.name)
                        .font(Theme.cardName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(asset.isManaged ? "\(asset.kind.displayName) · Managed" : asset.kind.displayName)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                actionsMenu
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.hairline)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .contextMenu { menuItems }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(asset.name), \(asset.kind.displayName)\(asset.isManaged ? ", managed" : "")")
    }

    private var actionsMenu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Theme.chipFill, in: Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Actions for \(asset.name)")
    }

    @ViewBuilder
    private var menuItems: some View {
        if asset.isManaged {
            if let onAddToLibrary {
                Button("Add to My Library", action: onAddToLibrary)
            }
            Button("Reveal in Finder") {
                model.revealBrandAsset(asset)
            }
        } else {
            Button("Rename…", action: onRename)
            Picker("Kind", selection: Binding(
                get: { asset.kind },
                set: { try? model.setBrandAssetKind(id: asset.id, kind: $0) })) {
                ForEach(BrandAssetKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            Button("Reveal in Finder") {
                model.revealBrandAsset(asset)
            }
            Divider()
            Button("Delete…", role: .destructive, action: onDelete)
        }
    }
}

/// Mid-gray checkerboard, the same in both themes: a white-on-transparent
/// logo and a dark one both stay visible (a light checker hides the white
/// variants, which are the ones made for dark backgrounds).
struct BrandAssetBackdrop: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 12
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = (row % 2 == 0) ? 0 : step
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: y, width: step, height: step)),
                                 with: .color(Color(white: 0.56)))
                    x += step * 2
                }
                y += step
                row += 1
            }
        }
        .background(Color(white: 0.64))
    }
}

/// An asset shown whole (aspect fit), unlike `WallpaperThumbnail`, which
/// fills. Decorative — the container owns interaction.
struct BrandAssetImage: View {
    let url: URL?
    var maxPixelSize: Int = 400

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            image = await ThumbnailLoader.loadThumbnail(for: url, maxPixelSize: maxPixelSize)
        }
    }
}

// MARK: - Composer picker

/// The "Brand Assets" strip inside the composer: the user's library plus
/// the organization's folder, selectable in one click. Shown only when
/// there is something to show. Selecting hands back the name a scene
/// refers to the image by (a managed image is copied into the Studio
/// asset store first).
struct BrandAssetPicker: View {
    @EnvironmentObject private var model: AppModel

    /// The scene's current image, to mark the matching asset.
    let selectedAssetName: String?
    let onSelect: (String) -> Void

    var body: some View {
        let assets = model.allBrandAssets
        if !assets.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(assets) { asset in
                        Button {
                            if let assetName = model.useBrandAsset(asset) {
                                onSelect(assetName)
                            }
                        } label: {
                            BrandAssetImage(url: model.brandAssetURL(asset), maxPixelSize: 240)
                                .padding(8)
                                .frame(width: 88, height: 66)
                                .background(BrandAssetBackdrop())
                                .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                                        .strokeBorder(asset.assetName == selectedAssetName ? Theme.accent : Theme.hairline,
                                                      lineWidth: asset.assetName == selectedAssetName ? 3 : 1)
                                }
                                .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("\(asset.name) · \(asset.kind.displayName)\(asset.isManaged ? " · Managed" : "")")
                        .accessibilityLabel(asset.name)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .frame(height: 90)
        }
    }
}
