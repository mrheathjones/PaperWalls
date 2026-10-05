import Foundation

/// "Improve prompt with Claude": turns a short wallpaper idea into one
/// vivid image-generation prompt through the Anthropic Messages API.
/// Claude doesn't make images; it only writes the prompt the chosen
/// image provider receives. Pure: builds the request, reads the reply.
struct PromptImprover: Equatable {
    static let defaultModel = "claude-opus-5-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let host = "api.anthropic.com"
    static let keychainAccount = "aiAnthropicAPIKey"
    static let apiVersion = "2023-06-01"
    /// `fallbacks: "default"` re-runs a declined request on another model.
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    static let systemPrompt = """
    You write prompts for an image-generation model that makes desktop wallpapers. \
    Turn the user's idea into one vivid, concrete prompt: subject, setting, lighting, \
    colour palette, mood, and style, suitable for a wide desktop background with \
    uncluttered space. Reply with the prompt only: no title, no quotes, no options, \
    no explanation, under 80 words.
    """

    var model: String = PromptImprover.defaultModel

    /// Reads the live preference layers.
    static func current() -> PromptImprover {
        let model = (ManagedPreferences.string(.aiPromptImproverModel) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return PromptImprover(model: model.isEmpty ? defaultModel : model)
    }

    /// Models that take `output_config.effort` and server-side fallbacks.
    var usesCurrentGenerationOptions: Bool {
        ["claude-opus-5", "claude-sonnet-5-5", "claude-fable-5"].contains { model.hasPrefix($0) }
    }

    func request(brief: String, apiKey: String) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw ImageEndpointError.missingAPIKey("Claude") }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": Self.systemPrompt,
            "messages": [["role": "user", "content": brief]],
        ]
        if usesCurrentGenerationOptions {
            request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
            body["output_config"] = ["effort": "low"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// The improved prompt in a Messages reply.
    static func improvedPrompt(fromResponse data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImageEndpointError.badPayload
        }
        if object["stop_reason"] as? String == "refusal" {
            throw ImageEndpointError.refused
        }
        guard let content = object["content"] as? [[String: Any]] else { throw ImageEndpointError.badPayload }
        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        guard !text.isEmpty else { throw ImageEndpointError.noImages }
        return text
    }
}
