import SwiftUI

/// Bundled curated wallpapers: filter chips (All / Favorites / collections),
/// daily featured hero, card grid.
struct BrowsePage: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: PreferencesStore

    private var columns: [GridItem] { prefs.wallpaperGridColumns }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "Browse",
                           subtitle: "\(wallpapers.count) wallpaper\(wallpapers.count == 1 ? "" : "s") · \(model.displayName(for: model.browseFilter))") {
                } trailing: {
                    GridDensityPicker()
                }

                if model.allBrowseWallpapers.isEmpty {
                    emptyState
                } else {
                    chipRow

                    if prefs.showFeaturedWallpaper,
                       model.searchText.isEmpty,
                       model.browseFilter == .all,
                       let featured = model.featuredWallpaper {
                        FeaturedHero(wallpaper: featured)
                    }

                    if wallpapers.isEmpty {
                        filterEmptyState
                    } else {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(wallpapers) { wallpaper in
                                WallpaperCard(wallpaper: wallpaper,
                                              subtitle: subtitle(for: wallpaper),
                                              monospacedName: wallpaper.source != .bundled)
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
    }

    private var wallpapers: [CuratedWallpaper] {
        model.searchFilter(model.browseWallpapers)
    }

    /// Bundled cards show their collection; folder wallpapers surfacing in
    /// the Favorites pill show their source instead.
    private func subtitle(for wallpaper: CuratedWallpaper) -> String? {
        wallpaper.source == .bundled ? wallpaper.collection : model.sourceLabel(for: wallpaper)
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                FilterChip(label: "All", isSelected: model.browseFilter == .all) {
                    model.browseFilter = .all
                }
                FilterChip(label: "Favorites", isSelected: model.browseFilter == .favorites) {
                    model.browseFilter = .favorites
                }
                ForEach(model.collections, id: \.self) { collection in
                    FilterChip(label: collection,
                               isSelected: model.browseFilter == .collection(collection)) {
                        model.browseFilter = .collection(collection)
                    }
                }
                if !model.visibleSystem.isEmpty {
                    FilterChip(label: "macOS", isSelected: model.browseFilter == .system) {
                        model.browseFilter = .system
                    }
                }
                if !model.visibleAppCurated.isEmpty {
                    FilterChip(label: "Curated", isSelected: model.browseFilter == .appCurated) {
                        model.browseFilter = .appCurated
                    }
                }
                if !model.visiblePersonal.isEmpty {
                    FilterChip(label: "Personal", isSelected: model.browseFilter == .personal) {
                        model.browseFilter = .personal
                    }
                }
                if !model.visibleManaged.isEmpty {
                    FilterChip(label: model.displayName(for: .managed),
                               isSelected: model.browseFilter == .managed) {
                        model.browseFilter = .managed
                    }
                }
                if !model.visibleOrgRemote.isEmpty {
                    FilterChip(label: model.displayName(for: .orgRemote),
                               isSelected: model.browseFilter == .orgRemote) {
                        model.browseFilter = .orgRemote
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var filterEmptyState: some View {
        if model.browseFilter == .favorites {
            EmptyStateView(systemImage: "heart",
                           title: "No Favorites Yet",
                           message: "Click the heart on any wallpaper to add it to your favorites.")
        } else {
            EmptyStateView(systemImage: "photo.on.rectangle.angled",
                           title: "Nothing Here",
                           message: model.searchText.isEmpty
                               ? "This source has no wallpapers right now."
                               : "No wallpapers match “\(model.searchText)”.")
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "photo.on.rectangle.angled",
            title: "No Wallpapers Available",
            message: prefs.showBundledWallpapers
                ? "No bundled wallpapers were found in the app."
                : "Bundled wallpapers are hidden by your settings. Add a personal folder, or re-enable bundled wallpapers in Settings.",
            actionLabel: "Open Settings",
            action: { model.page = .settings }
        )
    }
}

/// Large "Featured today" banner at the top of Browse.
struct FeaturedHero: View {
    @EnvironmentObject private var model: AppModel

    let wallpaper: CuratedWallpaper

    var body: some View {
        ZStack(alignment: .topLeading) {
            WallpaperThumbnail(url: model.library.fileURL(for: wallpaper), maxPixelSize: 1800)
            LinearGradient(stops: [.init(color: .black.opacity(0.5), location: 0),
                                   .init(color: .clear, location: 0.6)],
                           startPoint: .bottom, endPoint: .top)

            Text("FEATURED TODAY")
                .font(Theme.badge)
                .tracking(1.2)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.35), in: Capsule())
                .padding(18)

            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(wallpaper.displayName)
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(.white)
                        Text(heroSubtitle)
                            .font(Theme.body)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .shadow(color: .black.opacity(0.4), radius: 4)
                    Spacer()
                    SetButton(label: "Set wallpaper") {
                        model.apply(wallpaper)
                    }
                    .disabled(model.isApplying || model.selectionLocked)
                }
                .padding(22)
            }
        }
        .frame(height: 290)
        .clipShape(RoundedRectangle(cornerRadius: Theme.heroRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.heroRadius, style: .continuous))
        .onTapGesture {
            model.detailWallpaper = wallpaper
        }
    }

    private var heroSubtitle: String {
        var parts: [String] = []
        if let collection = wallpaper.collection {
            parts.append(collection)
        }
        if let size = model.pixelSize(of: wallpaper) {
            parts.append("\(Int(size.width)) × \(Int(size.height))")
        }
        return parts.joined(separator: " · ")
    }
}
