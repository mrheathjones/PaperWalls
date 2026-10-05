import XCTest

// MARK: - Publish to Jamf Pro (Admin mode)

final class JamfPublishTests: XCTestCase {
    private let base = URL(string: "https://acme.jamfcloud.com")!

    // MARK: Policy and server

    func testPolicyNeedsTheMasterSwitch() {
        XCTAssertFalse(JamfPublishPolicy.off.anyAllowed)
        XCTAssertFalse(JamfPublishPolicy(enabled: false, packages: true, profiles: true).canPublishPackages)
        let packagesOnly = JamfPublishPolicy(enabled: true, packages: true, profiles: false)
        XCTAssertTrue(packagesOnly.canPublishPackages)
        XCTAssertFalse(packagesOnly.canPublishProfiles)
        XCTAssertTrue(packagesOnly.anyAllowed)
        XCTAssertFalse(JamfPublishPolicy(enabled: true, packages: false, profiles: false).anyAllowed)
    }

    func testServerURLIsNormalized() {
        XCTAssertEqual(JamfServer.normalizedBaseURL("acme.jamfcloud.com")?.absoluteString, "https://acme.jamfcloud.com")
        XCTAssertEqual(JamfServer.normalizedBaseURL(" https://acme.jamfcloud.com/ ")?.absoluteString, "https://acme.jamfcloud.com")
        XCTAssertEqual(JamfServer.normalizedBaseURL("HTTPS://jss.example.org:8443/api/v1/?x=1#f")?.absoluteString,
                       "https://jss.example.org:8443")
        XCTAssertEqual(JamfServer.normalizedBaseURL("https://user:pw@acme.jamfcloud.com")?.absoluteString,
                       "https://acme.jamfcloud.com")
        XCTAssertNil(JamfServer.normalizedBaseURL(""))
        XCTAssertNil(JamfServer.normalizedBaseURL("ftp://acme.jamfcloud.com"))
        XCTAssertNil(JamfServer.normalizedBaseURL("https://"))
    }

    func testServerIsConfiguredOnlyWithURLAndClientID() {
        XCTAssertFalse(JamfServer().isConfigured)
        XCTAssertFalse(JamfServer(urlString: "acme.jamfcloud.com", clientID: "  ").isConfigured)
        XCTAssertFalse(JamfServer(urlString: "", clientID: "abc").isConfigured)
        // A bare intranet host name is a valid server.
        XCTAssertTrue(JamfServer(urlString: "jss", clientID: "abc").isConfigured)
        let server = JamfServer(urlString: "acme.jamfcloud.com", clientID: " abc ")
        XCTAssertTrue(server.isConfigured)
        XCTAssertEqual(server.trimmedClientID, "abc")
        XCTAssertEqual(server.host, "acme.jamfcloud.com")
    }

    func testEnrolledServerURLDropsTheTrailingSlash() throws {
        let plist = FileManager.default.temporaryDirectory.appendingPathComponent("jamf-\(UUID().uuidString).plist")
        try PropertyListSerialization.data(fromPropertyList: ["jss_url": "https://acme.jamfcloud.com/"], format: .xml, options: 0)
            .write(to: plist)
        defer { try? FileManager.default.removeItem(at: plist) }
        XCTAssertEqual(JamfServer.enrolledServerURL(plistPath: plist.path), "https://acme.jamfcloud.com")
        XCTAssertNil(JamfServer.enrolledServerURL(plistPath: plist.path + ".missing"))
    }

    // MARK: Authentication

    func testTokenRequestIsClientCredentialsForm() throws {
        let request = JamfAPI.tokenRequest(base: base, clientID: "id-1", clientSecret: "s3cr=t&x")
        XCTAssertEqual(request.url?.absoluteString, "https://acme.jamfcloud.com/api/oauth/token")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertEqual(body, "grant_type=client_credentials&client_id=id-1&client_secret=s3cr%3Dt%26x")
    }

