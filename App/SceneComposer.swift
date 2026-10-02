import SwiftUI

/// The Scene Composer (spec §10): live preview on top, the layers list
/// and the selected item's controls below. Edits apply to the draft held
/// by `StudioSession`; Save writes it to the ScreenSavers library.
struct SceneComposer: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: PreferencesStore

    @Binding var draft: SceneDraft

    enum Selection: Hashable {
        case background
        case layer(UUID)
    }

    @State private var selection: Selection = .background
    @State private var confirmingDiscard = false
    @State private var errorMessage: String?
    @State private var savedName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            toolbar
            preview
            HStack(alignment: .top, spacing: 20) {
                layersPanel
                    .frame(width: 300)
                controlsPanel
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .onAppear(perform: selectFrontLayer)
        .onChange(of: draft.sceneID) { _, _ in
            selectFrontLayer()
        }
        .confirmationDialog("Discard your changes to “\(draft.name)”?",
                            isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive, action: close)
            Button("Keep Editing", role: .cancel) {}
        }
        .alert("Couldn’t Save Screen Saver", isPresented: errorPresented) {
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
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("", text: $draft.name, prompt: Text("Name"))
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(width: 280)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                        .strokeBorder(Theme.hairline)
                }
                .accessibilityLabel("Screen saver name")
            if draft.isDirty {
                CapsuleBadge(text: "Unsaved changes", systemImage: "pencil")
            }
            Spacer(minLength: 12)
            Button {
                ScenePreviewPresenter.show(scene: draft.scene, resources: model.sceneResources,
                                           title: draft.name, fullscreen: true)
            } label: {
                Label("Test Fullscreen", systemImage: "play.fill")
            }
            .help("Run this scene fullscreen — any key or click exits")
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
            Button("Save", action: save)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(!draft.canSave)
                .keyboardShortcut("s", modifiers: .command)
        }
    }

    private var preview: some View {
        SaverSceneView(scene: draft.scene, resources: model.sceneResources)
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            // Cap the width (not the height) so the 16:10 shape holds.
            .frame(maxWidth: 640)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.hairline)
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Live preview")
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
                    Button("Clock") { add(.clock()) }
                    Button("Text") { add(.text()) }
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
        do {
            savedName = try model.saveStudioDraft()?.name
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Leaves the composer. A scene opened from the library returns there;
    /// a new one returns to the "New Screen Saver" chooser.
    private func close() {
        let cameFromLibrary = !draft.isNew
        model.studio.draft = nil
        if cameFromLibrary && prefs.showScreenSaversPage {
            model.page = .screenSavers
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var savedPresented: Binding<Bool> {
        Binding(get: { savedName != nil }, set: { if !$0 { savedName = nil } })
    }
}
