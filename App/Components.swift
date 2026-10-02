import AppKit
import SwiftUI

// MARK: - Async thumbnail

/// Downsampled wallpaper image that fills its container.
struct WallpaperThumbnail: View {
    let url: URL?
    var maxPixelSize: Int = 700

    @State private var image: NSImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle().fill(.quaternary)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        // .clipped() only clips drawing — a scaled-to-fill image still
        // hit-tests in its un-clipped bounds and would swallow clicks on
        // neighboring controls (e.g. the Browse filter chips above the hero).
        // Thumbnails are decorative; containers own all interaction.
        .allowsHitTesting(false)
        .task(id: url) {
            guard let url else { return }
            image = await ThumbnailLoader.loadThumbnail(for: url, maxPixelSize: maxPixelSize)
        }
    }
}

// MARK: - Page header

struct PageHeader<Accessory: View, Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var trailing: Trailing

    init(title: String, subtitle: String,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(title)
                    .font(Theme.pageTitle)
                accessory
                Spacer(minLength: 12)
                trailing
            }
            .frame(maxWidth: .infinity)
            Text(subtitle)
                .font(Theme.body)
                .foregroundStyle(.secondary)
        }
    }
}

/// Header "view" control: wallpaper grid density, 2–4 columns.
struct GridDensityPicker: View {
    @EnvironmentObject private var prefs: PreferencesStore

    private let options: [(columns: Int, icon: String, help: String)] = [
        (2, "square.grid.2x2", "Two columns"),
        (3, "square.grid.3x2", "Three columns"),
        (4, "square.grid.4x3.fill", "Four columns"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.columns) { option in
                let isSelected = prefs.gridColumns == option.columns
                Button {
                    prefs.gridColumns = option.columns
                } label: {
                    Image(systemName: option.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                        .frame(width: 34, height: 26)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Theme.chipFill)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(option.help)
                .accessibilityLabel(option.help)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.hairline)
        }
    }
}

extension PreferencesStore {
    /// The wallpaper grids' columns for the current density setting.
    var wallpaperGridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 20), count: gridColumns)
    }
}

/// Small gray capsule badge, e.g. "Read-only" on the Managed page.
struct CapsuleBadge: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.chipFill, in: Capsule())
    }
}

// MARK: - Filter chips

struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .white : .primary)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(isSelected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.chipFill),
                            in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Card controls

struct HeartButton: View {
    let isFavorite: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isFavorite ? Theme.accent : Color.black.opacity(0.35))
                .frame(width: 34, height: 34)
                .background(.white, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
    }
}

struct SetButton: View {
    @Environment(\.isEnabled) private var isEnabled

    var label: String = "Set"
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Label(label, systemImage: systemImage)
                } else {
                    Text(label)
                }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.white, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

struct ActiveBadge: View {
    var body: some View {
        Text("ACTIVE")
            .font(Theme.badge)
            .tracking(0.5)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.accent, in: Capsule())
    }
}

// MARK: - Wallpaper card

struct WallpaperCard: View {
    @EnvironmentObject private var model: AppModel
    // Favorites live on the prefs store; observing it directly makes the
    // heart repaint instantly instead of waiting for the next model publish.
    @EnvironmentObject private var prefs: PreferencesStore

    let wallpaper: CuratedWallpaper
    /// Second line under the name (e.g. collection name); nil for none.
    var subtitle: String?
    /// File-derived names (personal/managed) render in monospace like the mockups.
    var monospacedName: Bool = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            WallpaperThumbnail(url: model.library.thumbnailURL(for: wallpaper))
            LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0),
                                   .init(color: .clear, location: 0.55)],
                           startPoint: .bottom, endPoint: .top)
            if model.isCurrent(wallpaper) {
                ActiveBadge()
                    .padding(12)
            }
            VStack {
                Spacer()
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(wallpaper.displayName)
                            .font(monospacedName ? Theme.cardNameMono : Theme.cardName)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let subtitle {
                            Text(subtitle)
                                .font(Theme.caption)
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                        }
                    }
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    Spacer(minLength: 8)
                    HeartButton(isFavorite: prefs.favoriteWallpaperIDs.contains(wallpaper.id)) {
                        model.toggleFavorite(wallpaper)
                    }
                    SetButton {
                        model.apply(wallpaper)
                    }
                    .disabled(model.isApplying || model.selectionLocked)
                    .help(model.selectionLocked ? "Wallpaper selection is locked by your organization" : "Set as wallpaper")
                }
                .padding(14)
            }
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .onTapGesture {
            model.detailWallpaper = wallpaper
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(wallpaper.displayName)
        .accessibilityHint("Opens wallpaper details")
    }
}

// MARK: - Rotation pool membership

extension PreferencesStore {
    /// Toggle binding for one rotation-pool member (spec §4) — used by the
    /// source pages' "Include in auto-rotate" switches and Settings chips.
    func rotationPoolBinding(for member: RotationPoolMember) -> Binding<Bool> {
        Binding(
            get: { self.rotationPool.contains(member.rawValue) },
            set: { include in
                var pool = self.rotationPool
                pool.removeAll { $0 == member.rawValue }
                if include { pool.append(member.rawValue) }
                self.rotationPool = pool
            })
    }
}

// MARK: - Source header card (Personal / Managed pages)

struct SourceHeaderCard<Trailing: View>: View {
    let iconGradient: LinearGradient
    let title: String
    let path: String
    let statusColor: Color
    let statusText: String
    @Binding var includeInRotation: Bool
    var toggleDisabled: Bool = false
    var toggleManaged: Bool = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(iconGradient)
                    .frame(width: 46, height: 46)
                    .overlay {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                    Text(path)
                        .font(Theme.pathMono)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(statusColor)
                }
                trailing
            }
            .padding(18)

            Divider()
                .padding(.horizontal, 18)

            HStack {
                Text("Include in auto-rotate")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if toggleManaged {
                    ManagedBadge()
                }
                Toggle("", isOn: $includeInRotation)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.accent)
                    .disabled(toggleDisabled)
                    .accessibilityLabel("Include in auto-rotate")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                .strokeBorder(Theme.hairline)
        }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionLabel: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            Text(message)
                .font(Theme.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .tint(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}

// MARK: - Managed badge (shared with Settings)

struct ManagedBadge: View {
    var body: some View {
        Label("Managed by your organization", systemImage: "lock.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// Replaces the whole library when an MDM profile sets lockSelection.
struct LockedSelectionView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: PreferencesStore

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Wallpaper Managed by Your Organization")
                .font(.system(size: 20, weight: .semibold))
            Text("An administrator has locked wallpaper selection on this Mac.")
                .font(Theme.body)
                .foregroundStyle(.secondary)
            // Honest enforcement surface: OS profile vs app-only (spec §1).
            CapsuleBadge(text: model.lockState.enforcementDescription,
                         systemImage: model.lockState.osEnforced ? "checkmark.shield.fill" : "exclamationmark.shield")
            if let wallpaper = model.managedWallpaper {
                WallpaperThumbnail(url: model.library.thumbnailURL(for: wallpaper))
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .frame(width: 300)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    .padding(.top, 8)
                Button("Apply Managed Wallpaper") {
                    model.apply(wallpaper)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(model.isApplying)
            }
            if model.lockState.allowsExit(allowLockExit: prefs.allowLockExit) {
                // Escape hatch (soft lock with allowLockExit). The library
                // stays browsable but every Set control is greyed out.
                // Hard lock never offers an exit.
                Button("Back to Library") {
                    model.lockOverlayDismissed = true
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(Theme.background)
    }
}
