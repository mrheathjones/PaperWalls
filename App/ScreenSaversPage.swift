import SwiftUI

/// The screen saver library (spec §10): every saved scene plus the
/// admin-provisioned one. Browse, preview, and Set Active always work
/// here — even with Studio hidden or creation disabled.
struct ScreenSaversPage: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: PreferencesStore

    enum SortOrder: String, CaseIterable, Identifiable {
        case modified
        case name

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .modified: return "Recently Modified"
            case .name: return "Name"
            }
        }
    }

    @State private var sortOrder: SortOrder = .modified
    @State private var renaming: StoredScreenSaver?
    @State private var renameText = ""
    @State private var deleting: StoredScreenSaver?
    @State private var errorMessage: String?

    private var columns: [GridItem] { prefs.wallpaperGridColumns }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "ScreenSavers",
                           subtitle: "\(savers.count) screen saver\(savers.count == 1 ? "" : "s")") {
                    if !prefs.screenSaverEnabled {
                        CapsuleBadge(text: "Turned off", systemImage: "moon.zzz.fill")
                    }
                } trailing: {
                    HStack(spacing: 10) {
                        if model.canOpenComposer {
                            Button {
                                model.openStudio(.new)
                            } label: {
                                Label("New", systemImage: "plus")
                            }
                        }
                        Picker("Sort", selection: $sortOrder) {
                            ForEach(SortOrder.allCases) { order in
                                Text(order.displayName).tag(order)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        GridDensityPicker()
                    }
                }

                if model.allScreenSavers.isEmpty {
                    emptyState
                } else if savers.isEmpty {
                    EmptyStateView(systemImage: "magnifyingglass",
                                   title: "No Matches",
                                   message: "No screen saver matches “\(model.searchText)”.")
                } else {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(savers) { saver in
                            ScreenSaverCard(saver: saver,
                                            onRename: {
                                                renameText = saver.name
                                                renaming = saver
                                            },
                                            onDuplicate: { perform { try model.duplicateScreenSaver(saver) } },
                                            onDelete: { deleting = saver })
                        }
                    }
                }
            }
            .padding(28)
        }
        .alert("Rename Screen Saver", isPresented: renamePresented) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let renaming {
                    perform { try model.renameScreenSaver(id: renaming.id, to: renameText) }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?",
                            isPresented: deletePresented, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let deleting {
                    perform { try model.deleteScreenSaver(id: deleting.id) }
                }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("This screen saver will be permanently removed from your library.")
        }
        .alert("Couldn’t Update Screen Saver", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            // Desktop-picture backgrounds may have changed since last time.
            model.reloadScreenSavers()
        }
    }

    // MARK: - Content

    /// Managed entry first, then the user's scenes in the chosen order.
    private var savers: [StoredScreenSaver] {
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        let matching = model.allScreenSavers.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
        }
        let managed = matching.filter(\.isManaged)
        let personal = matching.filter { !$0.isManaged }
        switch sortOrder {
        case .modified:
            return managed + personal.sorted { $0.modifiedAt > $1.modifiedAt }
        case .name:
            return managed + personal.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.canOpenComposer {
            EmptyStateView(systemImage: "sparkles.tv",
                           title: "No Screen Savers Yet",
                           message: "Compose one in Studio — start from a preset like Bouncing Clock, or from a blank scene.",
                           actionLabel: "Create in Studio",
                           action: { model.openStudio(.new) })
        } else {
            EmptyStateView(systemImage: "sparkles.tv",
                           title: "No Screen Savers",
                           message: "There are no screen savers to show. Your organization hasn't provided one, and creating them is turned off.")
        }
    }

    // MARK: - Plumbing

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

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}

// MARK: - Card

