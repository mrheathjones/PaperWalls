import Foundation

/// The HTTP dialects a local image-generation server may speak. Draw
/// Things, Automatic1111, Forge, and SD.Next expose the Automatic1111
/// API; LocalAI and similar expose OpenAI's images endpoint.
enum LocalImageAPIFlavor: String, CaseIterable, Identifiable {
    case automatic1111
    case openAICompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic1111: return "Automatic1111 / Draw Things"
        case .openAICompatible: return "OpenAI-compatible"
        }
    }

    /// Path of the generation call, relative to the base URL.
    var generationPath: String {
        switch self {
        case .automatic1111: return "/sdapi/v1/txt2img"
        case .openAICompatible: return "/v1/images/generations"
        }
    }

    /// A cheap GET that proves the server is there and speaks this API.
    var healthPath: String {
        switch self {
        case .automatic1111: return "/sdapi/v1/sd-models"
        case .openAICompatible: return "/v1/models"
        }
    }
}

/// Width × height asked of the server. Stored as "WxH".
struct LocalImageSize: Equatable, Hashable {
    var width: Int
    var height: Int

    static let square = LocalImageSize(width: 1024, height: 1024)
    static let wide = LocalImageSize(width: 1344, height: 768)
    static let tall = LocalImageSize(width: 768, height: 1344)
    static let presets: [LocalImageSize] = [.square, .wide, .tall]

    var rawValue: String { "\(width)x\(height)" }

    var displayName: String {
        switch self {
        case .square: return "Square 1024"
        case .wide: return "Wide 1344 × 768"
        case .tall: return "Tall 768 × 1344"
        default: return "\(width) × \(height)"
        }
    }

    /// Parses "1344x768" (also "1344×768"); anything else is nil.
    init?(rawValue: String) {
        let parts = rawValue.lowercased()
            .replacingOccurrences(of: "×", with: "x")
            .split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let height = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              width >= 64, height >= 64, width <= 4096, height <= 4096 else { return nil }
        self.init(width: width, height: height)
    }

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// One image the server produced: inline bytes, or a URL to fetch.
enum LocalImagePayload: Equatable {
    case data(Data)
    case url(URL)
}

enum ImageEndpointError: LocalizedError, Equatable {
    case noEndpoint
    case invalidEndpoint(String)
    case badStatus(Int, String)
    case badPayload
    case noImages
    case missingAPIKey(String)
    case refused

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let service):
            return "No \(service) API key is saved. Add it in Settings › AI Generation."
        case .refused:
            return "Claude declined to write a prompt for that description."

        case .noEndpoint:
            return "No Local Model endpoint is set. Enter the server's address in Settings › AI Generation."
        case .invalidEndpoint(let text):
            return "“\(text)” isn’t a valid server address. Use something like http://127.0.0.1:7860."
        case .badStatus(let code, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "The server answered with HTTP \(code)." : "The server answered with HTTP \(code): \(detail.prefix(200))"
        case .badPayload:
            return "The server's reply wasn’t in the expected format."
        case .noImages:
            return "The server didn’t return an image."
        }
    }
}

/// Where and how to ask a local server for an image (pure: builds the
/// requests and reads the replies; the app does the networking).
struct LocalImageEndpoint: Equatable {
    var baseURL: String = ""
    var flavor: LocalImageAPIFlavor = .automatic1111
    var modelName: String = ""
    var imageSize: LocalImageSize = .square

    /// Reads the live preference layers.
    static func current() -> LocalImageEndpoint {
        LocalImageEndpoint(
            baseURL: ManagedPreferences.string(.aiLocalModelEndpoint) ?? "",
            flavor: ManagedPreferences.string(.aiLocalModelFlavor).flatMap(LocalImageAPIFlavor.init(rawValue:)) ?? .automatic1111,
            modelName: ManagedPreferences.string(.aiLocalModelName) ?? "",
            imageSize: ManagedPreferences.string(.aiLocalModelImageSize).flatMap(LocalImageSize.init(rawValue:)) ?? .square)
    }

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// "127.0.0.1:7860/" → http://127.0.0.1:7860. A missing scheme means
    /// plain HTTP: these are local servers.
    func resolvedBaseURL() throws -> URL {
        var text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ImageEndpointError.noEndpoint }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }
        while text.hasSuffix("/") {
            text.removeLast()
        }
        guard let url = URL(string: text), let host = url.host, !host.isEmpty else {
            throw ImageEndpointError.invalidEndpoint(baseURL)
        }
        return url
    }

    private func url(path: String) throws -> URL {
        let base = try resolvedBaseURL()
        return URL(string: base.absoluteString + path) ?? base.appendingPathComponent(path)
    }

    /// POST that asks for one image of `prompt`.
    func generationRequest(prompt: String, token: String? = nil) throws -> URLRequest {
        var request = URLRequest(url: try url(path: flavor.generationPath))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 300   // local generation can take minutes
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String: Any]
        switch flavor {
        case .automatic1111:
            body = ["prompt": prompt, "width": imageSize.width, "height": imageSize.height, "steps": 25]
            if !model.isEmpty {
                body["override_settings"] = ["sd_model_checkpoint": model]
            }
        case .openAICompatible:
            body = ["prompt": prompt, "n": 1, "size": imageSize.rawValue, "response_format": "b64_json"]
            if !model.isEmpty {
                body["model"] = model
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// GET that proves the server is reachable and speaks this API.
    func healthRequest(token: String? = nil) throws -> URLRequest {
        var request = URLRequest(url: try url(path: flavor.healthPath))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// The images in a generation reply.
    func images(fromResponse data: Data) throws -> [LocalImagePayload] {
        switch flavor {
        case .automatic1111: return try ImageAPIReply.automatic1111(data)
        case .openAICompatible: return try ImageAPIReply.openAI(data)
        }
    }

    /// Accepts bare base64 and `data:image/png;base64,…` URIs.
    static func decodeBase64(_ text: String) -> Data? {
        var body = Substring(text)
        if body.hasPrefix("data:"), let comma = body.firstIndex(of: ",") {
            body = body[body.index(after: comma)...]
        }
        return Data(base64Encoded: String(body), options: [.ignoreUnknownCharacters])
    }
}
