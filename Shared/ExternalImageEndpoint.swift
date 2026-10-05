import Foundation

/// Cloud image generators the External Model option can talk to.
enum ExternalImageProviderKind: String, CaseIterable, Identifiable {
    case google
    case openAI
    case openAICompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .google: return "Google"
        case .openAI: return "OpenAI"
        case .openAICompatible: return "OpenAI-compatible"
        }
    }

    /// Sent when the model name is left empty.
    var defaultModel: String {
        switch self {
        case .google: return "gemini-2.5-flash-image"
        case .openAI: return "gpt-image-1"
        case .openAICompatible: return ""
        }
    }

    /// Where prompts go, for the privacy note. Nil for a user-chosen URL.
    var fixedHost: String? {
        switch self {
        case .google: return "generativelanguage.googleapis.com"
        case .openAI: return "api.openai.com"
        case .openAICompatible: return nil
        }
    }

    /// Keychain account holding this provider's API key.
    var keychainAccount: String {
        switch self {
        case .google: return "aiGoogleAPIKey"
        case .openAI: return "aiOpenAIAPIKey"
        case .openAICompatible: return "aiOpenAICompatibleAPIKey"
        }
    }
}

/// The rough shape asked of a cloud generator; each API has its own
/// vocabulary for it. The composer's Fill / Blur / Dim do the rest.
enum ExternalImageShape: String, CaseIterable, Identifiable {
    case square
    case landscape
    case portrait

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .square: return "Square"
        case .landscape: return "Landscape"
        case .portrait: return "Portrait"
        }
    }

    /// OpenAI `size` (the values gpt-image-1 accepts).
    var openAISize: String {
        switch self {
        case .square: return "1024x1024"
        case .landscape: return "1536x1024"
        case .portrait: return "1024x1536"
        }
    }

    /// Gemini `imageConfig.aspectRatio`.
    var geminiAspectRatio: String {
        switch self {
        case .square: return "1:1"
        case .landscape: return "16:9"
        case .portrait: return "9:16"
        }
    }
}

/// Where and how to ask a cloud service for an image (pure: builds the
/// requests and reads the replies; the app does the networking and holds
/// the key).
struct ExternalImageEndpoint: Equatable {
    var provider: ExternalImageProviderKind = .google
    /// OpenAI-compatible only: the user's base URL.
    var baseURL: String = ""
    var modelName: String = ""
    var shape: ExternalImageShape = .landscape

    static let googleBase = "https://generativelanguage.googleapis.com/v1beta"
    static let openAIBase = "https://api.openai.com"

    /// Reads the live preference layers.
    static func current() -> ExternalImageEndpoint {
        ExternalImageEndpoint(
            provider: ManagedPreferences.string(.aiExternalProvider).flatMap(ExternalImageProviderKind.init(rawValue:)) ?? .google,
            baseURL: ManagedPreferences.string(.aiExternalEndpoint) ?? "",
            modelName: ManagedPreferences.string(.aiExternalModelName) ?? "",
            shape: ManagedPreferences.string(.aiExternalImageShape).flatMap(ExternalImageShape.init(rawValue:)) ?? .landscape)
    }

    /// The model actually sent.
    var effectiveModel: String {
        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? provider.defaultModel : trimmed
    }

