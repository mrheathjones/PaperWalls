import AppKit
import SwiftUI

/// Studio › ScreenSaver › "Compose with Claude": describe the screen saver
/// you want, press Compose, and the Scene Composer opens with Claude's
/// recipe as a new, unsaved draft — background, layers, and motion, all
/// editable like any other. Optionally the background picture is then
/// made by the Local or External image service from Settings (Claude only
/// describes it). Nothing leaves the Mac until Compose is pressed.
struct AISceneComposer: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var prefs: PreferencesStore

    /// Called with the composed draft, ready for the composer.
    let onComposed: (SceneDraft) -> Void

    @State private var brief = ""
    /// Which image service makes the background picture; nil keeps the
    /// colors Claude chose.
    @State private var imageProvider: AIProviderKind?
    @State private var isComposing = false
    @State private var progress = ""
    @State private var hasClaudeKey = false
    @State private var hasExternalKey = false
    @State private var errorMessage: String?
    /// A finished composition whose background picture failed: the user
    /// decides whether to open it with Claude's colors instead.
    @State private var draftAwaitingDecision: (draft: SceneDraft, reason: String)?

    private var trimmedBrief: String {
        brief.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        SettingsSection(label: "Compose with Claude") {
            SettingsCard {
                Text("Describe the screen saver you want — what's on screen, the colors, how it moves — and Claude writes the whole scene for you to fine-tune. Claude doesn't make pictures; choose an image service below to have the background painted from Claude's description.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                SettingsDivider()
                HStack(alignment: .top, spacing: 10) {
                    Text("Describe it")
                        .font(.system(size: 14, weight: .medium))
                        .padding(.top, 4)
                    TextField("", text: $brief, prompt: Text("e.g. a dark navy gradient, a large thin clock drifting slowly, and “Back soon” underneath"), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...5)
                        .accessibilityLabel("Screen saver description")
                        .onSubmit(compose)
                    if isComposing {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.top, 4)
                    }
                    Button(action: compose) {
                        Label(isComposing ? "Composing…" : "Compose", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(trimmedBrief.isEmpty || isComposing || !hasClaudeKey)
                    .help(hasClaudeKey
                          ? "Have Claude write this screen saver (the description is sent to \(SceneGenerator.host))"
                          : "Add the Claude API key in Settings › AI Generation")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .disabled(isComposing)

                if !availableImageProviders.isEmpty {
                    SettingsDivider()
                    ComposerRow(title: "Background picture") {
                        Picker("Background picture", selection: $imageProvider) {
                            Text("Claude's colors").tag(AIProviderKind?.none)
                            ForEach(availableImageProviders) { kind in
                                Text(providerLabel(kind)).tag(Optional(kind))
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .disabled(isComposing)
                    }
                }

                SettingsDivider()
                Text(isComposing && !progress.isEmpty ? progress : privacyNote)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
        .onAppear(perform: refreshKeys)
        .onChange(of: prefs.aiExternalProvider) { _, _ in
            refreshKeys()
        }
        .onChange(of: availableImageProviders) { _, providers in
            if let chosen = imageProvider, !providers.contains(chosen) {
                imageProvider = nil
            }
        }
        .alert("Couldn’t Compose a Screen Saver", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Background Picture Not Made", isPresented: decisionPresented) {
            Button("Open with Claude’s Colors") {
                if let pending = draftAwaitingDecision {
                    onComposed(pending.draft)
                }
                draftAwaitingDecision = nil
            }
            Button("Cancel", role: .cancel) {
                draftAwaitingDecision = nil
            }
        } message: {
            Text("Claude composed the screen saver, but the background picture couldn’t be generated: \(draftAwaitingDecision?.reason ?? "")")
        }
    }

    // MARK: - Providers

    /// Image services that are on, configured, and keyed — the ones that
    /// can actually paint a background.
    private var availableImageProviders: [AIProviderKind] {
        var kinds: [AIProviderKind] = []
        if prefs.aiPolicy.isEnabled(.localModel) && prefs.localImageEndpoint.isConfigured {
            kinds.append(.localModel)
        }
        if prefs.aiPolicy.isEnabled(.externalModel) && prefs.externalImageEndpoint.isConfigured && hasExternalKey {
            kinds.append(.externalModel)
        }
        return kinds
    }

    private func providerLabel(_ kind: AIProviderKind) -> String {
        switch kind {
        case .externalModel: return "External Model (\(prefs.externalImageEndpoint.provider.displayName))"
        case .localModel, .appleOnDevice: return kind.displayName
        }
    }

    private func imageProviderService(_ kind: AIProviderKind) -> (any WallpaperImageProvider)? {
        switch kind {
        case .localModel: return LocalImageProvider(endpoint: prefs.localImageEndpoint)
        case .externalModel: return ExternalImageProvider(endpoint: prefs.externalImageEndpoint)
        case .appleOnDevice: return nil
        }
    }

    private var privacyNote: String {
        var note = "Your description is sent to \(SceneGenerator.host) when you press Compose."
        if let kind = imageProvider {
            switch kind {
            case .localModel:
                note += " The background description then goes to your Local Model at \(prefs.localImageEndpoint.baseURL)."
            case .externalModel:
                note += " The background description then goes to \(prefs.externalImageEndpoint.host)."
            case .appleOnDevice:
                break
            }
        }
        return note
    }

    /// Keys live in the Keychain, read once per appearance (not per frame).
    private func refreshKeys() {
        hasClaudeKey = KeychainStore.read(account: SceneGenerator.keychainAccount) != nil
        hasExternalKey = KeychainStore.read(account: prefs.externalImageEndpoint.provider.keychainAccount) != nil
    }

    // MARK: - Compose

    private func compose() {
        guard !trimmedBrief.isEmpty, !isComposing, hasClaudeKey else { return }
        let brief = trimmedBrief
        let provider = imageProvider.flatMap(imageProviderService)
        let context = SceneGenerator.Context(companyName: prefs.companyName,
                                             canGenerateImage: provider != nil)
        let service = SceneCompositionService(generator: prefs.sceneGenerator)
        let pixelSize = model.displayPixelSizes.first ?? CGSize(width: 2560, height: 1600)
        let existingNames = model.allScreenSavers.map(\.name)
        isComposing = true
        progress = "Asking Claude to compose the scene…"
        Task { @MainActor in
            defer {
                isComposing = false
                progress = ""
            }
            let composition: SceneComposition
            do {
                composition = try await service.compose(brief: brief, context: context)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            var scene = composition.scene { name in
                NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
            }
            let name = ScreenSaverSceneStore.uniqueName(composition.displayName, existing: existingNames)

            if let provider, let prompt = composition.imagePrompt {
                progress = "Generating the background picture…"
                do {
                    let image = try await provider.generate(WallpaperGenerationRequest(prompt: prompt, pixelSize: pixelSize))
                    let assetName = try ScreenSaverSceneStore.importAsset(data: image.data, fileExtension: image.fileExtension)
                    scene.background.source = .image(assetName: assetName)
                    scene.background.treatment.scaleMode = .fitBlur
                } catch {
                    draftAwaitingDecision = (SceneDraft(newNamed: name, scene: scene), error.localizedDescription)
                    return
                }
            }
            onComposed(SceneDraft(newNamed: name, scene: scene))
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var decisionPresented: Binding<Bool> {
        Binding(get: { draftAwaitingDecision != nil }, set: { if !$0 { draftAwaitingDecision = nil } })
    }
}

/// "Compose with Claude" (Anthropic Messages API, JSON outputs).
struct SceneCompositionService {
    var generator: SceneGenerator
    var session: URLSession = .shared

    func compose(brief: String, context: SceneGenerator.Context) async throws -> SceneComposition {
        let apiKey = KeychainStore.read(account: SceneGenerator.keychainAccount) ?? ""
        let (data, response) = try await session.data(
            for: try generator.request(brief: brief, context: context, apiKey: apiKey))
        try LocalImageProvider.check(response, data: data)
        return try SceneGenerator.composition(fromResponse: data)
    }
}
