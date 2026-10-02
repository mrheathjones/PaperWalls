import AppKit
import SwiftUI

/// App shell: custom top bar with search, sidebar navigation, and the
/// selected library page — laid out to match the PaperWalls mockups.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: PreferencesStore

    var body: some View {
        Group {
            if model.lockState.showsLockedView && !model.lockOverlayDismissed {
                LockedSelectionView()
            } else {
                shell
            }
        }
        .frame(minWidth: 1080, minHeight: 700)
        .background(Theme.background)
        .tint(Theme.accent)
        .sheet(item: $model.detailWallpaper) { wallpaper in
            WallpaperDetailSheet(wallpaper: wallpaper)
        }
        .alert("Couldn’t Set Wallpaper", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }

    private var shell: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 0) {
                SidebarView()
                Divider()
                    .foregroundStyle(Theme.hairline)
                pageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            // Leave room for the traffic lights (hidden-title-bar window).
            Spacer()
                .frame(width: 64)
            Divider()
                .frame(height: 22)
            searchField
            Spacer()
        }
        .padding(.vertical, 10)
        .frame(height: 54)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            TextField(model.page == .screenSavers ? "Search screen savers" : "Search wallpapers",
                      text: $model.searchText)
                .textFieldStyle(.plain)
                .font(Theme.body)
        }
        .padding(.horizontal, 12)
        .frame(width: 420, height: 34)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .strokeBorder(Theme.hairline)
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private var pageContent: some View {
        switch model.page {
        case .browse:
            BrowsePage()
        case .collections:
            CollectionsPage()
        case .system:
            SystemPage()
        case .personal:
            PersonalPage()
        case .managed:
            ManagedPage()
        case .screenSavers:
            ScreenSaversPage()
        case .studio:
            StudioPage(studio: model.studio)
        case .settings:
            SettingsPage()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: PreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                appIcon
                Text("PaperWalls")
                    .font(.system(size: 19, weight: .bold))
            }
            .padding(.bottom, 26)

            // Sections (spec §10): Library, Tools, then Settings alone
            // as the last row. A section with no visible page disappears.
            ForEach(visibleSections, id: \.self) { section in
                if let title = section.title {
                    Text(title)
                        .font(Theme.sectionLabel)
                        .tracking(1.5)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                        .padding(.bottom, 8)
                }

                VStack(spacing: 2) {
                    ForEach(visiblePages(in: section)) { page in
                        SidebarRow(title: model.sidebarTitle(for: page),
                                   count: count(for: page),
                                   isSelected: model.page == page) {
                            model.page = page
                        }
                    }
                }
                .padding(.bottom, 22)
            }

            Spacer()

            autoRotateCard
        }
        .padding(16)
        .frame(width: 236)
    }

    private var appIcon: some View {
        Group {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 34, height: 34)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.accent)
                    .frame(width: 30, height: 30)
            }
        }
    }

    /// Pages hide when their gate is off (see `AppModel.isPageVisible`).
    private func visiblePages(in section: SidebarSection) -> [LibraryPage] {
        LibraryPage.allCases.filter { $0.section == section && model.isPageVisible($0) }
    }

    private var visibleSections: [SidebarSection] {
        SidebarSection.allCases.filter { !visiblePages(in: $0).isEmpty }
    }

    private func count(for page: LibraryPage) -> Int? {
        switch page {
        case .browse: return model.allBrowseWallpapers.count
        case .collections: return model.collections.count + (model.favoriteWallpapers.isEmpty ? 0 : 1)
        case .system: return model.visibleSystem.count
        case .personal: return model.visiblePersonal.count
        case .managed: return model.visibleManaged.count
        case .screenSavers: return model.allScreenSavers.count
        case .studio, .settings: return nil
        }
    }

    private var autoRotateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                model.page = .settings
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.rotationStatusTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(model.rotationStatusDetail)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(model.rotationStatusTitle). \(model.rotationStatusDetail)")

            if prefs.autoRotateEnabled {
                let actionsDisabled = model.isApplying || model.selectionLocked || model.rotationPool.isEmpty
                HStack(spacing: 6) {
                    Button {
                        model.applyNextWallpaper()
                    } label: {
                        Label("Next", systemImage: "forward.end.fill")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .help("Set the next wallpaper in the rotation now")
                    Button {
                        model.rotateNowManually()
                    } label: {
                        Label("Rotate", systemImage: "arrow.2.circlepath")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .help("Rotate to another wallpaper now")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Theme.accent)
                .disabled(actionsDisabled)
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.hairline)
        }
    }
}

struct SidebarRow: View {
    let title: String
    let count: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(isSelected ? 0 : 0.5), lineWidth: 1.5)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Theme.accent)
                        }
                    }
                    .frame(width: 22, height: 22)
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.selectedRow)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Theme.hairline)
                        }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
