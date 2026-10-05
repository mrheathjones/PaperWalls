import XCTest

// MARK: - Local Model endpoint (AI generation phase 3)

final class LocalImageEndpointTests: XCTestCase {
    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testBaseURLGetsASchemeAndLosesTrailingSlashes() throws {
        XCTAssertEqual(try LocalImageEndpoint(baseURL: " 127.0.0.1:7860/ ").resolvedBaseURL().absoluteString,
                       "http://127.0.0.1:7860")
        XCTAssertEqual(try LocalImageEndpoint(baseURL: "https://gpu.local/").resolvedBaseURL().absoluteString,
                       "https://gpu.local")
    }

    func testEmptyAndBrokenEndpointsAreRefused() {
        XCTAssertThrowsError(try LocalImageEndpoint(baseURL: "   ").resolvedBaseURL()) {
            XCTAssertEqual($0 as? LocalImageEndpointError, .noEndpoint)
        }
        XCTAssertThrowsError(try LocalImageEndpoint(baseURL: "http://").resolvedBaseURL()) {
            XCTAssertEqual($0 as? LocalImageEndpointError, .invalidEndpoint("http://"))
        }
        XCTAssertFalse(LocalImageEndpoint(baseURL: " ").isConfigured)
    }

    func testAutomatic1111RequestShape() throws {
        let endpoint = LocalImageEndpoint(baseURL: "127.0.0.1:7860", flavor: .automatic1111,
                                          modelName: "sdxl.safetensors", imageSize: .wide)
        let request = try endpoint.generationRequest(prompt: "mountains")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:7860/sdapi/v1/txt2img")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try json(request)
        XCTAssertEqual(body["prompt"] as? String, "mountains")
        XCTAssertEqual(body["width"] as? Int, 1344)
        XCTAssertEqual(body["height"] as? Int, 768)
        XCTAssertEqual((body["override_settings"] as? [String: Any])?["sd_model_checkpoint"] as? String, "sdxl.safetensors")
    }

    func testOpenAICompatibleRequestShape() throws {
        let endpoint = LocalImageEndpoint(baseURL: "http://localhost:8080", flavor: .openAICompatible,
                                          modelName: "", imageSize: .square)
        let request = try endpoint.generationRequest(prompt: "a lake", token: "secret")
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:8080/v1/images/generations")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let body = try json(request)
        XCTAssertEqual(body["size"] as? String, "1024x1024")
        XCTAssertEqual(body["response_format"] as? String, "b64_json")
        XCTAssertEqual(body["n"] as? Int, 1)
        XCTAssertNil(body["model"], "an empty model name is left to the server")
    }

    func testHealthRequestsUseEachAPIsListingCall() throws {
        XCTAssertEqual(try LocalImageEndpoint(baseURL: "h:1", flavor: .automatic1111).healthRequest().url?.path,
                       "/sdapi/v1/sd-models")
        XCTAssertEqual(try LocalImageEndpoint(baseURL: "h:1", flavor: .openAICompatible).healthRequest().url?.path,
                       "/v1/models")
    }

    func testAutomatic1111ReplyDecodesBase64WithOrWithoutDataPrefix() throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let plain = bytes.base64EncodedString()
        let reply = Data("""
        {"images": ["\(plain)", "data:image/png;base64,\(plain)"], "info": "{}"}
        """.utf8)
        let payloads = try LocalImageEndpoint(flavor: .automatic1111).images(fromResponse: reply)
        XCTAssertEqual(payloads, [.data(bytes), .data(bytes)])
    }

    func testOpenAIReplyTakesInlineBytesOrURLs() throws {
        let bytes = Data([1, 2, 3])
        let reply = Data("""
        {"data": [{"b64_json": "\(bytes.base64EncodedString())"}, {"url": "http://localhost:8080/out/1.png"}]}
        """.utf8)
        let payloads = try LocalImageEndpoint(flavor: .openAICompatible).images(fromResponse: reply)
        XCTAssertEqual(payloads, [.data(bytes), .url(URL(string: "http://localhost:8080/out/1.png")!)])
    }

    func testEmptyOrForeignRepliesAreErrors() {
        let endpoint = LocalImageEndpoint(flavor: .automatic1111)
        XCTAssertThrowsError(try endpoint.images(fromResponse: Data("{\"images\": []}".utf8))) {
            XCTAssertEqual($0 as? LocalImageEndpointError, .noImages)
        }
        XCTAssertThrowsError(try endpoint.images(fromResponse: Data("not json".utf8))) {
            XCTAssertEqual($0 as? LocalImageEndpointError, .badPayload)
        }
        XCTAssertThrowsError(try endpoint.images(fromResponse: Data("{\"data\": []}".utf8))) {
            XCTAssertEqual($0 as? LocalImageEndpointError, .badPayload, "an OpenAI-shaped reply to an A1111 endpoint")
        }
    }

    func testImageSizeRoundTripsAndRejectsNonsense() {
        XCTAssertEqual(LocalImageSize(rawValue: "1344x768"), .wide)
        XCTAssertEqual(LocalImageSize(rawValue: "768 × 1344"), .tall)
        XCTAssertEqual(LocalImageSize.wide.rawValue, "1344x768")
        XCTAssertNil(LocalImageSize(rawValue: "huge"))
        XCTAssertNil(LocalImageSize(rawValue: "10x10"))
        XCTAssertNil(LocalImageSize(rawValue: "9000x9000"))
    }
}
