import AppKit
import SwiftUI

/// What a Studio › Package build left on disk that Jamf Pro can take.
struct JamfPublishable: Equatable {
    /// The Jamf Pro package record's name — the pkg file's stem, so each
    /// version is its own record and re-publishing a version replaces it.
    let packageName: String
    let pkg: URL
    let profiles: [URL]
    let info: String
}

/// Studio › Package, after a build: tick the pkg and/or profiles, press
/// Publish, and they go to the Jamf Pro server from Settings › Admin.
/// Shown only when Admin mode and the Jamf toggles allow it.
struct JamfPublishCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: PreferencesStore

    let item: JamfPublishable

    @State private var includePackage = true
    @State private var excludedProfiles: Set<URL> = []
    @State private var isPublishing = false
    @State private var progressMessage = ""
    @State private var result: JamfPublishResult?
    @State private var errorMessage: String?

    private var policy: JamfPublishPolicy { prefs.jamfPolicy }
    private var server: JamfServer { JamfConnectionStore.server }

    private var offeredProfiles: [URL] { policy.canPublishProfiles ? item.profiles : [] }

    private var selectedProfiles: [URL] { offeredProfiles.filter { !excludedProfiles.contains($0) } }

    private var publishesPackage: Bool { policy.canPublishPackages && includePackage }

    private var canPublish: Bool {
        !isPublishing && server.isConfigured && (publishesPackage || !selectedProfiles.isEmpty)
    }

    var body: some View {
        SettingsSection(label: "Publish to Jamf Pro") {
            SettingsCard {
                if !server.isConfigured {
                    SettingsRow(title: "Jamf Pro server",
                                subtitle: "Add the server address and API client in Settings › Admin, then build again") {
                        Button("Open Settings") { model.page = .settings }
                    }
                } else {
                    if policy.canPublishPackages {
                        SettingsRow(title: item.pkg.lastPathComponent,
                                    subtitle: "Package record “\(item.packageName)” · \(fileSize(item.pkg)) · uploaded to the cloud distribution point") {
                            SettingsToggle(isOn: $includePackage, disabled: isPublishing)
                        }
                    }
                    ForEach(offeredProfiles, id: \.self) { profile in
                        if policy.canPublishPackages || profile != offeredProfiles.first {
                            SettingsDivider()
                        }
                        SettingsRow(title: profileName(profile),
                                    subtitle: "macOS configuration profile, computer level, not scoped — scope it in Jamf Pro") {
                            SettingsToggle(isOn: profileBinding(profile), disabled: isPublishing)
                        }
                    }
                    if !policy.canPublishPackages, offeredProfiles.isEmpty {
                        SettingsRow(title: "Nothing to publish",
                                    subtitle: "Packages and profiles are both turned off in Settings › Admin") {
                            EmptyView()
                        }
                    }
                    SettingsDivider()
                    publishRow
                }
            }
        }
        .onChange(of: item) { _, _ in
            result = nil
            errorMessage = nil
            excludedProfiles = []
            includePackage = true
        }
    }

    private var publishRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Button {
                    publish()
                } label: {
                    Label("Publish to \(server.host)", systemImage: "icloud.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(!canPublish)

                if isPublishing {
                    ProgressView()
                        .controlSize(.small)
                    Text(progressMessage)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                } else if !publishesPackage && selectedProfiles.isEmpty {
                    Text("Tick at least one item")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Sent only to \(server.host), only when you press Publish")
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

            if let result, !isPublishing {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(result.items) { published in
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(published.name)
                                    .font(Theme.body)
                                Text(published.summary)
                                    .font(Theme.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                            Button("Open in Jamf Pro") {
                                NSWorkspace.shared.open(published.webURL)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func publish() {
        let request = JamfPublishRequest(
            package: publishesPackage ? item.pkg : nil,
            packageName: item.packageName,
            packageInfo: item.info,
            packageNotes: "Built by PaperWalls on \(Date().formatted(date: .abbreviated, time: .shortened)).",
            profiles: selectedProfiles)
        let client = JamfClient(server: server)
        isPublishing = true
        errorMessage = nil
        result = nil
        progressMessage = "Signing in…"
        Task { @MainActor in
            do {
                result = try await client.publish(request) { message in
                    Task { @MainActor in progressMessage = message }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isPublishing = false
        }
    }

    private func profileBinding(_ profile: URL) -> Binding<Bool> {
        Binding(get: { !excludedProfiles.contains(profile) },
                set: { isOn in
                    if isOn { excludedProfiles.remove(profile) } else { excludedProfiles.insert(profile) }
                })
    }

    private func profileName(_ profile: URL) -> String {
        guard let data = FileManager.default.contents(atPath: profile.path),
              let name = ConfigurationProfileFile.displayName(in: data) else {
            return profile.deletingPathExtension().lastPathComponent
        }
        return name
    }

    private func fileSize(_ url: URL) -> String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Settings › Admin: the Jamf Pro server, API client ID (both stored in
/// the user layer only — never managed keys), the client secret (Keychain),
/// and Test Connection.
struct JamfConnectionRows: View {
    @State private var server = JamfConnectionStore.server
    @State private var loaded = false

    private var urlPrompt: String {
        JamfServer.enrolledServerURL() ?? "https://yourorg.jamfcloud.com"
    }

    var body: some View {
        Group {
            SettingsFieldRow(title: "Jamf Pro server",
                             prompt: urlPrompt,
                             text: $server.urlString)
            SettingsDivider()
            SettingsFieldRow(title: "API client ID",
                             prompt: "From Settings › System › API Roles and Clients",
                             text: $server.clientID)
            SettingsDivider()
            KeychainKeyRow(account: JamfConnectionStore.clientSecretAccount,
                           service: JamfConnectionStore.keychainService,
                           title: "Client secret",
                           hint: "Required. Kept in your Keychain; sent only to \(server.host)")
            SettingsDivider()
            ConnectionTestRow(isConfigured: server.isConfigured) {
                await JamfClient(server: server).testConnection()
            }
        }
        .onAppear {
            server = JamfConnectionStore.server
            loaded = true
        }
        .onChange(of: server) { _, newValue in
            guard loaded else { return }
            JamfConnectionStore.save(newValue)
        }
    }
}
