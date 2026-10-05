import AppKit
import SwiftUI

/// Detail sheet opened by clicking a wallpaper card: large preview, metadata,
/// a prominent Set button, and per-apply display/target options.
struct WallpaperDetailSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: PreferencesStore
    @Environment(\.dismiss) private var dismiss

    let wallpaper: CuratedWallpaper

    var body: some View {
        VStack(spacing: 0) {
            preview
            details
        }
        .frame(width: 720)
        .background(Theme.background)
    }

    private var preview: some View {
        ZStack(alignment: .topTrailing) {
            WallpaperThumbnail(url: model.library.fileURL(for: wallpaper), maxPixelSize: 1800)
                .frame(height: 400)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(16)
            .accessibilityLabel("Close")
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(wallpaper.displayName)
                        .font(.system(size: 26, weight: .bold))
                    Text(subtitle)
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if prefs.adminModeEnabled {
                    Button("Package for Deployment…") {
                        model.openWallpaperPackaging(selecting: wallpaper.id)
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .help("Studio › Package › Wallpapers, with this wallpaper ticked")
                }
                HeartButton(isFavorite: model.isFavorite(wallpaper)) {
                    model.toggleFavorite(wallpaper)
                }
            }

            Button {
                model.apply(wallpaper)
                dismiss()
            } label: {
                Text(model.selectionLocked ? "Selection locked by your organization" : "Set as wallpaper")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent.opacity(model.selectionLocked ? 0.4 : 1),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(model.isApplying || model.selectionLocked)

            HStack(alignment: .top, spacing: 40) {
                optionGroup(title: "Display", managedKey: .scale) {
                    HStack(spacing: 8) {
                        ForEach(WallpaperScale.allCases) { scale in
                            FilterChip(label: chipLabel(for: scale),
                                       isSelected: prefs.scale == scale) {
                                prefs.scale = scale
                            }
                        }
                    }
                    .disabled(prefs.isForced(.scale))
                }
                optionGroup(title: "Apply To", managedKey: .applyToAllScreens) {
                    HStack(spacing: 8) {
                        FilterChip(label: "All Displays", isSelected: prefs.applyToAllScreens) {
                            prefs.applyToAllScreens = true
                        }
                        FilterChip(label: "This Display", isSelected: !prefs.applyToAllScreens) {
                            prefs.applyToAllScreens = false
                        }
                    }
                    .disabled(prefs.isForced(.applyToAllScreens))
                }
            }
        }
        .padding(24)
    }

    private var subtitle: String {
        var parts = [model.sourceLabel(for: wallpaper)]
        if let size = model.pixelSize(of: wallpaper) {
            parts.append("\(Int(size.width)) × \(Int(size.height))")
        }
        if let fileSize = model.fileSizeString(of: wallpaper) {
            parts.append(fileSize)
        }
        return parts.joined(separator: " · ")
    }

    /// Short chip labels ("Fill", not "Fill Screen") to match the mockup.
    private func chipLabel(for scale: WallpaperScale) -> String {
        switch scale {
        case .fill: return "Fill"
        case .fit: return "Fit"
        case .stretch: return "Stretch"
        case .center: return "Center"
        }
    }

    @ViewBuilder
    private func optionGroup(title: String,
                             managedKey: ManagedPreferenceKey,
                             @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(Theme.sectionLabel)
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
                if prefs.isForced(managedKey) {
                    ManagedBadge()
                }
            }
            content()
        }
    }
}
