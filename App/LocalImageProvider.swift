import Foundation
import ImageIO
import Security

// MARK: - Provider contract

/// What the composer asks a programmatic provider for.
struct WallpaperGenerationRequest {
    var prompt: String
    /// The wallpaper's target size, a hint for providers that take one.
    var pixelSize: CGSize
}

/// One generated image, decoded and ready to import.
struct GeneratedImage {
    var data: Data
    var fileExtension: String
    var providerKind: AIProviderKind
}

/// A generator the app can call (Local Model, External Model). Apple
/// On-Device isn't one: the system sheet owns that flow end to end.
protocol WallpaperImageProvider {
    var kind: AIProviderKind { get }
    func generate(_ request: WallpaperGenerationRequest) async throws -> GeneratedImage
}

// MARK: - Local Model

/// Talks to the user's local image server as configured in Settings.
/// Nothing is sent until the user presses Generate, and only to that
/// address.
struct LocalImageProvider: WallpaperImageProvider {
    var endpoint: LocalImageEndpoint
    var session: URLSession = .shared

    var kind: AIProviderKind { .localModel }

    static let keychainAccount = "aiLocalModelAPIKey"

    func generate(_ request: WallpaperGenerationRequest) async throws -> GeneratedImage {
        let token = KeychainStore.read(account: Self.keychainAccount)
        let urlRequest = try endpoint.generationRequest(prompt: request.prompt, token: token, pixelSize: request.pixelSize)
        let (data, response) = try await session.data(for: urlRequest)
        try Self.check(response, data: data)
        guard let first = try endpoint.images(fromResponse: data).first else {
            throw ImageEndpointError.noImages
        }
        let imageData = try await Self.bytes(for: first, session: session)
        guard let fileExtension = Self.fileExtension(for: imageData) else {
            throw ImageEndpointError.badPayload
        }
        return GeneratedImage(data: imageData, fileExtension: fileExtension, providerKind: .localModel)
    }

    /// "Connected" with a hint of what's there, or the failure.
    func testConnection() async -> Result<String, Error> {
        do {
            let token = KeychainStore.read(account: Self.keychainAccount)
            let (data, response) = try await session.data(for: try endpoint.healthRequest(token: token))
            try Self.check(response, data: data)
            return .success(Self.connectedMessage(for: data))
        } catch {
            return .failure(error)
        }
    }

    // MARK: Shared networking helpers (also used by the external provider)

    static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw ImageEndpointError.badStatus(http.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
    }

    /// Inline bytes as-is; a URL payload is fetched.
    static func bytes(for payload: LocalImagePayload, session: URLSession) async throws -> Data {
        switch payload {
        case .data(let inline):
            return inline
        case .url(let url):
            let (fetched, response) = try await session.data(from: url)
            try check(response, data: fetched)
            return fetched
        }
    }

    /// "Connected — N models available" when the listing is readable.
    static func connectedMessage(for data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return "Connected" }
        var count: Int?
        if let list = object as? [Any] {
            count = list.count
        } else if let dictionary = object as? [String: Any] {
            count = (dictionary["data"] as? [Any])?.count ?? (dictionary["models"] as? [Any])?.count
        }
        guard let count else { return "Connected" }
        return "Connected — \(count) model\(count == 1 ? "" : "s") available"
    }

    /// The asset-store extension for the bytes, from the image's own type.
    static func fileExtension(for data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else { return nil }
        switch type {
        case "public.png": return "png"
        case "public.jpeg": return "jpg"
        case "public.heic": return "heic"
        case "public.tiff": return "tiff"
        case "com.compuserve.gif": return "gif"
        default: return nil
        }
    }
}

// MARK: - Keychain

/// Generic-password items for API keys and client secrets. They never go
/// into the preference domain, which is deployed as managed plists. The
/// default service is the AI providers'; Jamf uses its own.
enum KeychainStore {
    static let service = "\(ManagedPreferences.domain).ai"

    static func read(account: String, service: String = KeychainStore.service) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores `value`; an empty value removes the item.
    @discardableResult
    static func write(account: String, value: String, service: String = KeychainStore.service) -> Bool {
        guard !value.isEmpty else { return delete(account: account, service: service) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = Data(value.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func delete(account: String, service: String = KeychainStore.service) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
