import AppKit
import SwiftUI

/// Studio › Package › Wallpapers (admin mode): tick library wallpapers and
/// build one installer package that puts them in a folder on other Macs,
/// with a PaperWalls profile that shows the folder as the company source.
struct StudioWallpaperPackageView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: PreferencesStore

    @ObservedObject var studio: StudioSession

    private enum Filter: Hashable {
        case all
        case selected
        case favorites
        case source(CuratedWallpaper.Source)
    }

    /// What the Lock picker offers; `enforcedRotation` needs rotation
    /// settings this package doesn't carry, so it stays with the admin's
    /// own profile.
    private enum LockChoice: String, CaseIterable, Identifiable {
        case leave, off, soft, hard

        var id: String { rawValue }

        var label: String {
            switch self {
            case .leave: return "Leave as is"
            case .off: return "Off"
            case .soft: return "Soft lock"
            case .hard: return "Hard lock"
            }
        }

        var lockMode: LockMode? {
            switch self {
            case .leave: return nil
            case .off: return .off
            case .soft: return .soft
            case .hard: return .hard
            }
        }
    }

    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var packageName = ""
    @State private var version = "1.0"
    @State private var installDirectory = WallpaperDeployment.defaultInstallDirectory
    @State private var installerIdentity = ""   // "" = unsigned
    @State private var installerIdentities: [String] = []
    @State private var includeProfile = true
    @State private var defaultItemID = ""
    @State private var lockChoice: LockChoice = .leave
    @State private var restrictToPackaged = false
    @State private var isBuilding = false
    @State private var progressMessage = ""
    @State private var result: WallpaperPackager.Result?
    @State private var errorMessage: String?

    /// Above this, the selection summary gets a size warning.
    private let largeTotalBytes: Int64 = 500 * 1_000_000

    var body: some View {
        wallpaperSection
        packageSection
        signingSection
        configureSection
        buildBar
            .task {
                if packageName.isEmpty {
                    packageName = "\(prefs.companyDisplayName) Wallpapers"
                }
                installerIdentities = await Task.detached { SigningIdentities.installer() }.value
            }
    }

    // MARK: - Wallpapers

    /// Everything the admin can see in Browse, in Browse order.
    private var candidates: [CuratedWallpaper] { model.allBrowseWallpapers }

    private var selected: [CuratedWallpaper] {
        studio.wallpaperPackageSelection.compactMap { model.library.wallpaper(withID: $0) }
    }

    private var filtered: [CuratedWallpaper] {
        let base: [CuratedWallpaper]
        switch filter {
        case .all: base = candidates
        case .selected: base = selected
        case .favorites: base = model.favoriteWallpapers
        case .source(let source): base = candidates.filter { $0.source == source }
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return base }
        return base.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    /// Only pills with something behind them.
    private var filters: [(label: String, value: Filter)] {
        var options: [(String, Filter)] = [("All", .all)]
        if !selected.isEmpty { options.append(("Selected", .selected)) }
        if !model.favoriteWallpapers.isEmpty { options.append(("Favorites", .favorites)) }
        let sources: [(CuratedWallpaper.Source, String)] = [
            (.bundled, "Bundled"),
            (.system, "macOS"),
            (.appCurated, "Curated Feed"),
            (.orgRemote, "\(prefs.companyDisplayName) Feed"),
            (.external, prefs.companyDisplayName),
            (.personal, "Personal"),
        ]
        for (source, label) in sources where candidates.contains(where: { $0.source == source }) {
            options.append((label, .source(source)))
        }
        return options
    }

    @ViewBuilder
    private var wallpaperSection: some View {
        SettingsSection(label: "Wallpapers to include") {
            if candidates.isEmpty {
                EmptyStateView(systemImage: "photo.on.rectangle",
                               title: "No wallpapers to package",
                               message: "Turn on a wallpaper source in Settings, or add images to your Personal library.")
            } else {
                HStack(spacing: 12) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(filters, id: \.value) { option in
                                FilterChip(label: option.label, isSelected: filter == option.value) {
                                    filter = option.value
                                }
                            }
                        }
                    }
                    TextField("Search", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                SettingsCard {
                    if filtered.isEmpty {
                        Text(search.isEmpty ? "Nothing here yet" : "No wallpapers match “\(search)”")
                            .font(Theme.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, wallpaper in
                                if index > 0 {
                                    SettingsDivider()
                                }
                                wallpaperRow(wallpaper)
                            }
                        }
                    }
                }
                Text(selectionSummary)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func wallpaperRow(_ wallpaper: CuratedWallpaper) -> some View {
        let isSelected = studio.wallpaperPackageSelection.contains(wallpaper.id)
        return HStack(spacing: 14) {
            Toggle("", isOn: selectionBinding(wallpaper.id))
                .labelsHidden()
                .toggleStyle(.checkbox)
            WallpaperThumbnail(url: model.library.thumbnailURL(for: wallpaper), maxPixelSize: 240)
                .frame(width: 80, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(wallpaper.displayName)
                    .font(.system(size: 15, weight: .semibold))
                Text(rowSubtitle(wallpaper, isSelected: isSelected))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if isSelected {
                TextField("File name", text: nameBinding(wallpaper))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .help("The wallpaper's name on the target Macs")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    /// "macOS · 24 MB", plus the installed file name once ticked.
    private func rowSubtitle(_ wallpaper: CuratedWallpaper, isSelected: Bool) -> String {
        var parts = [model.sourceLabel(for: wallpaper)]
        if let size = model.fileSizeString(of: wallpaper) {
            parts.append(size)
        }
        if isSelected, let filename = filenames[wallpaper.id] {
            parts.append("installs as \(filename)")
        }
        return parts.joined(separator: " · ")
    }

    private var selectionSummary: String {
        guard !selected.isEmpty else { return "Tick the wallpapers to ship. Each lands in the install folder as its own file." }
        let bytes = selected.reduce(Int64(0)) { total, wallpaper in
            guard let url = model.library.fileURL(for: wallpaper),
                  let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else {
                return total
            }
            return total + size
        }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let count = selected.count == 1 ? "1 wallpaper" : "\(selected.count) wallpapers"
        let warning = bytes > largeTotalBytes ? " — large; the pkg is downloaded by every target Mac" : ""
        return "\(count) · \(size)\(warning)"
    }

    // MARK: - Package, signing, configure

    private var packageSpec: DeploymentPackageSpec {
        DeploymentPackageSpec(name: packageName.trimmingCharacters(in: .whitespaces),
                              version: version.trimmingCharacters(in: .whitespaces),
                              kind: .wallpapers)
    }

    private var installDirectoryIsValid: Bool {
        WallpaperDeployment.isValidInstallDirectory(installDirectory)
    }

    private var packageSection: some View {
        SettingsSection(label: "Package") {
            SettingsCard {
                SettingsRow(title: "Name", subtitle: "Identifier \(packageSpec.identifier)") {
                    TextField("Package name", text: $packageName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                SettingsDivider()
                SettingsRow(title: "Version",
                            subtitle: DeploymentPackageSpec.isValidVersion(packageSpec.version)
                                ? "Raise it each time you ship a change"
                                : "Use numbers separated by dots, like 1.0 or 2026.10.4") {
                    TextField("1.0", text: $version)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                SettingsDivider()
                SettingsRow(title: "Install folder",
                            subtitle: installDirectoryIsValid
                                ? "Where the images land on each Mac; the profile points PaperWalls here"
                                : "Use an absolute path outside any user's home folder, like \(WallpaperDeployment.defaultInstallDirectory)") {
                    TextField("Folder", text: $installDirectory)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 360)
                }
            }
        }
    }

    private var signingSection: some View {
        SettingsSection(label: "Signing") {
            SettingsCard {
                SettingsRow(title: "Installer package",
                            subtitle: installerIdentity.isEmpty
                                ? "Unsigned. MDM InstallEnterpriseApplication needs a Developer ID Installer signature; images themselves aren't signed"
                                : "Signed for installation through any MDM") {
                    Picker("", selection: $installerIdentity) {
                        Text("Unsigned").tag("")
                        ForEach(installerIdentities, id: \.self) { identity in
                            Text(identity).tag(identity)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 300)
                }
            }
        }
    }

    @ViewBuilder
    private var configureSection: some View {
        SettingsSection(label: "Also include") {
            SettingsCard {
                SettingsRow(title: "Configuration profile",
                            subtitle: "Profile and managed.json that show the folder as “\(prefs.companyDisplayName)” in PaperWalls (externalWallpaperFolderPath)") {
                    SettingsToggle(isOn: $includeProfile)
                }
                if includeProfile {
                    SettingsDivider()
                    SettingsRow(title: "Default wallpaper",
                                subtitle: defaultSelection.wrappedValue.isEmpty
                                    ? "Users keep their current desktop"
                                    : "Applied by the PaperWalls manage agent at login and hourly (selectedWallpaperID)") {
                        Picker("", selection: defaultSelection) {
                            Text("None").tag("")
                            ForEach(selected) { wallpaper in
                                Text(deployedName(wallpaper)).tag(wallpaper.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        .disabled(selected.isEmpty)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Lock",
                                subtitle: lockSubtitle) {
                        Picker("", selection: $lockChoice) {
                            ForEach(LockChoice.allCases) { choice in
                                Text(choice.label).tag(choice)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 160)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Only these wallpapers",
                                subtitle: "Hide every other source on the target Macs (allowedWallpaperIDs)") {
                        SettingsToggle(isOn: $restrictToPackaged)
                    }
                }
            }
        }
    }

    private var lockSubtitle: String {
        switch lockChoice {
        case .leave: return "Each Mac keeps its current lock tier (lockMode)"
        case .off: return "Forces lockMode off"
        case .soft: return "Only the default can be applied; users can still browse. Needs a default wallpaper"
        case .hard: return "Nothing else can be applied in the app or CLI. Needs a default wallpaper"
        }
    }

    // MARK: - Build

    private var canBuild: Bool {
        !isBuilding && !selected.isEmpty && packageSpec.isValid && installDirectoryIsValid
            && !(includeProfile && lockChoice.lockMode.map { $0 == .soft || $0 == .hard } == true
                 && defaultSelection.wrappedValue.isEmpty)
    }

    private var buildHint: String? {
        if selected.isEmpty { return "Tick at least one wallpaper" }
        if includeProfile, lockChoice == .soft || lockChoice == .hard, defaultSelection.wrappedValue.isEmpty {
            return "A lock needs a default wallpaper"
        }
        return nil
    }

    private var buildBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Button {
                    chooseFolderAndBuild()
                } label: {
                    Label(selected.count > 1 ? "Build Package with \(selected.count) Wallpapers…" : "Build Package…",
                          systemImage: "shippingbox")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.large)
                .disabled(!canBuild)

                if isBuilding {
                    ProgressView()
                        .controlSize(.small)
                    Text(progressMessage)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                } else if let buildHint {
                    Text(buildHint)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if let result, !isBuilding {
                SettingsCard {
                    SettingsRow(title: "Package ready",
                                subtitle: result.pkg.lastPathComponent + ". See DEPLOY.txt beside it for next steps") {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([result.pkg])
                        }
                    }
                }
            }
        }
    }

    private func chooseFolderAndBuild() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Build Here"
        panel.message = "Choose where to put the \(packageSpec.pkgFilename) folder"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let names = filenames
        let items: [WallpaperPackager.Item] = selected.compactMap { wallpaper in
            guard let source = model.library.fileURL(for: wallpaper), let filename = names[wallpaper.id] else {
                return nil
            }
            return WallpaperPackager.Item(wallpaper: wallpaper, source: source, filename: filename)
        }
        let configuration = includeProfile
            ? WallpaperPackager.Configuration(
                defaultItemID: defaultSelection.wrappedValue.isEmpty ? nil : defaultSelection.wrappedValue,
                lockMode: lockChoice.lockMode,
                restrictToPackaged: restrictToPackaged)
            : nil
        let request = WallpaperPackager.Request(package: packageSpec,
                                                items: items,
                                                installDirectory: installDirectory,
                                                outputDirectory: folder,
                                                installerIdentity: installerIdentity.isEmpty ? nil : installerIdentity,
                                                configuration: configuration,
                                                organization: prefs.companyName.trimmingCharacters(in: .whitespaces))
        isBuilding = true
        errorMessage = nil
        result = nil
        progressMessage = "Starting…"
        Task { @MainActor in
            do {
                result = try await WallpaperPackager.build(request) { progressMessage = $0 }
            } catch {
                errorMessage = error.localizedDescription
            }
            isBuilding = false
        }
    }

    // MARK: - Helpers

    private func deployedName(_ wallpaper: CuratedWallpaper) -> String {
        let edited = studio.wallpaperPackageNames[wallpaper.id]?.trimmingCharacters(in: .whitespaces) ?? ""
        return edited.isEmpty ? wallpaper.displayName : edited
    }

    /// Installed file name by wallpaper ID, clashes resolved in tick order.
    private var filenames: [String: String] {
        let selected = self.selected
        let names = WallpaperDeployment.uniqueFilenames(selected.map { wallpaper in
            WallpaperDeployment.filename(name: deployedName(wallpaper),
                                         sourcePath: model.library.fileURL(for: wallpaper)?.path ?? wallpaper.filename)
        })
        return Dictionary(uniqueKeysWithValues: zip(selected.map(\.id), names))
    }

    private func selectionBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { studio.wallpaperPackageSelection.contains(id) },
                set: { isOn in
                    if isOn, !studio.wallpaperPackageSelection.contains(id) {
                        studio.wallpaperPackageSelection.append(id)
                    } else if !isOn {
                        studio.wallpaperPackageSelection.removeAll { $0 == id }
                    }
                })
    }

    private func nameBinding(_ wallpaper: CuratedWallpaper) -> Binding<String> {
        Binding(get: { studio.wallpaperPackageNames[wallpaper.id] ?? wallpaper.displayName },
                set: { studio.wallpaperPackageNames[wallpaper.id] = $0 })
    }

    /// The chosen default, or none once it's unticked.
    private var defaultSelection: Binding<String> {
        Binding(get: { studio.wallpaperPackageSelection.contains(defaultItemID) ? defaultItemID : "" },
                set: { defaultItemID = $0 })
    }
}
