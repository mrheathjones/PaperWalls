import AppKit
import SwiftUI

// MARK: - Personal

/// Wallpapers from the user's personal library. In the default app-managed
/// mode (spec §5) the app owns a fixed folder and images are added by
/// dropping them onto this page; a pre-existing user-chosen folder keeps
/// working in the legacy user-defined mode.
struct PersonalPage: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: PreferencesStore

    @State private var isDropTargeted = false

    private var columns: [GridItem] { prefs.wallpaperGridColumns }

    private var isAppManaged: Bool { prefs.personalFolderSource == .appManaged }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "Personal",
                           subtitle: isAppManaged
                               ? "Your own wallpapers — drop images anywhere on this page to add them"
                               : "Wallpapers from your own folders on this Mac") {
                } trailing: {
                    GridDensityPicker()
                }

                if isAppManaged {
                    appManagedContent
                } else {
                    userDefinedContent
                }
            }
            .padding(28)
        }
        .dropDestination(for: URL.self) { urls, _ in
            isAppManaged ? importDroppedImages(urls) : acceptDroppedFolder(urls)
        } isTargeted: { targeting in
            isDropTargeted = targeting
        }
    }

    @ViewBuilder
    private var appManagedContent: some View {
        SourceHeaderCard(
            iconGradient: Theme.personalIcon,
            title: "My Wallpapers",
            path: (PersonalFolder.appManagedPath as NSString).abbreviatingWithTildeInPath,
            statusColor: .secondary.opacity(0.8),
            statusText: "App-managed",
            includeInRotation: prefs.rotationPoolBinding(for: .personal),
            toggleDisabled: prefs.rotationPoolForced,
            toggleManaged: prefs.rotationPoolForced
        ) {
            Button("Reveal in Finder", action: revealInFinder)
        }

        if wallpapers.isEmpty {
            EmptyStateView(systemImage: "photo.on.rectangle.angled",
                           title: "No Personal Wallpapers",
                           message: "Drop JPEG, PNG, HEIC, or TIFF images anywhere on this page — they're copied into your personal library.",
                           actionLabel: "Reveal in Finder",
                           action: revealInFinder)
        } else {
            wallpaperGrid
        }
    }

    @ViewBuilder
    private var userDefinedContent: some View {
        SourceHeaderCard(
            iconGradient: Theme.personalIcon,
            title: "My Wallpapers",
            path: prefs.personalWallpaperFolderPath,
            statusColor: .secondary.opacity(0.8),
            statusText: "Local",
            includeInRotation: prefs.rotationPoolBinding(for: .personal),
            toggleDisabled: prefs.rotationPoolForced,
            toggleManaged: prefs.rotationPoolForced
        ) {
            Button("Change…", action: chooseFolder)
                .disabled(prefs.isForced(.personalWallpaperFolderPath))
        }

        if wallpapers.isEmpty {
            EmptyStateView(systemImage: "photo.on.rectangle.angled",
                           title: "No Images Found",
                           message: "Add JPEG, PNG, HEIC, or TIFF files to \(prefs.personalWallpaperFolderPath), then rescan.",
                           actionLabel: "Rescan",
                           action: model.rescan)
        } else {
            wallpaperGrid
        }
    }

    private var wallpaperGrid: some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(wallpapers) { wallpaper in
                WallpaperCard(wallpaper: wallpaper, monospacedName: true)
            }
        }
    }

    private var wallpapers: [CuratedWallpaper] {
        model.searchFilter(model.visiblePersonal)
    }

    private func revealInFinder() {
        PersonalFolder.ensureAppManagedFolderExists()
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: PersonalFolder.appManagedPath, isDirectory: true)])
    }

    /// App-managed drop: copy dropped images into the library. Folders are
    /// deliberately ignored — dropping one no longer switches the source
    /// (spec §5 single-source semantics).
    private func importDroppedImages(_ urls: [URL]) -> Bool {
        guard PersonalFolder.importImages(at: urls) > 0 else { return false }
        model.rescan()
        return true
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            prefs.personalWallpaperFolderPath = url.path
            model.rescan()
        }
    }

    /// Legacy user-defined drop: accept the first dropped *folder* as the
    /// personal source.
    private func acceptDroppedFolder(_ urls: [URL]) -> Bool {
        guard !prefs.isForced(.personalWallpaperFolderPath) else { return false }
        var isDirectory: ObjCBool = false
        guard let url = urls.first,
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        prefs.personalWallpaperFolderPath = url.path
        model.rescan()
        return true
    }
}

// MARK: - macOS

