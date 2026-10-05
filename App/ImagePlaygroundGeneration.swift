import ImagePlayground
import SwiftUI

/// "Apple On-Device" generation for an image background: a prompt plus a
/// button that presents the system Image Playground sheet. The created
/// image is copied into the Studio asset store and handed back as an
/// asset name, so the scene owns it from then on.
///
/// Generation runs entirely on this Mac through Apple Intelligence; the
/// app never sees a network request. The sheet is Apple's own UI (styles,
/// people, editing) and is the supported path — the programmatic
/// `ImageCreator` is deprecated by Apple from macOS 27.
struct ImagePlaygroundBackgroundRow: View {
    /// Called with the imported asset's name.
    let onGenerated: (String) -> Void

    @Environment(\.supportsImagePlayground) private var supportsImagePlayground
    @State private var prompt = ""
    @State private var isPresented = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ComposerRow(title: "Generate with Apple Intelligence") {
                Button {
                    isPresented = true
                } label: {
                    Label("Generate…", systemImage: "apple.intelligence")
                }
                .disabled(!supportsImagePlayground)
                .help(supportsImagePlayground
                      ? "Create a background with Image Playground on this Mac"
                      : "Image Playground isn't available on this Mac")
            }
            if supportsImagePlayground {
                HStack(spacing: 10) {
                    Text("Describe it")
                        .font(.system(size: 14, weight: .medium))
                    TextField("", text: $prompt, prompt: Text("Optional, e.g. soft blue mountains at dawn"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            isPresented = true
                        }
                        .accessibilityLabel("Image description")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            } else {
                Text("Image Playground needs Apple Intelligence, which is off or unsupported on this Mac. Turn it on in System Settings › Apple Intelligence & Siri.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
        .imagePlaygroundSheet(isPresented: $isPresented, concepts: concepts, onCompletion: imported)
        .alert("Couldn’t Use the Generated Image", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var concepts: [ImagePlaygroundConcept] {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [.text(trimmed)]
    }

    /// The sheet hands back a temporary file; copying it into the asset
    /// store is what keeps it.
    private func imported(_ url: URL) {
        do {
            onGenerated(try ScreenSaverSceneStore.importAsset(from: url))
        } catch {
            errorMessage = "The image Image Playground produced couldn’t be added to the scene."
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}