    func testInvalidateAndVersionRequestsCarryTheBearerToken() {
        let invalidate = JamfAPI.invalidateTokenRequest(base: base, token: "tok")
        XCTAssertEqual(invalidate.url?.absoluteString, "https://acme.jamfcloud.com/api/v1/auth/invalidate-token")
        XCTAssertEqual(invalidate.httpMethod, "POST")
        XCTAssertEqual(invalidate.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let version = JamfAPI.versionRequest(base: base, token: "tok")
        XCTAssertEqual(version.url?.absoluteString, "https://acme.jamfcloud.com/api/v1/jamf-pro-version")
        XCTAssertEqual(version.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testTokenAndVersionParsing() throws {
        XCTAssertEqual(try JamfAPI.accessToken(from: Data(#"{"access_token":"abc","expires_in":1799}"#.utf8)), "abc")
        XCTAssertThrowsError(try JamfAPI.accessToken(from: Data(#"{"error":"invalid_client"}"#.utf8))) {
            XCTAssertEqual($0 as? JamfError, .badResponse("no access token"))
        }
        XCTAssertEqual(JamfAPI.version(from: Data(#"{"version":"11.12.1-t1727"}"#.utf8)), "11.12.1")
        XCTAssertNil(JamfAPI.version(from: Data("{}".utf8)))
    }

    // MARK: Packages

    func testPackageLookupFiltersByEscapedName() throws {
        let request = JamfAPI.packageLookupRequest(base: base, token: "tok", packageName: "Acme \"Lobby\" Savers-1.0")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/api/v1/packages")
        let filter = components.queryItems?.first { $0.name == "filter" }?.value
        XCTAssertEqual(filter, #"packageName=="Acme \"Lobby\" Savers-1.0""#)
        XCTAssertEqual(components.queryItems?.first { $0.name == "page-size" }?.value, "1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testCreatePackageBodyHasEveryRequiredField() throws {
        let request = JamfAPI.createPackageRequest(base: base, token: "tok", packageName: "Acme Savers-1.0",
                                                   fileName: "Acme Savers-1.0.pkg", notes: "n", info: "i")
        XCTAssertEqual(request.url?.absoluteString, "https://acme.jamfcloud.com/api/v1/packages")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["packageName"] as? String, "Acme Savers-1.0")
        XCTAssertEqual(body["fileName"] as? String, "Acme Savers-1.0.pkg")
        XCTAssertEqual(body["categoryId"] as? String, "-1")
        XCTAssertEqual(body["priority"] as? Int, 10)
        for key in ["fillUserTemplate", "rebootRequired", "osInstall", "suppressEula",
                    "suppressFromDock", "suppressRegistration", "suppressUpdates"] {
            XCTAssertEqual(body[key] as? Bool, false, key)
        }
    }

    func testUploadRequestIsMultipartWithTheFileField() {
        let request = JamfAPI.uploadPackageRequest(base: base, token: "tok", packageID: 42, boundary: "B")
        XCTAssertEqual(request.url?.absoluteString, "https://acme.jamfcloud.com/api/v1/packages/42/upload")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=B")
        let prefix = String(decoding: JamfAPI.multipartPrefix(boundary: "B", fileName: "A \"B\".pkg"), as: UTF8.self)
        XCTAssertTrue(prefix.hasPrefix("--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"A 'B'.pkg\"\r\n"))
        XCTAssertTrue(prefix.hasSuffix("\r\n\r\n"))
        XCTAssertEqual(String(decoding: JamfAPI.multipartSuffix(boundary: "B"), as: UTF8.self), "\r\n--B--\r\n")
    }

    func testPackageIDParsing() throws {
        XCTAssertEqual(JamfAPI.packageID(fromLookup: Data(#"{"totalCount":1,"results":[{"id":"12","packageName":"x"}]}"#.utf8)), 12)
        XCTAssertNil(JamfAPI.packageID(fromLookup: Data(#"{"totalCount":0,"results":[]}"#.utf8)))
        XCTAssertEqual(try JamfAPI.objectID(fromHrefResponse: Data(#"{"id":"7","href":"https://x/api/v1/packages/7"}"#.utf8)), 7)
        XCTAssertEqual(try JamfAPI.objectID(fromHrefResponse: Data(#"{"id":8}"#.utf8)), 8)
        XCTAssertThrowsError(try JamfAPI.objectID(fromHrefResponse: Data("{}".utf8)))
    }

    // MARK: Configuration profiles

    func testProfileLookupPercentEncodesTheName() {
        let request = JamfAPI.profileLookupRequest(base: base, token: "tok", name: "Acme – Lobby/Screen Saver")
        XCTAssertEqual(request.url?.absoluteString,
                       "https://acme.jamfcloud.com/JSSResource/osxconfigurationprofiles/name/Acme%20%E2%80%93%20Lobby%2FScreen%20Saver")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testProfileXMLEscapesThePayloadAndSendsNoScopeByDefault() throws {
        let mobileconfig = Data("<?xml version=\"1.0\"?><plist><dict><key>PayloadDisplayName</key><string>Acme &amp; Co</string></dict></plist>".utf8)
        let xml = String(decoding: JamfAPI.profileXML(name: "Acme <Lobby> & Co", description: "d", mobileconfig: mobileconfig), as: UTF8.self)
        XCTAssertTrue(xml.contains("<name>Acme &lt;Lobby&gt; &amp; Co</name>"))
        XCTAssertTrue(xml.contains("<level>computer</level>"))
        XCTAssertTrue(xml.contains("<user_removable>false</user_removable>"))
        XCTAssertTrue(xml.contains("<distribution_method>Install Automatically</distribution_method>"))
        XCTAssertFalse(xml.contains("<scope>"), "no scope element unless one is chosen")
        XCTAssertTrue(xml.contains("<payloads>&lt;?xml version=&quot;1.0&quot;?&gt;&lt;plist&gt;"))
        XCTAssertTrue(xml.contains("Acme &amp;amp; Co"))
        XCTAssertFalse(xml.contains("<plist>"))
    }

    func testProfileCreateAndUpdateRequests() throws {
        let xml = Data("<x/>".utf8)
        let create = JamfAPI.createProfileRequest(base: base, token: "tok", xml: xml)
        XCTAssertEqual(create.url?.absoluteString, "https://acme.jamfcloud.com/JSSResource/osxconfigurationprofiles/id/0")
        XCTAssertEqual(create.httpMethod, "POST")
        XCTAssertEqual(create.value(forHTTPHeaderField: "Content-Type"), "application/xml")
        XCTAssertEqual(create.httpBody, xml)
        let update = JamfAPI.updateProfileRequest(base: base, token: "tok", profileID: 5, xml: xml)
        XCTAssertEqual(update.url?.absoluteString, "https://acme.jamfcloud.com/JSSResource/osxconfigurationprofiles/id/5")
        XCTAssertEqual(update.httpMethod, "PUT")
    }

    func testProfileIDParsing() throws {
        XCTAssertEqual(JamfAPI.profileID(fromLookup: Data(#"{"os_x_configuration_profile":{"general":{"id":31,"name":"x"}}}"#.utf8)), 31)
        XCTAssertNil(JamfAPI.profileID(fromLookup: Data("{}".utf8)))
        let xml = Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><os_x_configuration_profile><id>36</id></os_x_configuration_profile>".utf8)
        XCTAssertEqual(try JamfAPI.profileID(fromClassicXML: xml), 36)
        XCTAssertThrowsError(try JamfAPI.profileID(fromClassicXML: Data("<nope/>".utf8)))
    }

    func testProfileFileNameAndDescriptionComeFromThePlist() throws {
        let plist: [String: Any] = ["PayloadDisplayName": "Acme Lobby Screen Saver", "PayloadDescription": "Selects it"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        XCTAssertEqual(ConfigurationProfileFile.displayName(in: data), "Acme Lobby Screen Saver")
        XCTAssertEqual(ConfigurationProfileFile.payloadDescription(in: data), "Selects it")
        XCTAssertNil(ConfigurationProfileFile.displayName(in: Data("garbage".utf8)))
    }

    // MARK: Categories, groups, scope

    func testCategoryAndGroupRequestsAndParsing() throws {
        let categories = JamfAPI.categoriesRequest(base: base, token: "tok")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(categories.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/api/v1/categories")
        XCTAssertEqual(components.queryItems?.first { $0.name == "sort" }?.value, "name:asc")
        XCTAssertEqual(JamfAPI.computerGroupsRequest(base: base, token: "tok").url?.absoluteString,
                       "https://acme.jamfcloud.com/api/v1/computer-groups")

        let parsed = JamfAPI.categories(from: Data(#"{"totalCount":2,"results":[{"id":"3","name":"Branding","priority":9},{"id":"x","name":"bad"}]}"#.utf8))
        XCTAssertEqual(parsed, [JamfCategory(id: 3, name: "Branding")])
        let groups = JamfAPI.computerGroups(from: Data(#"[{"id":"2","name":"Zulu","smartGroup":false},{"id":"1","name":"alpha","smartGroup":true}]"#.utf8))
        XCTAssertEqual(groups, [JamfComputerGroup(id: 1, name: "alpha", isSmart: true),
                                JamfComputerGroup(id: 2, name: "Zulu", isSmart: false)])
        XCTAssertEqual(JamfAPI.computerGroups(from: Data("{}".utf8)), [])
    }

    func testCreatePackageCarriesTheChosenCategory() throws {
        let request = JamfAPI.createPackageRequest(base: base, token: "tok", packageName: "p", fileName: "p.pkg",
                                                   notes: "", info: "", categoryID: 7)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["categoryId"] as? String, "7")
    }

    func testPackageCategoryUpdateReplaysTheRecordWithoutReadOnlyFields() throws {
        let record = Data(#"{"id":"12","packageName":"p","fileName":"p.pkg","categoryId":"-1","priority":10,"size":123,"indexed":false,"cloudTransferStatus":"READY","fillUserTemplate":false}"#.utf8)
        let request = try XCTUnwrap(JamfAPI.updatePackageCategoryRequest(base: base, token: "tok", packageID: 12,
                                                                         record: record, categoryID: 4))
        XCTAssertEqual(request.url?.absoluteString, "https://acme.jamfcloud.com/api/v1/packages/12")
        XCTAssertEqual(request.httpMethod, "PUT")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["categoryId"] as? String, "4")
        XCTAssertEqual(body["packageName"] as? String, "p")
        XCTAssertEqual(body["priority"] as? Int, 10)
        for key in ["id", "size", "indexed", "cloudTransferStatus"] {
            XCTAssertNil(body[key], key)
        }
        XCTAssertNil(JamfAPI.updatePackageCategoryRequest(base: base, token: "tok", packageID: 1, record: Data("[]".utf8), categoryID: 1))
    }

    func testProfileXMLOmitsCategoryAndScopeUnlessChosen() throws {
        let mobileconfig = Data("<plist/>".utf8)
        let plain = String(decoding: JamfAPI.profileXML(name: "n", description: "d", mobileconfig: mobileconfig), as: UTF8.self)
        XCTAssertFalse(plain.contains("<scope>"))
        XCTAssertFalse(plain.contains("<category>"))
        XCTAssertTrue(plain.contains("<payloads>&lt;plist/&gt;</payloads>"))
        XCTAssertTrue(plain.hasSuffix("</os_x_configuration_profile>\n"))

        let all = String(decoding: JamfAPI.profileXML(name: "n", description: "d", mobileconfig: mobileconfig,
                                                      categoryID: 5, scope: .allComputers), as: UTF8.self)
        XCTAssertTrue(all.contains("<category><id>5</id></category>"))
        XCTAssertTrue(all.contains("<all_computers>true</all_computers>"))
        XCTAssertTrue(all.contains("<computer_groups/>"))

        let groups = String(decoding: JamfAPI.profileXML(name: "n", description: "d", mobileconfig: mobileconfig,
                                                         scope: .computerGroups([3, 9])), as: UTF8.self)
        XCTAssertTrue(groups.contains("<all_computers>false</all_computers>"))
        XCTAssertTrue(groups.contains("<computer_group><id>3</id></computer_group>"))
        XCTAssertTrue(groups.contains("<computer_group><id>9</id></computer_group>"))
        XCTAssertFalse(groups.contains("<category>"))
        // Well-formed: the category sits inside <general>, the scope outside it.
        let generalEnd = try XCTUnwrap(all.range(of: "</general>"))
        XCTAssertTrue(try XCTUnwrap(all.range(of: "<category>")).lowerBound < generalEnd.lowerBound)
        XCTAssertTrue(try XCTUnwrap(all.range(of: "<scope>")).lowerBound > generalEnd.lowerBound)
    }

    func testWebLinks() {
        XCTAssertEqual(JamfAPI.packageWebURL(base: base, packageID: 3).absoluteString,
                       "https://acme.jamfcloud.com/view/settings/computer-management/packages/3")
        XCTAssertEqual(JamfAPI.profileWebURL(base: base, profileID: 9).absoluteString,
                       "https://acme.jamfcloud.com/OSXConfigurationProfiles.html?id=9&o=r")
    }

    func testStatusErrorsExplainThemselves() {
        XCTAssertTrue(JamfError.badStatus(401, "").localizedDescription.contains("refused"))
        XCTAssertTrue(JamfError.badStatus(403, "").localizedDescription.contains("privilege"))
        XCTAssertTrue(JamfError.badStatus(404, "").localizedDescription.contains("11.5"))
        XCTAssertTrue(JamfError.badStatus(500, "boom").localizedDescription.contains("boom"))
    }
}