/// Apple's built-in wallpapers (/System/Library/Desktop Pictures). Read-only
/// by nature; flat images only — the dynamic .madesktop bundles can't be set
/// through the wallpaper API.
struct SystemPage: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: PreferencesStore

    private var columns: [GridItem] { prefs.wallpaperGridColumns }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "macOS", subtitle: "Apple's built-in wallpapers on this Mac") {
                } trailing: {
                    GridDensityPicker()
                }

                SourceHeaderCard(
                    iconGradient: Theme.systemIcon,
                    title: "macOS Wallpapers",
                    path: WallpaperCatalog.systemWallpapersPath,
                    statusColor: .secondary.opacity(0.8),
                    statusText: "Built-in",
                    includeInRotation: prefs.rotationPoolBinding(for: .system),
                    toggleDisabled: prefs.rotationPoolForced,
                    toggleManaged: prefs.rotationPoolForced
                ) {
                    EmptyView()
                }

                if wallpapers.isEmpty && pending.isEmpty {
                    EmptyStateView(systemImage: "apple.logo",
                                   title: "No macOS Wallpapers Found",
                                   message: "This version of macOS keeps its wallpapers in a format the wallpaper API can't set directly.")
                } else {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(wallpapers) { wallpaper in
                            WallpaperCard(wallpaper: wallpaper)
                        }
                    }
                }

                if !pending.isEmpty {
                    Text("AVAILABLE TO DOWNLOAD")
                        .font(Theme.sectionLabel)
                        .tracking(1.5)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    Text("These wallpapers ship with macOS but aren't on this Mac yet. Downloading fetches the full-resolution image from Apple.")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(pending) { entry in
                            PendingSystemCard(entry: entry,
                                              isDownloading: model.downloadingSystemAssets.contains(entry.assetID),
                                              download: { model.downloadSystemWallpaper(entry) },
                                              downloadAndSet: { model.requestSetForPendingSystemWallpaper(entry) })
                        }
                    }
                }
            }
            .padding(28)
        }
    }

    private var wallpapers: [CuratedWallpaper] {
        model.searchFilter(model.visibleSystem)
    }

    private var pending: [SystemAssetEntry] {
        // Admins can force downloads off (network-restricted fleets) — the
        // on-demand section disappears entirely.
        guard prefs.allowSystemWallpaperDownloads else { return [] }
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.library.systemPending }
        return model.library.systemPending.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
        }
    }
}

/// Card for a macOS wallpaper that needs downloading first: Apple's own
/// preview, the size, Download, and Download & Set (spinner while fetching).
struct PendingSystemCard: View {
    @EnvironmentObject private var model: AppModel

    let entry: SystemAssetEntry
    let isDownloading: Bool
    let download: () -> Void
    let downloadAndSet: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WallpaperThumbnail(url: entry.thumbnailPath.map { URL(fileURLWithPath: $0) },
                               maxPixelSize: 480)
                .frame(height: 180)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: Theme.cardRadius,
                                                  topTrailingRadius: Theme.cardRadius))
                .opacity(isDownloading ? 0.55 : 1)
                .overlay {
                    if isDownloading {
                        ProgressView()
                    }
                }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .font(Theme.cardName)
                        .lineLimit(1)
                    Text(entry.downloadSize.map {
                        ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
                    } ?? "macOS")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                let unavailable = isDownloading || entry.downloadURL == nil
                Button(action: download) {
                    Label(isDownloading ? "Downloading…" : "Download",
                          systemImage: "arrow.down.circle")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(unavailable)
                .help(entry.downloadURL == nil
                      ? "Apple's wallpaper catalog isn't available on this Mac"
                      : "Download the full-resolution image from Apple")
                Button(action: downloadAndSet) {
                    Label("Set", systemImage: "photo.on.rectangle")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Theme.accent)
                .disabled(unavailable || model.selectionLocked)
                .help(model.selectionLocked
                      ? "Wallpaper selection is locked by your organization"
                      : "Set as wallpaper (downloads from Apple first)")
            }
            .padding(14)
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.hairline)
        }
    }
}

// MARK: - Managed

/// Wallpapers provisioned by the organization (externalWallpaperFolderPath).
struct ManagedPage: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: PreferencesStore

    private var columns: [GridItem] { prefs.wallpaperGridColumns }

    private var isProvisioned: Bool { prefs.isForced(.externalWallpaperFolderPath) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: prefs.companyDisplayName == "Company" ? "Managed" : "\(prefs.companyDisplayName) (Managed)",
                           subtitle: "Wallpapers provisioned by your organization") {
                    if isProvisioned {
                        CapsuleBadge(text: "Read-only", systemImage: "lock.fill")
                    }
                } trailing: {
                    GridDensityPicker()
                }

                if prefs.externalWallpaperFolderPath.isEmpty {
                    EmptyStateView(systemImage: "building.2",
                                   title: "No Managed Source",
                                   message: "No managed wallpaper folder is configured. Your organization can provision one via an MDM configuration profile, or you can set a folder path in Settings.")
                } else {
                    SourceHeaderCard(
                        iconGradient: Theme.managedIcon,
                        title: "\(prefs.companyDisplayName) Wallpapers",
                        path: prefs.externalWallpaperFolderPath,
                        statusColor: isProvisioned ? .green : .secondary.opacity(0.8),
                        statusText: isProvisioned ? "Synced" : "Local",
                        includeInRotation: prefs.rotationPoolBinding(for: .orgFolder),
                        toggleDisabled: prefs.rotationPoolForced,
                        toggleManaged: prefs.rotationPoolForced
                    ) {
                        if isProvisioned {
                            Text("Managed by admin")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if wallpapers.isEmpty {
                        EmptyStateView(systemImage: "photo.on.rectangle.angled",
                                       title: "No Images Found",
                                       message: "The managed folder has no supported images yet.",
                                       actionLabel: "Rescan",
                                       action: model.rescan)
                    } else {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(wallpapers) { wallpaper in
                                WallpaperCard(wallpaper: wallpaper, monospacedName: true)
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
    }

    private var wallpapers: [CuratedWallpaper] {
        model.searchFilter(model.visibleManaged)
    }
}
