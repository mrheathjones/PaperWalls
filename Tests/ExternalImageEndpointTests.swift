import XCTest

// MARK: - External Model endpoint (AI generation phase 4)

final class ExternalImageEndpointTests: XCTestCase {
    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testGoogleRequestShape() throws {
        let endpoint = ExternalImageEndpoint(provider: .google, shape: .landscape)
        let request = try endpoint.generationRequest(prompt: "dunes", apiKey: "g-key")
        XCTAssertEqual(request.url?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-image:generateContent")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "g-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try json(request)
        let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["responseModalities"] as? [String], ["IMAGE"])
        XCTAssertEqual((config["imageConfig"] as? [String: Any])?["aspectRatio"] as? String, "16:9")
        let parts = try XCTUnwrap(((body["contents"] as? [[String: Any]])?.first?["parts"]) as? [[String: Any]])
        XCTAssertEqual(parts.first?["text"] as? String, "dunes")
    }

    func testOpenAIRequestShapeOmitsResponseFormat() throws {
        let endpoint = ExternalImageEndpoint(provider: .openAI, modelName: " ", shape: .portrait)
        let request = try endpoint.generationRequest(prompt: "a lighthouse", apiKey: "sk-test")
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/images/generations")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try json(request)
        XCTAssertEqual(body["model"] as? String, "gpt-image-1")
        XCTAssertEqual(body["size"] as? String, "1024x1536")
        XCTAssertNil(body["response_format"])
    }

    func testCompatibleRequestUsesTheUsersURLAndAsksForBase64() throws {
        let endpoint = ExternalImageEndpoint(provider: .openAICompatible, baseURL: "images.example.net/",
                                             modelName: "flux", shape: .square)
        let request = try endpoint.generationRequest(prompt: "x", apiKey: "k")
        XCTAssertEqual(request.url?.absoluteString, "https://images.example.net/v1/images/generations")
        let body = try json(request)
        XCTAssertEqual(body["response_format"] as? String, "b64_json")
        XCTAssertEqual(body["model"] as? String, "flux")
        XCTAssertEqual(endpoint.host, "images.example.net")
    }

    func testMissingKeyAndMissingURLAreRefused() {
        XCTAssertThrowsError(try ExternalImageEndpoint(provider: .openAI).generationRequest(prompt: "x", apiKey: "")) {
            XCTAssertEqual($0 as? ImageEndpointError, .missingAPIKey("OpenAI"))
        }
        XCTAssertFalse(ExternalImageEndpoint(provider: .openAICompatible).isConfigured)
        XCTAssertTrue(ExternalImageEndpoint(provider: .google).isConfigured)
        XCTAssertThrowsError(try ExternalImageEndpoint(provider: .openAICompatible).healthRequest(apiKey: "k"))
    }

    func testHealthRequestsHitEachServicesModelList() throws {
        XCTAssertEqual(try ExternalImageEndpoint(provider: .google).healthRequest(apiKey: "k").url?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models")
        XCTAssertEqual(try ExternalImageEndpoint(provider: .openAI).healthRequest(apiKey: "k").url?.absoluteString,
                       "https://api.openai.com/v1/models")
    }

    func testGeminiReplyDecodesInlineData() throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let reply = Data("""
        {"candidates": [{"content": {"parts": [{"text": "Here you go"},
          {"inlineData": {"mimeType": "image/png", "data": "\(bytes.base64EncodedString())"}}]}}]}
        """.utf8)
        XCTAssertEqual(try ExternalImageEndpoint(provider: .google).images(fromResponse: reply), [.data(bytes)])
        XCTAssertThrowsError(try ExternalImageEndpoint(provider: .google).images(fromResponse: Data("{\"candidates\": []}".utf8))) {
            XCTAssertEqual($0 as? ImageEndpointError, .noImages)
        }
    }

    func testMatchWallpaperResolvesFromThePixelSize() throws {
        XCTAssertEqual(ExternalImageShape.matchWallpaper.resolved(for: CGSize(width: 2560, height: 1600)), .landscape)
        XCTAssertEqual(ExternalImageShape.matchWallpaper.resolved(for: CGSize(width: 1200, height: 1920)), .portrait)
        XCTAssertEqual(ExternalImageShape.matchWallpaper.resolved(for: CGSize(width: 1024, height: 1024)), .square)
        XCTAssertEqual(ExternalImageShape.portrait.resolved(for: CGSize(width: 2560, height: 1600)), .portrait)
        let request = try ExternalImageEndpoint(provider: .openAI).generationRequest(
            prompt: "x", apiKey: "k", pixelSize: CGSize(width: 1200, height: 1920))
        XCTAssertEqual(try json(request)["size"] as? String, "1024x1536")
    }

    func testShapesMapToEachServicesVocabulary() {
        XCTAssertEqual(ExternalImageShape.landscape.openAISize, "1536x1024")
        XCTAssertEqual(ExternalImageShape.portrait.geminiAspectRatio, "9:16")
        XCTAssertEqual(ExternalImageShape.square.openAISize, "1024x1024")
    }
}

// MARK: - Prompt improver (Claude)

final class PromptImproverTests: XCTestCase {
    func testRequestCarriesTheAnthropicHeadersAndCurrentOptions() throws {
        let request = try PromptImprover().request(brief: "calm sea", apiKey: "sk-ant-test")
        XCTAssertEqual(request.url, PromptImprover.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertNil(body["thinking"], "thinking is always on for this model; the parameter is omitted")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["content"] as? String, "calm sea")
    }

    func testOlderModelsSkipTheNewOptions() throws {
        let request = try PromptImprover(model: "claude-haiku-4-5").request(brief: "x", apiKey: "k")
        XCTAssertNil(request.value(forHTTPHeaderField: "anthropic-beta"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNil(body["fallbacks"])
        XCTAssertNil(body["output_config"])
    }

    func testReplyTextIsExtractedAndUnquoted() throws {
        let reply = Data("""
        {"stop_reason": "end_turn", "content": [{"type": "thinking", "thinking": ""},
          {"type": "text", "text": "\\"A calm sea at dusk, soft teal gradient\\"\\n"}]}
        """.utf8)
        XCTAssertEqual(try PromptImprover.improvedPrompt(fromResponse: reply), "A calm sea at dusk, soft teal gradient")
    }

    func testRefusalsAndEmptyRepliesAreErrors() {
        XCTAssertThrowsError(try PromptImprover.improvedPrompt(fromResponse: Data("{\"stop_reason\": \"refusal\", \"content\": []}".utf8))) {
            XCTAssertEqual($0 as? ImageEndpointError, .refused)
        }
        XCTAssertThrowsError(try PromptImprover.improvedPrompt(fromResponse: Data("{\"content\": []}".utf8)))
        XCTAssertThrowsError(try PromptImprover().request(brief: "x", apiKey: ""))
    }
}