/// Library card, styled like `WallpaperCard`: thumbnail, ACTIVE badge,
/// name, an actions menu, and "Set Active". Clicking the card previews
/// the scene fullscreen.
struct ScreenSaverCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: PreferencesStore

    let saver: StoredScreenSaver
    let onRename: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    private var policy: ScreenSaverPolicy { model.screenSaverPolicy }
    private var isActive: Bool { model.activeScreenSaverID == saver.id }
    /// The user's own scenes are editable while creation is allowed.
    private var canModify: Bool { !saver.isManaged && policy.canCreate }

    var body: some View {
        ZStack(alignment: .topLeading) {
            thumbnail
            LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0),
                                   .init(color: .clear, location: 0.55)],
                           startPoint: .bottom, endPoint: .top)
            HStack(spacing: 6) {
                if isActive {
                    ActiveBadge()
                }
                if saver.isManaged {
                    SceneManagedBadge()
                }
                if saver.isListedInSystemSettings && model.canListInSystemSettings(saver.id) {
                    SceneListedBadge()
                }
            }
            .padding(12)
            VStack {
                Spacer()
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(saver.name)
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
                    SetButton(label: isActive ? "Active" : "Set Active") {
                        model.setActiveScreenSaver(id: saver.id)
                    }
                    .disabled(isActive || !policy.canSetActive(saver.id))
                    .help(policy.setActiveRefusalReason(saver.id) ?? "Use as the screen saver")
                }
                .padding(14)
            }
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .onTapGesture {
            model.previewScreenSaver(saver)
        }
        .contextMenu { menuItems }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(saver.name)
        .accessibilityHint("Previews the screen saver")
    }

    private var listedBinding: Binding<Bool> {
        Binding(get: { saver.listedInSystemSettings },
                set: { listed in
                    // Failures surface in the log; the card simply doesn't flip.
                    try? model.setScreenSaverListed(id: saver.id, listed)
                })
    }

    private var subtitle: String {
        if saver.isManaged {
            return "Provided by \(prefs.companyDisplayName == "Company" ? "your organization" : prefs.companyDisplayName)"
        }
        return "Edited \(saver.modifiedAt.formatted(.relative(presentation: .named)))"
    }

    private var thumbnail: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle().fill(.quaternary)
                if let image = model.screenSaverThumbnails[saver.id] {
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
        // Plain button style keeps the custom circular label (the
        // borderless menu style would redraw it as a bare glyph).
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Actions for \(saver.name)")
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Preview Fullscreen") {
            model.previewScreenSaver(saver)
        }
        if model.canOpenComposer && canModify {
            Button("Edit in Studio") {
                model.openStudio(.edit(sceneID: saver.id))
            }
        }
        if canModify {
            Button("Rename…", action: onRename)
        }
        if !saver.isManaged {
            Toggle("Show in System Settings", isOn: listedBinding)
                .disabled(!model.canListInSystemSettings(saver.id))
                .help(model.canListInSystemSettings(saver.id)
                      ? "Give this screen saver its own tile under System Settings › Screen Saver"
                      : "Not allowed by your organization's settings")
        }
        if policy.canCreate {
            // For the managed entry this makes a personal, editable copy.
            Button(saver.isManaged ? "Duplicate as My Own" : "Duplicate", action: onDuplicate)
        }
        if !saver.isManaged && prefs.adminModeEnabled {
            Button("Copy Scene for MDM") {
                model.copyManagedSceneJSON(for: saver)
            }
        }
        if canModify {
            Divider()
            Button("Delete…", role: .destructive, action: onDelete)
        }
    }
}

/// Marks a scene that has its own tile in System Settings.
struct SceneListedBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "tv")
                .font(.system(size: 9, weight: .bold))
            Text("IN SETTINGS")
                .font(Theme.badge)
                .tracking(0.5)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
        .help("Has its own tile under System Settings › Screen Saver")
    }
}

/// "Managed" marker for the admin-provisioned card; a dark capsule so it
/// reads over any thumbnail (CapsuleBadge is tuned for page backgrounds).
struct SceneManagedBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill")
                .font(.system(size: 9, weight: .bold))
            Text("MANAGED")
                .font(Theme.badge)
                .tracking(0.5)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
    }
}
