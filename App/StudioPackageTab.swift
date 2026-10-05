import AppKit
import SwiftUI

/// Studio › Package (admin mode): pick library screen savers and build one
/// installer package that puts each on other Macs as its own saver. The
/// Wallpapers side is a placeholder until Studio can make wallpapers.
struct StudioPackageTab: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: PreferencesStore

    @ObservedObject var studio: StudioSession

    enum Kind: Hashable {
        case screenSavers
        case wallpapers
    }

    @State private var kind: Kind = .screenSavers
    @State private var packageName = ""
    @State private var version = "1.0"
    @State private var appIdentity = ""         // "" = ad hoc
    @State private var installerIdentity = ""   // "" = unsigned
    @State private var codeSigningIdentities: [String] = []
    @State private var installerIdentities: [String] = []
    @State private var includeMDMJSON = true
    @State private var includeProfile = false
    @State private var profileSceneID = ""
    @State private var isBuilding = false
    @State private var progressMessage = ""
    @State private var result: ScenePackager.Result?
    @State private var errorMessage: String?

    /// Above this, a rotating-pool scene gets a size warning.
    private let largeMediaBytes: Int64 = 250 * 1_000_000

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SegmentedPills(options: [("Screen Savers", Kind.screenSavers), ("Wallpapers", Kind.wallpapers)],
                           selection: $kind)
            switch kind {
            case .screenSavers:
                screenSaverPackaging
            case .wallpapers:
                comingSoon
            }
        }
        .task {
            if packageName.isEmpty {
                packageName = "\(prefs.companyDisplayName) Screen Savers"
            }
            let identities = await Task.detached {
                (SigningIdentities.codeSigning(), SigningIdentities.installer())
            }.value
            (codeSigningIdentities, installerIdentities) = identities
        }
    }

    // MARK: - Screen savers

    private var selected: [StoredScreenSaver] {
        studio.packageSelection.compactMap { model.screenSaver(withID: $0) }
    }

    private var packageSpec: DeploymentPackageSpec {
        DeploymentPackageSpec(name: packageName.trimmingCharacters(in: .whitespaces),
                              version: version.trimmingCharacters(in: .whitespaces))
    }

    @ViewBuilder
    private var screenSaverPackaging: some View {
        SettingsSection(label: "Screen savers to include") {
            if model.allScreenSavers.isEmpty {
                EmptyStateView(systemImage: "sparkles.tv",
                               title: "No screen savers yet",
                               message: "Make one in Studio's ScreenSaver tab, then package it here.")
            } else {
                SettingsCard {
                    ForEach(Array(model.allScreenSavers.enumerated()), id: \.element.id) { index, saver in
                        if index > 0 {
                            SettingsDivider()
                        }
                        sceneRow(saver)
                    }
                }
            }
        }

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
            }
        }

        SettingsSection(label: "Signing") {
            SettingsCard {
                SettingsRow(title: "Screen savers",
                            subtitle: appIdentity.isEmpty
                                ? "Ad hoc. Fine for Jamf Pro; notarizing needs a Developer ID Application certificate"
                                : "Hardened runtime + secure timestamp, ready to notarize") {
                    identityPicker($appIdentity, none: "Ad hoc", options: codeSigningIdentities)
                }
                SettingsDivider()
                SettingsRow(title: "Installer package",
                            subtitle: installerIdentity.isEmpty
                                ? "Unsigned. MDM InstallEnterpriseApplication needs a Developer ID Installer signature"
                                : "Signed for installation through any MDM") {
                    identityPicker($installerIdentity, none: "Unsigned", options: installerIdentities)
                }
            }
        }

        SettingsSection(label: "Also include") {
            SettingsCard {
                SettingsRow(title: "MDM scene JSON",
                            subtitle: "managedScreenSaverScene values, to provision the same scenes inside the PaperWalls app") {
                    SettingsToggle(isOn: $includeMDMJSON)
                }
                SettingsDivider()
                SettingsRow(title: "Selection profile",
                            subtitle: "A reference .mobileconfig that selects one saver. macOS 14 and later may ignore it; test before relying on it") {
                    HStack(spacing: 10) {
                        if includeProfile {
                            Picker("", selection: profileSelection) {
                                ForEach(selected) { saver in
                                    Text(deployedName(saver)).tag(saver.id)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 220)
                        }
                        SettingsToggle(isOn: $includeProfile, disabled: selected.isEmpty)
                    }
                }
            }
        }

        buildBar
    }

    private func sceneRow(_ saver: StoredScreenSaver) -> some View {
        let isSelected = studio.packageSelection.contains(saver.id)
        return HStack(spacing: 14) {
            Toggle("", isOn: selectionBinding(saver.id))
                .labelsHidden()
                .toggleStyle(.checkbox)
            thumbnail(saver)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(saver.name)
                        .font(.system(size: 15, weight: .semibold))
                    if saver.isManaged {
                        SceneManagedBadge()
                    }
                }
                Text(mediaSummary(saver))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if isSelected {
                TextField("Saver name", text: displayNameBinding(saver))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .help("The name in System Settings › Screen Saver on the target Macs")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func thumbnail(_ saver: StoredScreenSaver) -> some View {
        ZStack {
            Theme.chipFill
            if let image = model.screenSaverThumbnails[saver.id] {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: 80, height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .allowsHitTesting(false)
    }

    private var comingSoon: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
            Text("Coming Soon")
                .font(.system(size: 22, weight: .bold))
            Text("Package wallpapers made in Studio for deployment, the same way as screen savers.")
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

    // MARK: - Build

    private var buildBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Button {
                    chooseFolderAndBuild()
                } label: {
                    Label(selected.count > 1 ? "Build Package with \(selected.count) Screen Savers…" : "Build Package…",
                          systemImage: "shippingbox")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.large)
                .disabled(isBuilding || selected.isEmpty || !packageSpec.isValid)

                if isBuilding {
                    ProgressView()
                        .controlSize(.small)
                    Text(progressMessage)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                } else if selected.isEmpty {
                    Text("Tick at least one screen saver")
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

        let items = selected.map { saver in
            model.deploymentItem(for: saver, displayName: deployedName(saver), includeMDMJSON: includeMDMJSON)
        }
        let profileSaver = includeProfile
            ? items.first { $0.spec.sceneID == profileSelection.wrappedValue }?.spec
            : nil
        let request = ScenePackager.Request(package: packageSpec,
                                            items: items,
                                            outputDirectory: folder,
                                            appIdentity: appIdentity.isEmpty ? nil : appIdentity,
                                            installerIdentity: installerIdentity.isEmpty ? nil : installerIdentity,
                                            profileSaver: profileSaver,
                                            organization: prefs.companyName.trimmingCharacters(in: .whitespaces))
        isBuilding = true
        errorMessage = nil
        result = nil
        progressMessage = "Starting…"
        Task { @MainActor in
            do {
                result = try await ScenePackager.build(request) { progressMessage = $0 }
            } catch {
                errorMessage = error.localizedDescription
            }
            isBuilding = false
        }
    }

    // MARK: - Helpers

    private func deployedName(_ saver: StoredScreenSaver) -> String {
        let edited = studio.packageDisplayNames[saver.id]?.trimmingCharacters(in: .whitespaces) ?? ""
        return edited.isEmpty ? model.defaultDeployedName(for: saver) : edited
    }

    private func selectionBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { studio.packageSelection.contains(id) },
                set: { isOn in
                    if isOn, !studio.packageSelection.contains(id) {
                        studio.packageSelection.append(id)
                    } else if !isOn {
                        studio.packageSelection.removeAll { $0 == id }
                    }
                })
    }

    private func displayNameBinding(_ saver: StoredScreenSaver) -> Binding<String> {
        Binding(get: { studio.packageDisplayNames[saver.id] ?? model.defaultDeployedName(for: saver) },
                set: { studio.packageDisplayNames[saver.id] = $0 })
    }

    /// The chosen profile scene, falling back to the first ticked one.
    private var profileSelection: Binding<String> {
        Binding(get: {
                    studio.packageSelection.contains(profileSceneID) ? profileSceneID : (studio.packageSelection.first ?? "")
                },
                set: { profileSceneID = $0 })
    }

    private func identityPicker(_ selection: Binding<String>, none: String, options: [String]) -> some View {
        Picker("", selection: selection) {
            Text(none).tag("")
            ForEach(options, id: \.self) { identity in
                Text(identity).tag(identity)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 300)
    }

    /// "Embeds 12 images · 84 MB", or a note that the scene follows the
    /// target Mac's desktop picture.
    private func mediaSummary(_ saver: StoredScreenSaver) -> String {
        let (_, media) = SceneDeployment.portable(model.sceneSnapshot(for: saver))
        if case .currentDesktop = saver.scene.background.source, media.isEmpty {
            return "Shows each Mac's current desktop picture"
        }
        guard !media.isEmpty else { return "No images to embed" }
        let bytes = media.reduce(Int64(0)) { total, file in
            let size = (try? FileManager.default.attributesOfItem(atPath: file.source)[.size] as? NSNumber)?.int64Value
            return total + (size ?? 0)
        }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        var count = media.count == 1 ? "1 image" : "\(media.count) images"
        if case .rotatingPool = saver.scene.background.source {
            count += " from your rotation pool"
        }
        let warning = bytes > largeMediaBytes ? " — large; consider a smaller rotation pool" : ""
        return "Embeds \(count) · \(size)\(warning)"
    }
}
