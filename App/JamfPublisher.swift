import Foundation
import os

/// Where the Jamf Pro connection lives. The server URL and client ID are
/// raw keys in the user layer of the preference domain — read with
/// `CFPreferencesCopyValue` on the user layer only, so a profile or
/// `managed.json` can't inject them — and the client secret is a Keychain
/// item. None of them are `ManagedPreferenceKey`s, by design.
enum JamfConnectionStore {
    static let serverURLKey = "jamfServerURL"
    static let clientIDKey = "jamfClientID"
    static let keychainService = "\(ManagedPreferences.domain).jamf"
    static let clientSecretAccount = "jamfClientSecret"

    private static var domain: CFString { ManagedPreferences.domain as CFString }

    static var server: JamfServer {
        JamfServer(urlString: userValue(serverURLKey) ?? "", clientID: userValue(clientIDKey) ?? "")
    }

    static func save(_ server: JamfServer) {
        setUserValue(server.urlString.trimmingCharacters(in: .whitespacesAndNewlines), for: serverURLKey)
        setUserValue(server.trimmedClientID, for: clientIDKey)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    static var clientSecret: String? {
        KeychainStore.read(account: clientSecretAccount, service: keychainService)
    }

    private static func userValue(_ key: String) -> String? {
        CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
    }

    private static func setUserValue(_ value: String, for key: String) {
        CFPreferencesSetValue(key as CFString, value.isEmpty ? nil : value as CFString, domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}

/// One publish run: the pkg and/or profiles a Studio › Package build left
/// on disk, going to Jamf Pro.
struct JamfPublishRequest {
    /// nil skips the package.
    var package: URL?
    /// The Jamf Pro package record's name (the pkg file's stem).
    var packageName: String
    /// Shown in the record's Info and Notes.
    var packageInfo: String
    var packageNotes: String
    var profiles: [URL]
}

struct JamfPublishResult {
    struct Item: Identifiable {
        enum Kind { case package, profile }

        let kind: Kind
        let id: Int
        let name: String
        /// False when an existing object with the same name was updated.
        let created: Bool
        let webURL: URL

        var summary: String {
            switch kind {
            case .package: return created ? "Uploaded as package \(id)" : "Replaced the file of package \(id)"
            case .profile: return created ? "Created as profile \(id), unscoped" : "Updated profile \(id); its scope is unchanged"
            }
        }
    }

    var items: [Item]
}

/// Talks to Jamf Pro with the connection from Settings › Admin. Each call
/// obtains one OAuth access token, does its work, and invalidates the token
/// on every exit path — an abandoned token holds a database connection on
/// the server until it expires.
struct JamfClient {
    static let log = Logger(subsystem: ManagedPreferences.domain, category: "jamf")

    var server: JamfServer
    var session: URLSession = .shared

    // MARK: Test Connection

    /// "Connected to Jamf Pro 11.x at host", or why not.
    func testConnection() async -> Result<String, Error> {
        do {
            return .success(try await withToken { base, token in
                let (data, response) = try await session.data(for: JamfAPI.versionRequest(base: base, token: token))
                if let http = response as? HTTPURLResponse, http.statusCode == 403 {
                    return "Connected to \(server.host). The API role can't read the version; publishing needs its own privileges"
                }
                try Self.check(response, data: data)
                if let version = JamfAPI.version(from: data) {
                    return "Connected to Jamf Pro \(version) at \(server.host)"
                }
                return "Connected to \(server.host)"
            })
        } catch {
            return .failure(error)
        }
    }

    // MARK: Publish

    func publish(_ request: JamfPublishRequest, progress: @escaping @Sendable (String) -> Void) async throws -> JamfPublishResult {
        guard request.package != nil || !request.profiles.isEmpty else { throw JamfError.nothingSelected }
        return try await withToken { base, token in
            var items: [JamfPublishResult.Item] = []
            if let package = request.package {
                items.append(try await publishPackage(package, request: request, base: base, token: token, progress: progress))
            }
            for profile in request.profiles {
                items.append(try await publishProfile(profile, base: base, token: token, progress: progress))
            }
            return JamfPublishResult(items: items)
        }
    }

    private func publishPackage(_ file: URL, request: JamfPublishRequest, base: URL, token: String,
                                progress: @escaping @Sendable (String) -> Void) async throws -> JamfPublishResult.Item {
        let fileManager = FileManager.default
        guard fileManager.isReadableFile(atPath: file.path) else { throw JamfError.unreadableFile(file.path) }
        let fileName = file.lastPathComponent

        progress("Looking up “\(request.packageName)” in Jamf Pro…")
        let (lookupData, lookupResponse) = try await session.data(
            for: JamfAPI.packageLookupRequest(base: base, token: token, packageName: request.packageName))
        try Self.check(lookupResponse, data: lookupData)
        var created = false
        let packageID: Int
        if let existing = JamfAPI.packageID(fromLookup: lookupData) {
            packageID = existing
        } else {
            progress("Creating the package record…")
            let (data, response) = try await session.data(
                for: JamfAPI.createPackageRequest(base: base, token: token, packageName: request.packageName,
                                                  fileName: fileName, notes: request.packageNotes, info: request.packageInfo))
            try Self.check(response, data: data)
            packageID = try JamfAPI.objectID(fromHrefResponse: data)
            created = true
        }

        // The multipart body is assembled on disk so a large pkg is never
        // held in memory, then streamed by URLSession.
        let size = (try? fileManager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        progress("Uploading \(fileName) (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))…")
        let boundary = "PaperWalls-\(UUID().uuidString)"
        let body = fileManager.temporaryDirectory.appendingPathComponent("PaperWallsUpload-\(UUID().uuidString)")
        try Self.writeMultipartBody(prefix: JamfAPI.multipartPrefix(boundary: boundary, fileName: fileName),
                                    file: file,
                                    suffix: JamfAPI.multipartSuffix(boundary: boundary),
                                    to: body)
        defer { try? fileManager.removeItem(at: body) }
        let (uploadData, uploadResponse) = try await session.upload(
            for: JamfAPI.uploadPackageRequest(base: base, token: token, packageID: packageID, boundary: boundary),
            fromFile: body)
        try Self.check(uploadResponse, data: uploadData)
        Self.log.info("Uploaded \(fileName, privacy: .public) to Jamf Pro package \(packageID)")
        return JamfPublishResult.Item(kind: .package, id: packageID, name: request.packageName, created: created,
                                      webURL: JamfAPI.packageWebURL(base: base, packageID: packageID))
    }

    private func publishProfile(_ file: URL, base: URL, token: String,
                                progress: @escaping @Sendable (String) -> Void) async throws -> JamfPublishResult.Item {
        guard let mobileconfig = FileManager.default.contents(atPath: file.path) else {
            throw JamfError.unreadableFile(file.path)
        }
        let name = ConfigurationProfileFile.displayName(in: mobileconfig)
            ?? (file.deletingPathExtension().lastPathComponent)
        let description = ConfigurationProfileFile.payloadDescription(in: mobileconfig) ?? "Built by PaperWalls."
        let xml = JamfAPI.profileXML(name: name, description: description, mobileconfig: mobileconfig)

        progress("Looking up “\(name)” in Jamf Pro…")
        let (lookupData, lookupResponse) = try await session.data(
            for: JamfAPI.profileLookupRequest(base: base, token: token, name: name))
        let existingID: Int?
        if let http = lookupResponse as? HTTPURLResponse, http.statusCode == 404 {
            existingID = nil
        } else {
            try Self.check(lookupResponse, data: lookupData)
            existingID = JamfAPI.profileID(fromLookup: lookupData)
        }

        let profileID: Int
        if let existingID {
            progress("Updating profile “\(name)”…")
            let (data, response) = try await session.data(
                for: JamfAPI.updateProfileRequest(base: base, token: token, profileID: existingID, xml: xml))
            try Self.check(response, data: data)
            profileID = (try? JamfAPI.profileID(fromClassicXML: data)) ?? existingID
        } else {
            progress("Creating profile “\(name)”…")
            let (data, response) = try await session.data(
                for: JamfAPI.createProfileRequest(base: base, token: token, xml: xml))
            try Self.check(response, data: data)
            profileID = try JamfAPI.profileID(fromClassicXML: data)
        }
        Self.log.info("Published profile \(name, privacy: .public) as Jamf Pro profile \(profileID)")
        return JamfPublishResult.Item(kind: .profile, id: profileID, name: name, created: existingID == nil,
                                      webURL: JamfAPI.profileWebURL(base: base, profileID: profileID))
    }

    // MARK: Token lifecycle

    /// Obtains a token, runs `body`, and invalidates the token whether or
    /// not `body` threw.
    private func withToken<T>(_ body: (URL, String) async throws -> T) async throws -> T {
        guard let base = server.baseURL, server.isConfigured else { throw JamfError.notConfigured }
        guard let secret = JamfConnectionStore.clientSecret, !secret.isEmpty else { throw JamfError.missingClientSecret }
        let (tokenData, tokenResponse) = try await session.data(
            for: JamfAPI.tokenRequest(base: base, clientID: server.trimmedClientID, clientSecret: secret))
        try Self.check(tokenResponse, data: tokenData)
        let token = try JamfAPI.accessToken(from: tokenData)
        do {
            let value = try await body(base, token)
            await invalidate(token, base: base)
            return value
        } catch {
            await invalidate(token, base: base)
            throw error
        }
    }

    private func invalidate(_ token: String, base: URL) async {
        _ = try? await session.data(for: JamfAPI.invalidateTokenRequest(base: base, token: token))
    }

    // MARK: Helpers

    static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw JamfError.badStatus(http.statusCode, String(decoding: data.prefix(400), as: UTF8.self))
        }
    }

    /// prefix + file bytes + suffix, copied in chunks.
    static func writeMultipartBody(prefix: Data, file: URL, suffix: Data, to destination: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw JamfError.unreadableFile(destination.path)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        try output.write(contentsOf: prefix)
        while true {
            let chunk = try input.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
        }
        try output.write(contentsOf: suffix)
    }
}
