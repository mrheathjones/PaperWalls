import ImagePlayground
import SwiftUI

/// The "Generate a background" rows under Background › An Image: one
/// description, then a button per enabled provider. Whatever comes back
/// is copied into the Studio asset store and handed back as an asset
/// name, so the scene owns it from then on.
///
/// Apple On-Device presents the system Image Playground sheet (Apple's
/// own UI; the programmatic `ImageCreator` is deprecated from macOS 27).
/// Local Model calls the server configured in Settings and shows
/// progress inline. Nothing leaves the Mac until a button is pressed.
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
                    HStack(spacing: 8) {
                        if isGenerating {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button {
                            generateLocally()
                        } label: {
                            Label(isGenerating ? "Generating…" : "Generate", systemImage: "server.rack")
                        }
                        .disabled(!localEndpoint.isConfigured || trimmedPrompt.isEmpty || isGenerating)
                        .help(localEndpoint.isConfigured
                              ? "Ask your local model for a background (needs a description)"
                              : "Set the server address in Settings › AI Generation")
                    }
                }
                if !localEndpoint.isConfigured {
                    note("No Local Model endpoint is set. Enter the server's address in Settings › AI Generation.")
                }
            }
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

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
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

    // MARK: Local Model

    private func generateLocally() {
        let provider = LocalImageProvider(endpoint: localEndpoint)
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

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}
