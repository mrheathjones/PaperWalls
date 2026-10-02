import SwiftUI

/// Studio (spec §10): the composing plane. It holds no library — what is
/// made here is saved to the ScreenSavers page. One tab per kind of
/// creation; a single visible tab shows without the tab control.
struct StudioPage: View {
    @EnvironmentObject private var model: AppModel

    private var tabs: [StudioTab] { model.visibleStudioTabs }

    /// The selected tab, or the first visible one if the selection's gate
    /// just flipped off.
    private var currentTab: StudioTab? {
        tabs.contains(model.studioTab) ? model.studioTab : tabs.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
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
                    StudioWallpapersTab()
                case .screenSaver:
                    StudioScreenSaverTab()
                case nil:
                    EmptyView()
                }
            }
            .padding(28)
        }
    }
}

// MARK: - Wallpapers tab

/// Placeholder. A future generative wallpaper feature replaces this
/// view's body — the tab, its gate, and its routing already exist.
struct StudioWallpapersTab: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
            Text("Coming Soon")
                .font(.system(size: 22, weight: .bold))
            Text("Create your own wallpapers right here in Studio. This is where wallpaper generation will live.")
                .font(Theme.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 90)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                .strokeBorder(Theme.hairline)
        }
    }
}

// MARK: - ScreenSaver tab

/// "New Screen Saver": start blank or from a built-in preset.
///
/// PHASE 3: the Scene Composer editor is not built yet, so a template is
/// saved straight to the library and an "Edit" request shows a notice.
/// Phase 4 replaces both with the editor.
struct StudioScreenSaverTab: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: PreferencesStore

    @State private var errorMessage: String?
    @State private var savedName: String?

    private let columns = [GridItem(.flexible(), spacing: 20),
                           GridItem(.flexible(), spacing: 20),
                           GridItem(.flexible(), spacing: 20)]

    private struct Template: Identifiable {
        let id: String
        let name: String
        let scene: ScreenSaverScene
    }

    // Built once per view so the paused previews keep stable layer IDs.
    @State private var templates: [Template] =
        [Template(id: "blank", name: "Blank", scene: ScreenSaverScene())]
        + ScreenSaverPreset.allCases.map { Template(id: $0.rawValue, name: $0.displayName, scene: $0.scene) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if case .edit(let sceneID) = model.studioRequest,
               let saver = model.screenSaver(withID: sceneID) {
                editNotice(for: saver)
            }

            SettingsSection(label: "New Screen Saver") {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(templates) { template in
                        templateCard(template)
                    }
                }
            }
        }
        .alert("Couldn’t Save Screen Saver", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Saved to ScreenSavers", isPresented: savedPresented) {
            if prefs.showScreenSaversPage {
                Button("Go to ScreenSavers") {
                    model.studioRequest = nil
                    model.page = .screenSavers
                }
            }
            Button("Stay in Studio", role: .cancel) {}
        } message: {
            Text("“\(savedName ?? "")” is now in your library.")
        }
    }

    private func templateCard(_ template: Template) -> some View {
        ZStack(alignment: .bottom) {
            SaverSceneView(scene: template.scene, resources: model.sceneResources, isPaused: true)
                .allowsHitTesting(false)
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
                SetButton(label: "Add", systemImage: "plus") {
                    add(template)
                }
                .help("Save this to your ScreenSavers library")
            }
            .padding(14)
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(template.name)
    }

    private func editNotice(for saver: StoredScreenSaver) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Editing “\(saver.name)”")
                    .font(.system(size: 15, weight: .semibold))
                Text("The Scene Composer editor isn’t available in this build yet.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Done") {
                model.studioRequest = nil
            }
        }
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                .strokeBorder(Theme.hairline)
        }
    }

    private func add(_ template: Template) {
        do {
            // A fresh copy of the template, so each saved entry gets its
            // own layer IDs.
            let scene = ScreenSaverPreset(rawValue: template.id)?.scene ?? ScreenSaverScene()
            let name = template.id == "blank" ? "Untitled" : template.name
            savedName = try model.saveScreenSaver(name: name, scene: scene).name
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var savedPresented: Binding<Bool> {
        Binding(get: { savedName != nil }, set: { if !$0 { savedName = nil } })
    }
}
