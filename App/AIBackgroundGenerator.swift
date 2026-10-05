import ImagePlayground
import SwiftUI

/// The "Generate a background" rows under Background › An Image: one
/// description, then a button per enabled provider. Whatever comes back
/// is copied into the Studio asset store and handed back as an asset
/// name, so the scene owns it from then on.
///
/// Apple On-Device presents the system Image Playground sheet (Apple's
/// own UI; the programmatic `ImageCreator` is deprecated from macOS 27).
/// Local Model and External Model call the service configured in
/// Settings and show progress inline. "Improve" sends the description to
/// Claude and replaces it with a fuller prompt. Nothing leaves the Mac
/// until a button is pressed.
struct AIBackgroundGenerator: View {
    let policy: AIGenerationPolicy
    /// The wallpaper's target size (a hint for providers that take one).
    var pixelSize: CGSize = CGSize(width: 2560, height: 1600)
    /// Called with the imported asset's name.
    let onGenerated: (String) -> Void

    @EnvironmentObject private var prefs: PreferencesStore
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground

    @State private var prompt = ""
    @State private var isPlaygroundPresented = false
    @State private var isGenerating = false
    @State private var isImproving = false
    @State private var hasExternalKey = false
    @State private var hasClaudeKey = false
    @State private var errorMessage: String?

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Describe it")
                    .font(.system(size: 14, weight: .medium))
                TextField("", text: $prompt, prompt: Text("e.g. soft blue mountains at dawn"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Image description")
                if policy.offersPromptImprovement {
                    if isImproving {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Improve", action: improvePrompt)
                        .disabled(trimmedPrompt.isEmpty || isImproving || isGenerating || !hasClaudeKey)
                        .help(hasClaudeKey
                              ? "Have Claude rewrite this into a detailed image prompt (sent to \(PromptImprover.host))"
                              : "Add the Claude API key in Settings › AI Generation")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .disabled(isGenerating)

            if policy.isEnabled(.appleOnDevice) {
                SettingsDivider()
                ComposerRow(title: "Apple On-Device") {
                    Button {
                        isPlaygroundPresented = true
                    } label: {
                        Label("Generate…", systemImage: "apple.intelligence")
                    }
                    .disabled(!supportsImagePlayground || isGenerating)
                    .help(supportsImagePlayground
                          ? "Create a background with Image Playground on this Mac"
                          : "Image Playground isn't available on this Mac")
                }
                if !supportsImagePlayground {
                    note("Image Playground needs Apple Intelligence, which is off or unsupported on this Mac. Turn it on in System Settings › Apple Intelligence & Siri.")
                }
            }

            if policy.isEnabled(.localModel) {
                SettingsDivider()
                ComposerRow(title: "Local Model") {
                    generateButton(enabled: localEndpoint.isConfigured,
                                   help: localEndpoint.isConfigured
                                       ? "Ask your local model for a background (needs a description)"
                                       : "Set the server address in Settings › AI Generation") {
                        generate(using: LocalImageProvider(endpoint: localEndpoint))
                    }
                }
                if !localEndpoint.isConfigured {
                    note("No Local Model endpoint is set. Enter the server's address in Settings › AI Generation.")
                }
            }

            if policy.isEnabled(.externalModel) {
                SettingsDivider()
                ComposerRow(title: "External Model (\(externalEndpoint.provider.displayName))") {
                    generateButton(enabled: externalEndpoint.isConfigured && hasExternalKey,
                                   help: "Ask \(externalEndpoint.provider.displayName) for a background; the description is sent to \(externalEndpoint.host)") {
                        generate(using: ExternalImageProvider(endpoint: externalEndpoint))
                    }
                }
                if !hasExternalKey {
                    note("Add the \(externalEndpoint.provider.displayName) API key in Settings › AI Generation.")
                } else if !externalEndpoint.isConfigured {
                    note("Enter the service's address in Settings › AI Generation.")
                } else {
                    note("Prompts are sent to \(externalEndpoint.host) when you press Generate.")
                }
            }
        }
        .onAppear(perform: refreshKeys)
        .onChange(of: prefs.aiExternalProvider) { _, _ in
            refreshKeys()
        }
        .imagePlaygroundSheet(isPresented: $isPlaygroundPresented, concepts: playgroundConcepts,
                              onCompletion: importPlaygroundImage)
        .alert("Couldn’t Generate a Background", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var localEndpoint: LocalImageEndpoint { prefs.localImageEndpoint }
    private var externalEndpoint: ExternalImageEndpoint { prefs.externalImageEndpoint }

    /// Keys live in the Keychain, read once per appearance (not per frame).
    private func refreshKeys() {
        hasExternalKey = KeychainStore.read(account: externalEndpoint.provider.keychainAccount) != nil
        hasClaudeKey = KeychainStore.read(account: PromptImprover.keychainAccount) != nil
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
    }

    private func generateButton(enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            if isGenerating {
                ProgressView()
                    .controlSize(.small)
            }
            Button(action: action) {
                Label(isGenerating ? "Generating…" : "Generate", systemImage: "server.rack")
            }
            .disabled(!enabled || trimmedPrompt.isEmpty || isGenerating || isImproving)
            .help(help)
        }
    }

    // MARK: Apple On-Device

    private var playgroundConcepts: [ImagePlaygroundConcept] {
        trimmedPrompt.isEmpty ? [] : [.text(trimmedPrompt)]
    }

    /// The sheet hands back a temporary file; copying it into the asset
    /// store is what keeps it.
    private func importPlaygroundImage(_ url: URL) {
        do {
            onGenerated(try ScreenSaverSceneStore.importAsset(from: url))
        } catch {
            errorMessage = "The image Image Playground produced couldn’t be added to the scene."
        }
    }

    // MARK: Programmatic providers

    private func generate(using provider: any WallpaperImageProvider) {
        let request = WallpaperGenerationRequest(prompt: trimmedPrompt, pixelSize: pixelSize)
        isGenerating = true
        Task { @MainActor in
            defer { isGenerating = false }
            do {
                let image = try await provider.generate(request)
                onGenerated(try ScreenSaverSceneStore.importAsset(data: image.data, fileExtension: image.fileExtension))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Prompt improver

    private func improvePrompt() {
        let service = PromptImprovementService(improver: prefs.promptImprover)
        let brief = trimmedPrompt
        isImproving = true
        Task { @MainActor in
            defer { isImproving = false }
            do {
                prompt = try await service.improve(brief)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}
