import SwiftUI

/// The Scene Composer (spec §10): live preview on top, the layers list
/// and the selected item's controls below. Edits apply to the draft held
/// by `StudioSession`. In screen-saver mode Save writes the scene to the
/// ScreenSavers library; in wallpaper mode it renders a PNG into the
/// Personal library and keeps the design for later edits.
struct SceneComposer: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: PreferencesStore

    @Binding var draft: SceneDraft
    var kind: SceneComposerKind = .screenSaver
    /// Wallpaper mode: the pixel size the next save renders at.
    var pixelSize: Binding<CGSize>?

    enum Selection: Hashable {
        case background
        case layer(UUID)
    }

    @State private var selection: Selection = .background
    @State private var confirmingDiscard = false
    @State private var errorMessage: String?
    @State private var savedName: String?
    @State private var savedDesign: StoredWallpaperDesign?
    @State private var isSaving = false

    /// The Name field and the Layers list below it share this width.
    private static let sidebarWidth: CGFloat = 300

    var body: some View {
        // Layers sit under the Name field; the preview stays put beside
        // them and only the edit form below it scrolls, so every change
        // is visible as it's made.
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 16) {
                toolbar
                HStack(alignment: .top, spacing: 20) {
                    ScrollView {
                        layersPanel
                            .padding(.bottom, 20)
                    }
                    .frame(width: Self.sidebarWidth)
                    VStack(spacing: 16) {
                        preview
                            .frame(height: min(400, max(180, proxy.size.height * 0.42)))
                            .frame(maxWidth: .infinity)
                        ScrollView {
                            controlsPanel
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(.bottom, 20)
                        }
                    }
                }
            }
        }
        .environment(\.composerKind, kind)
        .environment(\.composerPixelSize, pixelSize?.wrappedValue
                     ?? model.displayPixelSizes.first ?? CGSize(width: 2560, height: 1600))
        .onAppear(perform: selectFrontLayer)
        .onChange(of: draft.sceneID) { _, _ in
            selectFrontLayer()
        }
        .confirmationDialog("Discard your changes to “\(draft.name)”?",
                            isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive, action: close)
            Button("Keep Editing", role: .cancel) {}
        }
        .alert(kind == .wallpaper ? "Couldn’t Save Wallpaper" : "Couldn’t Save Screen Saver",
               isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Saved to ScreenSavers", isPresented: savedPresented) {
            if prefs.showScreenSaversPage {
                Button("Go to ScreenSavers") {
                    model.studio.draft = nil
                    model.page = .screenSavers
                }
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("“\(savedName ?? "")” is in your library.")
        }
        .alert("Saved to Personal", isPresented: savedDesignPresented) {
            if let design = savedDesign, let wallpaper = model.exportedWallpaper(for: design),
               !model.selectionLocked {
                Button("Set as Wallpaper") {
                    model.apply(wallpaper)
                }
            }
            Button("Show in Personal") {
                model.studio.wallpaperDraft = nil
                model.page = .personal
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("“\(savedDesign?.exportedFilename ?? "")” is in your Personal wallpapers.")
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("", text: $draft.name, prompt: Text("Name"))
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(width: Self.sidebarWidth)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                        .strokeBorder(Theme.hairline)
                }
                .accessibilityLabel(kind == .wallpaper ? "Wallpaper name" : "Screen saver name")
            if draft.isDirty || sizeChanged {
                CapsuleBadge(text: "Unsaved changes", systemImage: "pencil")
            }
            Spacer(minLength: 12)
            if kind == .wallpaper, let pixelSize {
                sizeMenu(pixelSize)
            }
            Button {
                ScenePreviewPresenter.show(scene: draft.scene, resources: model.sceneResources,
                                           title: draft.name, fullscreen: true)
            } label: {
                Label(kind == .wallpaper ? "Preview Fullscreen" : "Test Fullscreen", systemImage: "play.fill")
            }
            .help(kind == .wallpaper
                  ? "Show this wallpaper fullscreen — any key or click exits"
                  : "Run this scene fullscreen — any key or click exits")
            Button(draft.resetLabel) {
                draft.reset()
                selectFrontLayer()
            }
            .disabled(!draft.isDirty)
            Button("Cancel") {
                if draft.isDirty {
                    confirmingDiscard = true
                } else {
                    close()
                }
            }
            if isSaving {
                ProgressView()
                    .controlSize(.small)
            }
            Button(kind == .wallpaper ? "Save to Personal" : "Save", action: save)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(!canSave || isSaving)
                .keyboardShortcut("s", modifiers: .command)
        }
    }

    /// Wallpaper mode: the render size isn't part of the scene, but
    /// changing it is a reason to save again.
    private var sizeChanged: Bool {
        guard kind == .wallpaper, let pixelSize, let id = draft.sceneID,
              let design = model.wallpaperDesign(withID: id) else { return false }
        return design.pixelSize != pixelSize.wrappedValue
    }

    private var canSave: Bool {
        draft.canSave || (sizeChanged && !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func sizeMenu(_ pixelSize: Binding<CGSize>) -> some View {
        Menu {
            ForEach(WallpaperRenderSize.options(displayPixelSizes: model.displayPixelSizes)) { option in
                Button {
                    pixelSize.wrappedValue = option.pixelSize
                } label: {
                    if option.pixelSize == pixelSize.wrappedValue {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            Label(WallpaperRenderSize.label(for: pixelSize.wrappedValue), systemImage: "aspectratio")
        }
        .fixedSize()
        .help("The pixel size the wallpaper is saved at")
        .accessibilityLabel("Wallpaper size")
    }

    private var previewAspect: CGFloat {
        if kind == .wallpaper, let size = pixelSize?.wrappedValue, size.width > 0, size.height > 0 {
            return size.width / size.height
        }
        return 16.0 / 10.0
    }

    private var preview: some View {
        VStack(spacing: 6) {
            InteractiveScenePreview(scene: $draft.scene, resources: model.sceneResources)
                .aspectRatio(previewAspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                        .strokeBorder(Theme.hairline)
                }
                .accessibilityLabel("Live preview")
            Text("Drag a layer to move it · drag the picture to pan · scroll or pinch to zoom")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Layers

    private var layersPanel: some View {
        ComposerSection(title: "Layers") {
            // Front-most first, like every layers list; the background
            // is always at the bottom.
            ForEach(draft.scene.layers.reversed()) { layer in
                layerRow(layer)
                SettingsDivider()
            }
            row(isSelected: selection == .background,
                systemImage: "photo", title: "Background") {
                selection = .background
            } trailing: {
                EmptyView()
            }
            SettingsDivider()
            HStack(spacing: 8) {
                Menu {
                    if kind == .screenSaver {
                        Button("Clock") { add(.clock()) }
                    }
                    Button("Text") { add(.text(kind == .wallpaper ? "Your text here" : "Be right back")) }
                    Button("Icon") { add(.icon()) }
                } label: {
                    Label("Add Layer", systemImage: "plus")
                }
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func layerRow(_ layer: SceneLayer) -> some View {
        let index = draft.scene.layers.firstIndex { $0.id == layer.id } ?? 0
        return row(isSelected: selection == .layer(layer.id),
                   systemImage: icon(for: layer), title: title(for: layer),
                   dimmed: !layer.isVisible) {
            selection = .layer(layer.id)
        } trailing: {
            rowIcon(layer.isVisible ? "eye" : "eye.slash", help: layer.isVisible ? "Hide" : "Show") {
                draft.scene.layers[index].isVisible.toggle()
            }
            rowIcon("chevron.up", help: "Bring forward",
                    disabled: index >= draft.scene.layers.count - 1) {
                draft.scene.layers.swapAt(index, index + 1)
            }
            rowIcon("chevron.down", help: "Send backward", disabled: index == 0) {
                draft.scene.layers.swapAt(index, index - 1)
            }
            rowIcon("trash", help: "Delete layer") {
                draft.scene.layers.remove(at: index)
                if selection == .layer(layer.id) {
                    selectFrontLayer()
                }
            }
        }
    }

    /// One list row: a real button selects it (so keyboard and
    /// assistive tech can too), with the row's own controls beside it.
    private func row<Trailing: View>(isSelected: Bool,
                                     systemImage: String,
                                     title: String,
                                     dimmed: Bool = false,
                                     select: @escaping () -> Void,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Button(action: select) {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .frame(width: 20)
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .opacity(dimmed ? 0.45 : 1)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.selectedRow)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func rowIcon(_ systemImage: String, help: String, disabled: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(help)
        .accessibilityLabel(help)
    }

    private func icon(for layer: SceneLayer) -> String {
        switch layer.content {
        case .clock: return "clock"
        case .text: return "textformat"
        case .icon: return "star"
        case .unsupported: return "questionmark.square.dashed"
        }
    }

    /// Text layers are named by what they say.
    private func title(for layer: SceneLayer) -> String {
        guard case .text(let text) = layer.content else { return layer.content.displayName }
        let preview = text.segments.map { segment -> String in
            switch segment {
            case .text(let string): return string
            case .token(let token): return "[\(token.displayName)]"
            }
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.isEmpty ? "Text" : preview
    }

    // MARK: - Controls

    @ViewBuilder
    private var controlsPanel: some View {
        switch selection {
        case .background:
            SceneBackgroundControls(background: $draft.scene.background)
        case .layer(let id):
            if let index = draft.scene.layers.firstIndex(where: { $0.id == id }) {
                SceneLayerControls(layer: $draft.scene.layers[index])
                    .id(id)
            } else {
                SceneBackgroundControls(background: $draft.scene.background)
            }
        }
    }

    // MARK: - Actions

    private func add(_ layer: SceneLayer) {
        draft.scene.layers.append(layer)
        selection = .layer(layer.id)
    }

    private func selectFrontLayer() {
        selection = draft.scene.layers.last.map { .layer($0.id) } ?? .background
    }

    private func save() {
        switch kind {
        case .screenSaver:
            do {
                savedName = try model.saveStudioDraft()?.name
            } catch {
                errorMessage = error.localizedDescription
            }
        case .wallpaper:
            isSaving = true
            Task { @MainActor in
                defer { isSaving = false }
                do {
                    savedDesign = try await model.saveWallpaperDraft()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Leaves the composer. A screen saver opened from the library returns
    /// there; anything else returns to its tab's "New …" chooser.
    private func close() {
        switch kind {
        case .screenSaver:
            let cameFromLibrary = !draft.isNew
            model.studio.draft = nil
            if cameFromLibrary && prefs.showScreenSaversPage {
                model.page = .screenSavers
            }
        case .wallpaper:
            model.studio.wallpaperDraft = nil
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var savedPresented: Binding<Bool> {
        Binding(get: { savedName != nil }, set: { if !$0 { savedName = nil } })
    }

    private var savedDesignPresented: Binding<Bool> {
        Binding(get: { savedDesign != nil }, set: { if !$0 { savedDesign = nil } })
    }
}
