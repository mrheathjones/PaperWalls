import AppKit
import SwiftUI

/// Settings as a sidebar page in the main window.
struct SettingsPage: View {
    var body: some View {
        ScrollView {
            SettingsContent()
                .padding(28)
        }
    }
}

/// Settings scene content (⌘,) — same cards, standalone window.
struct SettingsView: View {
    @EnvironmentObject private var prefs: PreferencesStore

    var body: some View {
        ScrollView {
            SettingsContent()
                .padding(24)
        }
        .frame(width: 640, height: 720)
        .background(Theme.background)
        .tint(Theme.accent)
    }
}

/// Every user preference and MDM-configurable key, in the mockup's card
/// style. Keys forced by a configuration profile render disabled with a
/// "Managed by your organization" badge.
struct SettingsContent: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: PreferencesStore

    private let intervalOptions: [(label: String, value: Int)] = [
        ("5 min", 5), ("15 min", 15), ("30 min", 30), ("1 hour", 60), ("Daily", 1440),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Settings", subtitle: "Personalize how PaperWalls looks and behaves")

            SettingsSection(label: "Appearance") {
                SettingsCard {
                    SettingsRow(title: "Theme",
                                subtitle: "Light, dark, or follow the system setting",
                                managedKey: .appearanceTheme) {
                        SegmentedPills(options: AppearanceTheme.allCases.map { ($0.displayName, $0) },
                                       selection: $prefs.appearanceTheme)
                            .disabled(prefs.isForced(.appearanceTheme))
                    }
                    SettingsDivider()
                    SettingsRow(title: "Featured today",
                                subtitle: "Show a daily highlighted wallpaper at the top of Browse",
                                managedKey: .showFeaturedWallpaper) {
                        SettingsToggle(isOn: $prefs.showFeaturedWallpaper,
                                       disabled: prefs.isForced(.showFeaturedWallpaper))
                    }
                }
            }

            SettingsSection(label: "Auto-Rotate") {
                SettingsCard {
                    SettingsRow(title: "Rotate wallpaper",
                                subtitle: "Automatically cycle through a source",
                                managedKey: .autoRotateEnabled) {
                        SettingsToggle(isOn: $prefs.autoRotateEnabled,
                                       disabled: prefs.isForced(.autoRotateEnabled))
                    }
                    SettingsDivider()
                    SettingsMultiChipsRow(title: "Sources",
                                          subtitle: "Rotation draws from every selected source. Favorites narrows the pick to hearted wallpapers.",
                                          options: rotationPoolOptions,
                                          selection: $prefs.rotationPool,
                                          forced: prefs.rotationPoolForced)
                    SettingsDivider()
                    SettingsChipsRow(title: "Change every",
                                     managedKey: .autoRotateIntervalMinutes,
                                     options: intervalOptions,
                                     selection: $prefs.autoRotateIntervalMinutes)
                    SettingsDivider()
                    SettingsRow(title: "Shuffle order",
                                subtitle: "Pick randomly instead of in order",
                                managedKey: .autoRotateShuffle) {
                        SettingsToggle(isOn: $prefs.autoRotateShuffle,
                                       disabled: prefs.isForced(.autoRotateShuffle))
                    }
                    SettingsDivider()
                    SettingsRow(title: "Change on wake",
                                subtitle: "New wallpaper each time you open your Mac",
                                managedKey: .autoRotateOnWake) {
                        SettingsToggle(isOn: $prefs.autoRotateOnWake,
                                       disabled: prefs.isForced(.autoRotateOnWake))
                    }
                }
            }

            if prefs.autoRotateEnabled && !model.upNext.isEmpty {
                SettingsSection(label: "Up Next") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(model.upNext) { wallpaper in
                                WallpaperThumbnail(url: model.library.thumbnailURL(for: wallpaper),
                                                   maxPixelSize: 320)
                                    .frame(width: 150, height: 94)
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                                    .help(wallpaper.displayName)
                            }
                        }
                    }
                }
            }

            SettingsSection(label: "Wallpaper") {
                SettingsCard {
                    SettingsChipsRow(title: "Display",
                                     managedKey: .scale,
                                     options: WallpaperScale.allCases.map { ($0.displayName, $0) },
                                     selection: $prefs.scale)
                    SettingsDivider()
                    SettingsRow(title: "Fill color",
                                subtitle: "Letterbox color for Fit and Center",
                                managedKey: .fillColor) {
                        HStack(spacing: 8) {
                            if let color = NSColor(hexString: prefs.fillColorHex) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(nsColor: color))
                                    .frame(width: 28, height: 16)
                                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline))
                            }
                            TextField("", text: $prefs.fillColorHex, prompt: Text("Hex, e.g. 1D2E3F"))
                                .textFieldStyle(.plain)
                                .font(Theme.pathMono)
                                .frame(width: 130)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Theme.chipFill, in: RoundedRectangle(cornerRadius: 8))
                                .disabled(prefs.isForced(.fillColor))
                        }
                    }
                    SettingsDivider()
                    SettingsRow(title: "Apply to all displays",
                                subtitle: "Turn off to set only the primary display",
                                managedKey: .applyToAllScreens) {
                        SettingsToggle(isOn: $prefs.applyToAllScreens,
                                       disabled: prefs.isForced(.applyToAllScreens))
                    }
                }
            }

            SettingsSection(label: "Sources") {
                SettingsCard {
                    if prefs.personalFolderSource == .appManaged {
                        // Spec §5: the app owns the personal library folder;
                        // there is no picker (a legacy user-defined folder
                        // path still shows the editable field below).
                        SettingsRow(title: "Personal folder",
                                    subtitle: (PersonalFolder.appManagedPath as NSString).abbreviatingWithTildeInPath,
                                    managedKey: .personalFolderSource) {
                            Button("Reveal") {
                                PersonalFolder.ensureAppManagedFolderExists()
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [URL(fileURLWithPath: PersonalFolder.appManagedPath, isDirectory: true)])
                            }
                        }
                    } else {
                        SettingsFieldRow(title: "Personal folder",
                                         prompt: "~/Pictures/Wallpapers",
                                         text: $prefs.personalWallpaperFolderPath,
                                         managedKey: .personalWallpaperFolderPath,
                                         onBrowse: { browseForFolder { prefs.personalWallpaperFolderPath = $0 } })
                    }
                    SettingsDivider()
                    SettingsFieldRow(title: "Managed folder",
                                     prompt: "/Library/CompanyWallpapers",
                                     text: $prefs.externalWallpaperFolderPath,
                                     managedKey: .externalWallpaperFolderPath,
                                     onBrowse: { browseForFolder { prefs.externalWallpaperFolderPath = $0 } })
                    SettingsDivider()
                    SettingsRow(title: "Show bundled wallpapers",
                                subtitle: "Hide to use only your folders",
                                managedKey: .showBundledWallpapers) {
                        SettingsToggle(isOn: $prefs.showBundledWallpapers,
                                       disabled: prefs.isForced(.showBundledWallpapers))
                    }
                    SettingsDivider()
                    SettingsRow(title: "Show macOS wallpapers",
                                subtitle: "Apple's built-in wallpapers from this Mac",
                                managedKey: .showSystemWallpapers) {
                        SettingsToggle(isOn: $prefs.showSystemWallpapers,
                                       disabled: prefs.isForced(.showSystemWallpapers))
                    }
                    SettingsDivider()
                    SettingsRow(title: "Allow macOS wallpaper downloads",
                                subtitle: "Fetch not-yet-downloaded Apple wallpapers on demand (from Apple's CDN)",
                                managedKey: .allowSystemWallpaperDownloads) {
                        SettingsToggle(isOn: $prefs.allowSystemWallpaperDownloads,
                                       disabled: prefs.isForced(.allowSystemWallpaperDownloads))
                    }
                    SettingsDivider()
                    SettingsRow(title: "Curated feed",
                                subtitle: "Download fresh wallpapers curated by PaperWalls (signed and cached; nothing is fetched while this is off)",
                                managedKey: .appCuratedEnabled) {
                        SettingsToggle(isOn: $prefs.appCuratedEnabled,
                                       disabled: prefs.isForced(.appCuratedEnabled))
                    }
                    SettingsDivider()
                    SettingsRow(title: "Company name",
                                subtitle: "Shown instead of \u{201C}Company\u{201D} on the Managed source (usually set by your organization)",
                                managedKey: .companyName) {
                        TextField("", text: $prefs.companyName, prompt: Text("e.g. Acme Corp"))
                            .textFieldStyle(.plain)
                            .font(Theme.body)
                            .frame(width: 180)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.chipFill, in: RoundedRectangle(cornerRadius: 8))
                            .disabled(prefs.isForced(.companyName))
                    }
                    SettingsDivider()
                    SettingsRow(title: "Rescan folders",
                                subtitle: "\(model.library.personal.count) personal · \(model.library.managed.count) managed found") {
                        Button("Rescan", action: model.rescan)
                    }
                }
            }

            SettingsSection(label: "Screen Savers & Studio") {
                SettingsCard {
                    SettingsRow(title: "Screen savers",
                                subtitle: "Turn off to have the PaperWalls screen saver show a plain color",
                                managedKey: .screenSaverEnabled) {
                        SettingsToggle(isOn: $prefs.screenSaverEnabled,
                                       disabled: prefs.isForced(.screenSaverEnabled))
                    }
                    SettingsDivider()
                    SettingsRow(title: "Active screen saver",
                                subtitle: activeScreenSaverSubtitle,
                                managedKey: .activeScreenSaverSceneID) {
                        if prefs.showScreenSaversPage {
                            Button("Choose…") {
                                model.page = .screenSavers
                            }
                        }
                    }
                    SettingsDivider()
                    SettingsRow(title: "Screen saver module",
                                subtitle: screenSaverInstallSubtitle) {
                        if SceneBundleManager.installStatus == .notInstalled {
                            Button("Install for Me") {
                                installSaverForCurrentUser()
                            }
                        }
                    }
                    SettingsDivider()
                    SettingsRow(title: "Tiles in System Settings",
                                subtitle: sceneBundleSubtitle) {
                        EmptyView()
                    }
                    if model.managedScreenSaver != nil {
                        SettingsDivider()
                        SettingsRow(title: "Managed screen saver",
                                    subtitle: "“\(model.managedScreenSaver?.name ?? "")” is provided by your organization",
                                    managedKey: .managedScreenSaverScene) {
                            EmptyView()
                        }
                    }
                    SettingsDivider()
                    SettingsRow(title: "Show ScreenSavers page",
                                subtitle: "Your screen saver library, in the sidebar's Library section",
                                managedKey: .showScreenSaversPage) {
                        SettingsToggle(isOn: $prefs.showScreenSaversPage,
                                       disabled: prefs.isForced(.showScreenSaversPage))
                    }
                    SettingsDivider()
                    SettingsRow(title: "Show Studio",
                                subtitle: "The composing tools, in the sidebar's Tools section",
                                managedKey: .showStudio) {
                        SettingsToggle(isOn: $prefs.showStudio,
                                       disabled: prefs.isForced(.showStudio))
                    }
                    SettingsDivider()
                    SettingsRow(title: "Studio: Wallpapers tab",
                                subtitle: "Coming soon",
                                managedKey: .showStudioWallpapersTab) {
                        SettingsToggle(isOn: $prefs.showStudioWallpapersTab,
                                       disabled: prefs.isForced(.showStudioWallpapersTab) || !prefs.showStudio)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Studio: ScreenSaver tab",
                                subtitle: "The Scene Composer for building screen savers",
                                managedKey: .showStudioScreenSaverTab) {
                        SettingsToggle(isOn: $prefs.showStudioScreenSaverTab,
                                       disabled: prefs.isForced(.showStudioScreenSaverTab) || !prefs.showStudio)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Allow creating screen savers",
                                subtitle: "Turn off to keep the library browse-only: no new, edited, or deleted screen savers",
                                managedKey: .allowScreenSaverCreation) {
                        SettingsToggle(isOn: $prefs.allowScreenSaverCreation,
                                       disabled: prefs.isForced(.allowScreenSaverCreation))
                    }
                    SettingsDivider()
                    SettingsFieldRow(title: "Allowed screen saver IDs",
                                     prompt: "Comma-separated; empty allows all",
                                     text: allowedSceneIDsBinding,
                                     managedKey: .allowedScreenSaverSceneIDs)
                }
            }

            SettingsSection(label: "Restrictions") {
                SettingsCard {
                    SettingsChipsRow(title: "Lock mode",
                                     managedKey: .lockMode,
                                     options: LockMode.allCases.map { ($0.displayName, $0) },
                                     selection: $prefs.lockMode)
                    if model.lockState.mode != .off {
                        SettingsDivider()
                        SettingsRow(title: "Enforcement",
                                    subtitle: model.lockState.enforcementDescription) {
                            EmptyView()
                        }
                    }
                    SettingsDivider()
                    SettingsFieldRow(title: "Allowed wallpaper IDs",
                                     prompt: "Comma-separated; empty allows all",
                                     text: allowedIDsBinding,
                                     managedKey: .allowedWallpaperIDs)
                }
                SettingsSection(label: "Support") {
                SettingsCard {
                    SettingsRow(title: "Collect logs",
                                subtitle: "Bundle the app's logs, settings, and status into a zip for troubleshooting — nothing is sent anywhere") {
                        Button {
                            model.collectDiagnostics()
                        } label: {
                            if model.isCollectingDiagnostics {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Collecting…")
                                }
                            } else {
                                Label("Collect Logs…", systemImage: "doc.zipper")
                            }
                        }
                        .disabled(model.isCollectingDiagnostics)
                    }
                }
            }

            Text("Preference domain: \(ManagedPreferences.domain). Keys forced by an MDM configuration profile appear disabled with a badge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: 860, alignment: .leading)
    }

    /// Chips offered for the rotation pool. Feed chips appear only when the
    /// corresponding feed is configured.
    private var rotationPoolOptions: [(label: String, value: String)] {
        var members: [RotationPoolMember] = [.favorites, .bundled, .system]
        if prefs.appCuratedEnabled { members.append(.appCurated) }
        if prefs.orgFeed != nil { members.append(.orgRemote) }
        members += [.personal, .orgFolder]
        return members.map { (model.poolMemberLabel($0), $0.rawValue) }
    }

    /// Names the scene the saver runs right now (after lock tiers and the
    /// allow-list), or explains why there isn't one.
    private var activeScreenSaverSubtitle: String {
        if !prefs.screenSaverEnabled { return "Screen savers are turned off" }
        if model.lockState.mode == .hard { return "Locked by your organization — showing a plain color" }
        if let id = model.activeScreenSaverID, let saver = model.screenSaver(withID: id) {
            return saver.name
        }
        return "None selected"
    }

    private var screenSaverInstallSubtitle: String {
        switch SceneBundleManager.installStatus {
        case .system: return "Installed for everyone (/Library/Screen Savers). Choose “PaperWalls” under System Settings › Screen Saver › Other"
        case .user: return "Installed for you (~/Library/Screen Savers). Choose “PaperWalls” under System Settings › Screen Saver › Other"
        case .notInstalled: return "Not installed on this Mac — install it to use your scenes as the screen saver"
        }
    }

    private var sceneBundleSubtitle: String {
        let count = model.sceneBundleCount
        switch count {
        case 0: return "Use “Show in System Settings” on a screen saver's card to give it its own tile"
        case 1: return "1 screen saver has its own tile under System Settings › Screen Saver › Other"
        default: return "\(count) screen savers have their own tiles under System Settings › Screen Saver › Other"
        }
    }

    private func installSaverForCurrentUser() {
        do {
            try SceneBundleManager.installForCurrentUser()
            model.objectWillChange.send()
        } catch {
            model.errorMessage = "Couldn't install the screen saver: \(error.localizedDescription)"
        }
    }

    private var allowedSceneIDsBinding: Binding<String> {
        Binding(
            get: { prefs.allowedScreenSaverSceneIDs?.joined(separator: ", ") ?? "" },
            set: { newValue in
                let ids = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                prefs.allowedScreenSaverSceneIDs = ids.isEmpty ? nil : ids
            }
        )
    }

    private var allowedIDsBinding: Binding<String> {
        Binding(
            get: { prefs.allowedWallpaperIDs?.joined(separator: ", ") ?? "" },
            set: { newValue in
                let ids = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                prefs.allowedWallpaperIDs = ids.isEmpty ? nil : ids
            }
        )
    }

    private func browseForFolder(onChoose: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            onChoose(url.path)
            model.rescan()
        }
    }
}

