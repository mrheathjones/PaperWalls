import SwiftUI

/// Curated collections as wide preview-strip cards; tapping one jumps to
/// Browse filtered to that collection.
struct CollectionsPage: View {
    @EnvironmentObject private var model: AppModel
    // Observed so the Favorites collection card appears/updates the moment
    // a heart is toggled (favorites live on the prefs store).
    @EnvironmentObject private var prefs: PreferencesStore

    private let columns = [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "Collections", subtitle: "Curated sets grouped by mood")

                if model.collections.isEmpty && model.favoriteWallpapers.isEmpty {
                    EmptyStateView(systemImage: "square.grid.2x2",
                                   title: "No Collections",
                                   message: "Bundled wallpapers are hidden or unavailable, so there are no collections to show.")
                } else {
                    LazyVGrid(columns: columns, spacing: 24) {
                        if !model.favoriteWallpapers.isEmpty {
                            CollectionCard(name: "Favorites",
                                           wallpapers: model.favoriteWallpapers) {
                                model.browseFilter = .favorites
                                model.page = .browse
                            }
                        }
                        ForEach(model.collections, id: \.self) { collection in
                            CollectionCard(name: collection,
                                           wallpapers: model.bundledWallpapers(in: collection)) {
                                model.browseFilter = .collection(collection)
                                model.page = .browse
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
    }
}

struct CollectionCard: View {
    @EnvironmentObject private var model: AppModel

    let name: String
    let wallpapers: [CuratedWallpaper]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                HStack(spacing: 0) {
                    ForEach(wallpapers.prefix(3)) { wallpaper in
                        WallpaperThumbnail(url: model.library.thumbnailURL(for: wallpaper))
                    }
                }
                LinearGradient(stops: [.init(color: .black.opacity(0.5), location: 0),
                                       .init(color: .clear, location: 0.55)],
                               startPoint: .bottom, endPoint: .top)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                    Text("\(wallpapers.count) wallpaper\(wallpapers.count == 1 ? "" : "s")")
                        .font(Theme.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .shadow(color: .black.opacity(0.4), radius: 3)
                .padding(16)
            }
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            // Thumbnails opt out of hit testing, so give the button an
            // explicit hit shape covering the whole card.
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(wallpapers.count) wallpapers")
    }
}
