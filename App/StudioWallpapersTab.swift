import AppKit
import SwiftUI

/// Studio › Wallpapers: the "New Wallpaper" chooser (blank or a preset)
/// and the user's saved designs until something is being composed, then
/// the Scene Composer in wallpaper mode. Saving renders a PNG into the
/// Personal library; the design stays here, re-editable.
struct StudioWallpapersTab: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: PreferencesStore

    @ObservedObject var studio: StudioSession

    private let columns = [GridItem(.flexible(), spacing: 20),
                           GridItem(.flexible(), spacing: 20),
                           GridItem(.flexible(), spacing: 20)]

    private struct Template: Identifiable {
        let id: String
        let name: String
        let scene: ScreenSaverScene
        var isPreset: Bool { id != "blank" }
    }

    // Built once per view so the paused previews keep stable layer IDs.
    @State private var templates: [Template] =
        [Template(id: "blank", name: "Blank", scene: WallpaperPreset.blankScene)]
        + WallpaperPreset.allCases.map { Template(id: $0.rawValue, name: $0.displayName, scene: $0.scene) }

    /// "Edit" on a design arrived while the draft has unsaved changes.
    @State private var pendingDesign: StoredWallpaperDesign?
    @State private var renaming: StoredWallpaperDesign?
    @State private var renameText = ""
    @State private var deleting: StoredWallpaperDesign?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if studio.wallpaperDraft != nil {
                SceneComposer(draft: draftBinding, kind: .wallpaper, pixelSize: $studio.wallpaperPixelSize)
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    SettingsSection(label: "New Wallpaper") {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(templates) { template in
                                templateCard(template)
                            }
                        }
                    }
                    if !model.wallpaperDesigns.isEmpty {
                        SettingsSection(label: "Your Designs") {
                            LazyVGrid(columns: columns, spacing: 20) {
                                ForEach(model.wallpaperDesigns) { design in
                                    WallpaperDesignCard(design: design,
                                                        onEdit: { edit(design) },
                                                        onRename: {
                                                            renameText = design.name
                                                            renaming = design
                                                        },
                                                        onDelete: { deleting = design })
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            studio.ensureWallpaperPixelSize(displayPixelSizes: model.displayPixelSizes)
        }
        .confirmationDialog("Discard your changes to “\(studio.wallpaperDraft?.name ?? "")”?",
                            isPresented: pendingPresented, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) {
                if let design = pendingDesign {
                    model.openWallpaperDesign(design)
                }
                pendingDesign = nil
            }
            Button("Keep Editing", role: .cancel) {
                pendingDesign = nil
            }
        }
        .alert("Rename Design", isPresented: renamePresented) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let design = renaming {
                    perform { try model.renameWallpaperDesign(id: design.id, to: renameText) }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) {
                renaming = nil
            }
        } message: {
            Text("The wallpaper image already saved keeps its file name.")
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?",
                            isPresented: deletePresented, titleVisibility: .visible) {
            if let design = deleting {
                Button("Delete Design", role: .destructive) {
                    perform { try model.deleteWallpaperDesign(id: design.id, removingImage: false) }
                    deleting = nil
                }
                if model.exportedImageURL(for: design) != nil {
                    Button("Delete Design and Wallpaper Image", role: .destructive) {
                        perform { try model.deleteWallpaperDesign(id: design.id, removingImage: true) }
                        deleting = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                deleting = nil
            }
        } message: {
            Text(deleting.flatMap { model.exportedImageURL(for: $0) } == nil
                 ? "This can't be undone."
                 : "Deleting only the design keeps its wallpaper image in your Personal library.")
        }
        .alert("Something Went Wrong", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// Non-optional view of the draft for the composer. Writes after the
    /// draft is closed (a late text-field commit) are dropped.
    private var draftBinding: Binding<SceneDraft> {
        Binding(
            get: { studio.wallpaperDraft ?? SceneDraft(newNamed: "", scene: WallpaperPreset.blankScene) },
            set: { newValue in
                if studio.wallpaperDraft != nil {
                    studio.wallpaperDraft = newValue
                }
            })
    }

    private func templateCard(_ template: Template) -> some View {
        Button {
            start(template)
        } label: {
            ZStack(alignment: .bottom) {
                SaverSceneView(scene: template.scene, resources: model.sceneResources, isPaused: true)
                LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0),
                                       .init(color: .clear, location: 0.6)],
                               startPoint: .bottom, endPoint: .top)
                HStack(spacing: 10) {
                    Text(template.name)
                        .font(Theme.cardName)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.4), radius: 3)
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 3)
                }
                .padding(14)
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Start from \(template.name)")
        .accessibilityLabel("Start from \(template.name)")
    }

    private func start(_ template: Template) {
        // A fresh copy of the template, so every draft gets its own layer IDs.
        let scene = WallpaperPreset(rawValue: template.id)?.scene ?? WallpaperPreset.blankScene
        let name = WallpaperDesignStore.uniqueName(template.isPreset ? template.name : "Untitled",
                                                   existing: model.wallpaperDesigns.map(\.name))
        studio.ensureWallpaperPixelSize(displayPixelSizes: model.displayPixelSizes)
        studio.wallpaperDraft = SceneDraft(newNamed: name, scene: scene,
                                           presetName: template.isPreset ? template.name : nil)
    }

    private func edit(_ design: StoredWallpaperDesign) {
        if let draft = studio.wallpaperDraft, draft.isDirty, draft.sceneID != design.id {
            pendingDesign = design
        } else {
            model.openWallpaperDesign(design)
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var pendingPresented: Binding<Bool> {
        Binding(get: { pendingDesign != nil }, set: { if !$0 { pendingDesign = nil } })
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}

// MARK: - Design card

/// A saved design, styled like the library cards: thumbnail, name, when
/// it was edited, an actions menu, and "Edit". Clicking the card edits.
struct WallpaperDesignCard: View {
    @EnvironmentObject private var model: AppModel

    let design: StoredWallpaperDesign
    let onEdit: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    private var exportedWallpaper: CuratedWallpaper? { model.exportedWallpaper(for: design) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            thumbnail
            LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0),
                                   .init(color: .clear, location: 0.55)],
                           startPoint: .bottom, endPoint: .top)
            if let wallpaper = exportedWallpaper, model.isCurrent(wallpaper) {
                ActiveBadge()
                    .padding(12)
            }
            VStack {
                Spacer()
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(design.name)
                            .font(Theme.cardName)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(Theme.caption)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    Spacer(minLength: 8)
                    actionsMenu
                    SetButton(label: "Edit", action: onEdit)
                }
                .padding(14)
            }
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .onTapGesture(perform: onEdit)
        .contextMenu { menuItems }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(design.name)
        .accessibilityHint("Edits the wallpaper design")
    }

    private var subtitle: String {
        "\(WallpaperRenderSize.label(for: design.pixelSize)) · Edited \(design.modifiedAt.formatted(.relative(presentation: .named)))"
    }

    private var thumbnail: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle().fill(.quaternary)
                if let image = model.wallpaperDesignThumbnails[design.id] {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        // Decorative — the card owns all interaction (see WallpaperThumbnail).
        .allowsHitTesting(false)
    }

    private var actionsMenu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.6))
                .frame(width: 34, height: 34)
                .background(.white, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Actions for \(design.name)")
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Edit", action: onEdit)
        Button("Rename…", action: onRename)
        if let wallpaper = exportedWallpaper {
            Divider()
            Button("Set as Wallpaper") {
                model.apply(wallpaper)
            }
            .disabled(model.selectionLocked || model.isCurrent(wallpaper))
        }
        if model.exportedImageURL(for: design) != nil {
            Button("Reveal Image in Finder") {
                model.revealExportedImage(for: design)
            }
        }
        Divider()
        Button("Delete…", role: .destructive, action: onDelete)
    }
}
