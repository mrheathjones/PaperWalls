import SwiftUI

/// Studio (spec §10): the composing plane. It holds no library — what is
/// made here is saved to the ScreenSavers page or the Personal wallpaper
/// library. One tab per kind of creation; a single visible tab shows
/// without the tab control.
struct StudioPage: View {
    @EnvironmentObject private var model: AppModel

    @ObservedObject var studio: StudioSession

    private var tabs: [StudioTab] { model.visibleStudioTabs }

    /// The selected tab, or the first visible one if the selection's gate
    /// just flipped off.
    private var currentTab: StudioTab? {
        tabs.contains(model.studioTab) ? model.studioTab : tabs.first
    }

    /// While composing, the page itself doesn't scroll — the composer pins
    /// its preview and scrolls only the edit form.
    private var isComposing: Bool {
        switch currentTab {
        case .screenSaver: return studio.draft != nil
        case .wallpapers: return studio.wallpaperDraft != nil
        case .assets, .package, nil: return false
        }
    }

    var body: some View {
        if isComposing {
            content
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                content
                    .padding(28)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: isComposing ? 16 : 24) {
            PageHeader(title: "Studio",
                       subtitle: "Compose your own wallpapers and screen savers") {
            } trailing: {
                if tabs.count > 1 {
                    SegmentedPills(options: tabs.map { ($0.displayName, $0) },
                                   selection: $model.studioTab)
                }
            }

            switch currentTab {
            case .wallpapers:
                StudioWallpapersTab(studio: studio)
            case .screenSaver:
                StudioScreenSaverTab(studio: studio)
            case .assets:
                StudioAssetsTab()
            case .package:
                StudioPackageTab(studio: studio)
            case nil:
                EmptyView()
            }
        }
    }
}

// MARK: - ScreenSaver tab

/// The composing plane for screen savers: the "New Screen Saver" chooser
/// (blank, a built-in preset, or — with AI generation on — a description
/// for Claude) until something is being composed, then the Scene Composer.
struct StudioScreenSaverTab: View {
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
    // Presets are read-only templates — nothing reaches the library until
    // the user saves from the composer.
    @State private var templates: [Template] =
        [Template(id: "blank", name: "Blank", scene: ScreenSaverScene())]
        + ScreenSaverPreset.allCases.map { Template(id: $0.rawValue, name: $0.displayName, scene: $0.scene) }

    var body: some View {
        Group {
            if studio.draft != nil {
                SceneComposer(draft: draftBinding)
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    if prefs.aiPolicy.offersSceneComposition {
                        AISceneComposer { draft in
                            studio.draft = draft
                        }
                    }
                    SettingsSection(label: "New Screen Saver") {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(templates) { template in
                                templateCard(template)
                            }
                        }
                    }
                }
            }
        }
        // "Edit" on another screen saver arrived while this draft has
        // unsaved changes.
        .confirmationDialog("Discard your changes to “\(studio.draft?.name ?? "")”?",
                            isPresented: pendingPresented, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) {
                if let request = studio.pendingRequest {
                    model.applyStudioRequest(request)
                }
            }
            Button("Keep Editing", role: .cancel) {
                studio.pendingRequest = nil
            }
        }
    }

    /// Non-optional view of the draft for the composer. Writes after the
    /// draft is closed (a late text-field commit) are dropped rather than
    /// resurrecting it.
    private var draftBinding: Binding<SceneDraft> {
        Binding(
            get: { studio.draft ?? SceneDraft(newNamed: "", scene: ScreenSaverScene()) },
            set: { newValue in
                if studio.draft != nil {
                    studio.draft = newValue
                }
            })
    }

    private var pendingPresented: Binding<Bool> {
        Binding(get: { studio.pendingRequest != nil },
                set: { if !$0 { studio.pendingRequest = nil } })
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
        // A fresh copy of the template, so every draft gets its own
        // layer IDs.
        let scene = ScreenSaverPreset(rawValue: template.id)?.scene ?? ScreenSaverScene()
        let name = ScreenSaverSceneStore.uniqueName(template.isPreset ? template.name : "Untitled",
                                                    existing: model.allScreenSavers.map(\.name))
        studio.draft = SceneDraft(newNamed: name, scene: scene,
                                  presetName: template.isPreset ? template.name : nil)
    }
}