// MARK: - Settings building blocks

struct SettingsSection<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label.uppercased())
                .font(Theme.sectionLabel)
                .tracking(1.5)
                .foregroundStyle(.secondary)
            content
        }
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                .strokeBorder(Theme.hairline)
        }
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 18)
    }
}

/// Title + optional subtitle on the left, any control on the right.
/// When `managedKey` is profile-forced, a badge appears under the subtitle
/// (the caller disables its own control).
struct SettingsRow<Control: View>: View {
    @EnvironmentObject private var prefs: PreferencesStore

    let title: String
    var subtitle: String?
    var managedKey: ManagedPreferenceKey?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
                if let managedKey, prefs.isForced(managedKey) {
                    ManagedBadge()
                }
            }
            Spacer(minLength: 16)
            control
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

/// Chip group row ("Source", "Change every", "Display").
struct SettingsChipsRow<Value: Hashable>: View {
    @EnvironmentObject private var prefs: PreferencesStore

    let title: String
    var managedKey: ManagedPreferenceKey?
    let options: [(label: String, value: Value)]
    @Binding var selection: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                if let managedKey, prefs.isForced(managedKey) {
                    ManagedBadge()
                }
            }
            HStack(spacing: 8) {
                ForEach(options, id: \.value) { option in
                    FilterChip(label: option.label, isSelected: selection == option.value) {
                        selection = option.value
                    }
                }
            }
            .disabled(managedKey.map(prefs.isForced) ?? false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

/// Multi-select chip group row (rotation pool membership, spec §4).
/// Selection is an ordered array of raw member values; tapping a chip
/// toggles membership.
struct SettingsMultiChipsRow: View {
    let title: String
    var subtitle: String?
    let options: [(label: String, value: String)]
    @Binding var selection: [String]
    var forced: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                if forced {
                    ManagedBadge()
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(options, id: \.value) { option in
                    FilterChip(label: option.label,
                               isSelected: selection.contains(option.value)) {
                        if let index = selection.firstIndex(of: option.value) {
                            selection.remove(at: index)
                        } else {
                            selection.append(option.value)
                        }
                    }
                }
            }
            .disabled(forced)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

/// Text field + optional Browse… row for folder paths and ID lists.
/// Rows with a Browse… button also accept a folder dropped from Finder.
struct SettingsFieldRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: PreferencesStore

    let title: String
    let prompt: String
    @Binding var text: String
    var managedKey: ManagedPreferenceKey?
    var onBrowse: (() -> Void)?

    @State private var isDropTargeted = false

    private var forced: Bool { managedKey.map(prefs.isForced) ?? false }
    private var acceptsFolderDrop: Bool { onBrowse != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                if forced {
                    ManagedBadge()
                }
            }
            HStack(spacing: 8) {
                TextField("", text: $text, prompt: Text(prompt))
                    .textFieldStyle(.plain)
                    .font(Theme.pathMono)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(isDropTargeted ? AnyShapeStyle(Theme.accent.opacity(0.12)) : AnyShapeStyle(Theme.chipFill),
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        if isDropTargeted {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Theme.accent, lineWidth: 1.5)
                        }
                    }
                if let onBrowse {
                    Button("Browse…", action: onBrowse)
                }
            }
            .disabled(forced)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .dropDestination(for: URL.self) { urls, _ in
            acceptDroppedFolder(urls)
        } isTargeted: { targeting in
            isDropTargeted = targeting && acceptsFolderDrop && !forced
        }
    }

    private func acceptDroppedFolder(_ urls: [URL]) -> Bool {
        guard acceptsFolderDrop, !forced else { return false }
        var isDirectory: ObjCBool = false
        guard let url = urls.first,
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        text = url.path
        model.rescan()
        return true
    }
}

/// Accent-tinted switch used across the settings cards.
struct SettingsToggle: View {
    @Binding var isOn: Bool
    var disabled: Bool = false

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(Theme.accent)
            .disabled(disabled)
    }
}

/// Two-or-more segment pill control (Settings → Theme).
struct SegmentedPills<Value: Hashable>: View {
    let options: [(label: String, value: Value)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selection == option.value ? .white : .primary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background {
                            if selection == option.value {
                                Capsule().fill(Theme.accent)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.chipFill, in: Capsule())
    }
}
