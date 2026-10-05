import Foundation

/// Which Jamf Pro uploads are allowed (Settings › Admin, or forced by a
/// profile). `enabled` is the master switch; the per-kind toggles only
/// matter while it is on. The whole feature also sits behind Admin mode.
struct JamfPublishPolicy: Equatable {
    var enabled: Bool
    var packages: Bool
    var profiles: Bool

    static let off = JamfPublishPolicy(enabled: false, packages: true, profiles: true)

    var canPublishPackages: Bool { enabled && packages }
    var canPublishProfiles: Bool { enabled && profiles }
    var anyAllowed: Bool { canPublishPackages || canPublishProfiles }
}

/// The Jamf Pro server and API client typed into Settings › Admin. These are
/// deliberately not managed keys: a configuration profile must never be able
/// to point the app — and the client secret it holds — at another server.
struct JamfServer: Equatable {
    var urlString: String = ""
    var clientID: String = ""

    /// "https://acme.jamfcloud.com": scheme added when missing; path, query,
    /// credentials and trailing slash dropped so API paths never double up.
    var baseURL: URL? { Self.normalizedBaseURL(urlString) }

    var trimmedClientID: String { clientID.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isConfigured: Bool { baseURL != nil && !trimmedClientID.isEmpty }

    /// For privacy notes ("sent only to acme.jamfcloud.com").
    var host: String { baseURL?.host ?? "the Jamf Pro server" }

    static func normalizedBaseURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty else { return nil }
        components.scheme = scheme
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }

    /// Jamf Pro's own record of its URL on an enrolled Mac, for the field's
    /// placeholder. Never used without the admin typing it.
    static func enrolledServerURL(plistPath: String = "/Library/Preferences/com.jamfsoftware.jamf.plist") -> String? {
        guard let plist = NSDictionary(contentsOfFile: plistPath),
              let raw = plist["jss_url"] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }
}

enum JamfError: LocalizedError, Equatable {
    case notEnabled
    case notConfigured
    case missingClientSecret
    case badStatus(Int, String)
    case badResponse(String)
    case unreadableFile(String)
    case nothingSelected

    var errorDescription: String? {
        switch self {
        case .notEnabled:
            return "Publishing to Jamf Pro is turned off. Turn it on in Settings › Admin."
        case .notConfigured:
            return "No Jamf Pro server or API client is set. Add them in Settings › Admin."
        case .missingClientSecret:
            return "No client secret is saved. Paste the API client's secret in Settings › Admin."
        case .badStatus(let code, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let hint: String
            switch code {
            case 401: hint = " The client ID or secret was refused."
            case 403: hint = " The API role lacks a privilege this step needs."
            case 404: hint = " The endpoint isn't there — Jamf Pro 11.5 or later is needed for package uploads."
            case 409: hint = " Jamf Pro already has an object with that name."
            default: hint = ""
            }
            return detail.isEmpty
                ? "Jamf Pro answered with HTTP \(code).\(hint)"
                : "Jamf Pro answered with HTTP \(code): \(detail.prefix(240)).\(hint)"
        case .badResponse(let what):
            return "Jamf Pro's reply wasn't in the expected format (\(what))."
        case .unreadableFile(let path):
            return "Can't read \(path)."
        case .nothingSelected:
            return "Tick at least one item to publish."
        }
    }
}

/// Request builders and response parsers for the slice of the Jamf Pro API
/// the app uses. Pure functions over `URLRequest` and `Data`, so they are
/// unit-tested without a server. Networking lives in `JamfClient` (App).
///
///   POST /api/oauth/token                               client credentials → access token
///   POST /api/v1/auth/invalidate-token                  always, when done
///   GET  /api/v1/jamf-pro-version                       Test Connection
///   GET  /api/v1/packages?filter=packageName=="…"       find an existing package record
///   POST /api/v1/packages                               create the record (Create Packages)
///   POST /api/v1/packages/{id}/upload                   multipart "file" (Update + Read Packages)
///   GET  /JSSResource/osxconfigurationprofiles/name/{n} find an existing profile
///   POST /JSSResource/osxconfigurationprofiles/id/0     create (Create macOS Configuration Profiles)
///   PUT  /JSSResource/osxconfigurationprofiles/id/{id}  update (Update macOS Configuration Profiles)
enum JamfAPI {
    /// Jamf has no documented category for "none" in the create body; -1 is
    /// what its own UI sends.
    static let noCategoryID = "-1"