    /// Google and OpenAI need only a key; a compatible server needs its URL.
    var isConfigured: Bool {
        provider != .openAICompatible || !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The host prompts are sent to, for the privacy note.
    var host: String {
        if let fixed = provider.fixedHost { return fixed }
        return (try? LocalImageEndpoint(baseURL: baseURL).resolvedBaseURL().host) ?? "the server you entered"
    }

    private func compatibleBase() throws -> URL {
        // Cloud endpoints default to https when no scheme is given.
        var text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, !text.lowercased().hasPrefix("http://"), !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        return try LocalImageEndpoint(baseURL: text).resolvedBaseURL()
    }

    private func authorized(_ url: URL, apiKey: String, method: String) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw ImageEndpointError.missingAPIKey(provider.displayName) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch provider {
        case .google:
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        case .openAI, .openAICompatible:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// POST that asks for one image of `prompt`.
    func generationRequest(prompt: String, apiKey: String) throws -> URLRequest {
        let url: URL
        var body: [String: Any]
        switch provider {
        case .google:
            url = URL(string: "\(Self.googleBase)/models/\(effectiveModel):generateContent")!
            body = [
                "contents": [["parts": [["text": prompt]]]],
                "generationConfig": [
                    "responseModalities": ["IMAGE"],
                    "imageConfig": ["aspectRatio": shape.geminiAspectRatio],
                ],
            ]
        case .openAI:
            url = URL(string: "\(Self.openAIBase)/v1/images/generations")!
            // gpt-image-1 always returns base64 and rejects response_format.
            body = ["model": effectiveModel, "prompt": prompt, "n": 1, "size": shape.openAISize]
        case .openAICompatible:
            url = URL(string: try compatibleBase().absoluteString + "/v1/images/generations")!
            body = ["prompt": prompt, "n": 1, "size": shape.openAISize, "response_format": "b64_json"]
            if !effectiveModel.isEmpty {
                body["model"] = effectiveModel
            }
        }
        var request = try authorized(url, apiKey: apiKey, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// GET that proves the key works: each service's model listing.
    func healthRequest(apiKey: String) throws -> URLRequest {
        let url: URL
        switch provider {
        case .google: url = URL(string: "\(Self.googleBase)/models")!
        case .openAI: url = URL(string: "\(Self.openAIBase)/v1/models")!
        case .openAICompatible: url = URL(string: try compatibleBase().absoluteString + "/v1/models")!
        }
        var request = try authorized(url, apiKey: apiKey, method: "GET")
        request.timeoutInterval = 20
        return request
    }

    /// The images in a generation reply.
    func images(fromResponse data: Data) throws -> [LocalImagePayload] {
        switch provider {
        case .google: return try ImageAPIReply.gemini(data)
        case .openAI, .openAICompatible: return try ImageAPIReply.openAI(data)
        }
    }
}

/// Reply parsers shared by the local and external endpoints.
enum ImageAPIReply {
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImageEndpointError.badPayload
        }
        return object
    }

    /// `{"images": ["<base64>", …]}`
    static func automatic1111(_ data: Data) throws -> [LocalImagePayload] {
        guard let images = try object(data)["images"] as? [String] else { throw ImageEndpointError.badPayload }
        let payloads = images.compactMap { LocalImageEndpoint.decodeBase64($0).map(LocalImagePayload.data) }
        guard !payloads.isEmpty else { throw ImageEndpointError.noImages }
        return payloads
    }

    /// `{"data": [{"b64_json": "…"} | {"url": "…"}, …]}`
    static func openAI(_ data: Data) throws -> [LocalImagePayload] {
        guard let entries = try object(data)["data"] as? [[String: Any]] else { throw ImageEndpointError.badPayload }
        var payloads: [LocalImagePayload] = []
        for entry in entries {
            if let text = entry["b64_json"] as? String, let bytes = LocalImageEndpoint.decodeBase64(text) {
                payloads.append(.data(bytes))
            } else if let text = entry["url"] as? String, let url = URL(string: text) {
                payloads.append(.url(url))
            }
        }
        guard !payloads.isEmpty else { throw ImageEndpointError.noImages }
        return payloads
    }

    /// `{"candidates": [{"content": {"parts": [{"inlineData": {"data": "…"}}, …]}}]}`
    static func gemini(_ data: Data) throws -> [LocalImagePayload] {
        guard let candidates = try object(data)["candidates"] as? [[String: Any]] else { throw ImageEndpointError.badPayload }
        var payloads: [LocalImagePayload] = []
        for candidate in candidates {
            let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            for part in parts {
                let inline = part["inlineData"] as? [String: Any] ?? part["inline_data"] as? [String: Any]
                if let text = inline?["data"] as? String, let bytes = LocalImageEndpoint.decodeBase64(text) {
                    payloads.append(.data(bytes))
                }
            }
        }
        guard !payloads.isEmpty else { throw ImageEndpointError.noImages }
        return payloads
    }
}
