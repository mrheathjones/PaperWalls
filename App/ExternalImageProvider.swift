import Foundation

/// Talks to the cloud image service configured in Settings. Nothing is
/// sent until the user presses Generate, and only to that service.
struct ExternalImageProvider: WallpaperImageProvider {
    var endpoint: ExternalImageEndpoint
    var session: URLSession = .shared

    var kind: AIProviderKind { .externalModel }

    private var apiKey: String {
        KeychainStore.read(account: endpoint.provider.keychainAccount) ?? ""
    }

    func generate(_ request: WallpaperGenerationRequest) async throws -> GeneratedImage {
        let urlRequest = try endpoint.generationRequest(prompt: request.prompt, apiKey: apiKey)
        let (data, response) = try await session.data(for: urlRequest)
        try LocalImageProvider.check(response, data: data)
        guard let first = try endpoint.images(fromResponse: data).first else {
            throw ImageEndpointError.noImages
        }
        let imageData = try await LocalImageProvider.bytes(for: first, session: session)
        guard let fileExtension = LocalImageProvider.fileExtension(for: imageData) else {
            throw ImageEndpointError.badPayload
        }
        return GeneratedImage(data: imageData, fileExtension: fileExtension, providerKind: .externalModel)
    }

    /// "Connected" with a hint of what's there, or the failure.
    func testConnection() async -> Result<String, Error> {
        do {
            let (data, response) = try await session.data(for: try endpoint.healthRequest(apiKey: apiKey))
            try LocalImageProvider.check(response, data: data)
            return .success(LocalImageProvider.connectedMessage(for: data))
        } catch {
            return .failure(error)
        }
    }
}

/// "Improve prompt with Claude" (Anthropic Messages API).
struct PromptImprovementService {
    var improver: PromptImprover
    var session: URLSession = .shared

    func improve(_ brief: String) async throws -> String {
        let apiKey = KeychainStore.read(account: PromptImprover.keychainAccount) ?? ""
        let (data, response) = try await session.data(for: try improver.request(brief: brief, apiKey: apiKey))
        try LocalImageProvider.check(response, data: data)
        return try PromptImprover.improvedPrompt(fromResponse: data)
    }
}