    // MARK: Authentication

    static func tokenRequest(base: URL, clientID: String, clientSecret: String) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent("api/oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formEncoded([("grant_type", "client_credentials"),
                                        ("client_id", clientID),
                                        ("client_secret", clientSecret)])
        return request
    }

    static func invalidateTokenRequest(base: URL, token: String) -> URLRequest {
        var request = authorized(base.appendingPathComponent("api/v1/auth/invalidate-token"), token: token)
        request.httpMethod = "POST"
        return request
    }

    static func versionRequest(base: URL, token: String) -> URLRequest {
        authorized(base.appendingPathComponent("api/v1/jamf-pro-version"), token: token)
    }

    /// `{"access_token": "…", "expires_in": 1800, …}`
    static func accessToken(from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["access_token"] as? String, !token.isEmpty else {
            throw JamfError.badResponse("no access token")
        }
        return token
    }

    /// `{"version": "11.12.0-t1234"}` → "11.12.0"
    static func version(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String, !version.isEmpty else { return nil }
        return version.split(separator: "-").first.map(String.init) ?? version
    }

    // MARK: Packages (Jamf Pro API v1)

    static func packageLookupRequest(base: URL, token: String, packageName: String) -> URLRequest {
        var components = URLComponents(url: base.appendingPathComponent("api/v1/packages"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "page", value: "0"),
            URLQueryItem(name: "page-size", value: "1"),
            URLQueryItem(name: "filter", value: "packageName==\"\(rsqlEscaped(packageName))\""),
        ]
        return authorized(components.url!, token: token)
    }

    static func createPackageRequest(base: URL, token: String, packageName: String, fileName: String,
                                     notes: String, info: String) -> URLRequest {
        var request = authorized(base.appendingPathComponent("api/v1/packages"), token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "packageName": packageName,
            "fileName": fileName,
            "categoryId": noCategoryID,
            "info": info,
            "notes": notes,
            "priority": 10,
            "fillUserTemplate": false,
            "rebootRequired": false,
            "osInstall": false,
            "suppressEula": false,
            "suppressFromDock": false,
            "suppressRegistration": false,
            "suppressUpdates": false,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// The multipart request; its body is streamed from a file built with
    /// `multipartPrefix` + the pkg bytes + `multipartSuffix`.
    static func uploadPackageRequest(base: URL, token: String, packageID: Int, boundary: String) -> URLRequest {
        var request = authorized(base.appendingPathComponent("api/v1/packages/\(packageID)/upload"), token: token)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60 * 60
        return request
    }

    static func multipartPrefix(boundary: String, fileName: String) -> Data {
        let safeName = fileName.replacingOccurrences(of: "\"", with: "'")
        return Data("""
            --\(boundary)\r
            Content-Disposition: form-data; name="file"; filename="\(safeName)"\r
            Content-Type: application/octet-stream\r
            \r

            """.utf8)
    }

    static func multipartSuffix(boundary: String) -> Data {
        Data("\r\n--\(boundary)--\r\n".utf8)
    }

    /// `{"totalCount": 1, "results": [{"id": "12", …}]}` → 12 (nil when none).
    static func packageID(fromLookup data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]],
              let first = results.first else { return nil }
        return intID(first["id"])
    }

    /// `{"id": "12", "href": "…"}` (v1 create responses carry ids as strings).
    static func objectID(fromHrefResponse data: Data) throws -> Int {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = intID(object["id"]) else {
            throw JamfError.badResponse("no object id")
        }
        return id
    }

    // MARK: macOS configuration profiles (Classic API)

    static func profileLookupRequest(base: URL, token: String, name: String) -> URLRequest {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: classicPathAllowed) ?? name
        return authorized(URL(string: base.absoluteString + "/JSSResource/osxconfigurationprofiles/name/\(encoded)")!,
                          token: token)
    }

    static func createProfileRequest(base: URL, token: String, xml: Data) -> URLRequest {
        var request = authorized(base.appendingPathComponent("JSSResource/osxconfigurationprofiles/id/0"), token: token)
        request.httpMethod = "POST"
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = xml
        return request
    }

    static func updateProfileRequest(base: URL, token: String, profileID: Int, xml: Data) -> URLRequest {
        var request = authorized(base.appendingPathComponent("JSSResource/osxconfigurationprofiles/id/\(profileID)"),
                                 token: token)
        request.httpMethod = "PUT"
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = xml
        return request
    }

    /// The Classic body: an unscoped, computer-level, non-removable profile
    /// that installs automatically, carrying the mobileconfig as its payload.
    /// Scoping is left to the admin in Jamf Pro.
    static func profileXML(name: String, description: String, mobileconfig: Data) -> Data {
        let payloads = String(decoding: mobileconfig, as: UTF8.self)
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <os_x_configuration_profile>
              <general>
                <name>\(xmlEscaped(name))</name>
                <description>\(xmlEscaped(description))</description>
                <distribution_method>Install Automatically</distribution_method>
                <user_removable>false</user_removable>
                <level>computer</level>
                <redeploy_on_update>Newly Assigned</redeploy_on_update>
                <payloads>\(xmlEscaped(payloads))</payloads>
              </general>
              <scope>
                <all_computers>false</all_computers>
                <all_jss_users>false</all_jss_users>
              </scope>
            </os_x_configuration_profile>

            """
        return Data(xml.utf8)
    }

    /// Classic lookups answer JSON when asked:
    /// `{"os_x_configuration_profile": {"general": {"id": 12, …}}}`
    static func profileID(fromLookup data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = object["os_x_configuration_profile"] as? [String: Any],
              let general = profile["general"] as? [String: Any] else { return nil }
        return intID(general["id"])
    }

    /// Classic writes answer XML: `<os_x_configuration_profile><id>12</id></…>`
    static func profileID(fromClassicXML data: Data) throws -> Int {
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: #"<id>\s*(\d+)\s*</id>"#, options: .regularExpression) else {
            throw JamfError.badResponse("no profile id")
        }
        let digits = text[range].filter(\.isNumber)
        guard let id = Int(digits) else { throw JamfError.badResponse("no profile id") }
        return id
    }

    // MARK: Jamf Pro web links

    static func packageWebURL(base: URL, packageID: Int) -> URL {
        base.appendingPathComponent("view/settings/computer-management/packages/\(packageID)")
    }

    static func profileWebURL(base: URL, profileID: Int) -> URL {
        URL(string: base.absoluteString + "/OSXConfigurationProfiles.html?id=\(profileID)&o=r")!
    }

    // MARK: Helpers

    private static func authorized(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func formEncoded(_ pairs: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = pairs.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    static func xmlEscaped(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.append(character)
            }
        }
        return result
    }

    /// RSQL string literal escaping (backslash and double quote).
    static func rsqlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Everything but unreserved characters is percent-encoded in Classic
    /// `/name/` paths — spaces, slashes, and non-ASCII (the en dash in
    /// "Acme – Lobby") included.
    private static let classicPathAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private static func intID(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }
}

/// Reads the bits of a `.mobileconfig` Jamf needs to name the profile.
enum ConfigurationProfileFile {
    static func displayName(in data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = plist["PayloadDisplayName"] as? String, !name.isEmpty else { return nil }
        return name
    }

    static func payloadDescription(in data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let description = plist["PayloadDescription"] as? String, !description.isEmpty else { return nil }
        return description
    }
}
