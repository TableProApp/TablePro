import Foundation
import TableProPluginKit
import Testing

private let modernConfig = """
# top-level comment

[default]
region = ap-southeast-1

[sso-session my-sso]
sso_start_url = https://example.awsapps.com/start#/
sso_region = eu-west-1
sso_registration_scopes = sso:account:access

[profile my-profile]
sso_session = my-sso
sso_account_id = 111111111111
sso_role_name = AWSAdministratorAccess
region = eu-west-1

[profile legacy-profile]
sso_start_url = https://legacy.awsapps.com/start
sso_region = us-east-1
sso_account_id = 222222222222
sso_role_name = LegacyRole
"""

@Suite("AWSSSO - INI parsing")
struct AWSSSOIniParsingTests {
    @Test("comment lines and empty lines are skipped")
    func skipsCommentsAndEmptyLines() {
        let content = """
        # hello
        ; semicolon comment

        [default]
        region = us-east-1
        """
        let sections = AWSSSO.parseIniSections(content)
        #expect(sections["default"]?["region"] == "us-east-1")
        #expect(sections.count == 1)
    }

    @Test("section + key/value parsed; URL with # in value preserved")
    func preservesHashInValues() {
        let sections = AWSSSO.parseIniSections(modernConfig)
        #expect(sections["sso-session my-sso"]?["sso_start_url"] == "https://example.awsapps.com/start#/")
    }

    @Test("orphan key before any section is dropped")
    func dropsOrphanKey() {
        let content = "rogue = value\n[default]\nregion = us-east-1\n"
        let sections = AWSSSO.parseIniSections(content)
        #expect(sections["default"]?["region"] == "us-east-1")
        #expect(sections.keys.contains("rogue") == false)
    }
}

@Suite("AWSSSO - parseProfileSettings")
struct AWSSSOProfileSettingsTests {
    @Test("modern profile resolves all fields from sso-session block")
    func resolvesModernProfile() throws {
        let s = try AWSSSO.parseProfileSettings(configContent: modernConfig, profileName: "my-profile")
        #expect(s.accountId == "111111111111")
        #expect(s.roleName == "AWSAdministratorAccess")
        #expect(s.startUrl == "https://example.awsapps.com/start#/")
        #expect(s.region == "eu-west-1")
        #expect(s.ssoSession == "my-sso")
    }

    @Test("legacy profile resolves fields from profile block")
    func resolvesLegacyProfile() throws {
        let s = try AWSSSO.parseProfileSettings(configContent: modernConfig, profileName: "legacy-profile")
        #expect(s.startUrl == "https://legacy.awsapps.com/start")
        #expect(s.region == "us-east-1")
        #expect(s.ssoSession == nil)
    }

    @Test("missing profile throws profileNotFound")
    func throwsOnMissingProfile() {
        #expect(throws: AWSSSOError.profileNotFound("ghost")) {
            _ = try AWSSSO.parseProfileSettings(configContent: modernConfig, profileName: "ghost")
        }
    }

    @Test("profile missing account/role throws profileMissingFields")
    func throwsOnIncompleteProfile() {
        let content = "[profile partial]\nsso_account_id = 1\n"
        #expect(throws: AWSSSOError.profileMissingFields(profile: "partial")) {
            _ = try AWSSSO.parseProfileSettings(configContent: content, profileName: "partial")
        }
    }

    @Test("modern profile referencing unknown session throws sessionNotFound")
    func throwsOnMissingSession() {
        let content = """
        [profile orphan]
        sso_session = does-not-exist
        sso_account_id = 1
        sso_role_name = R
        """
        #expect(throws: AWSSSOError.sessionNotFound(profile: "orphan", session: "does-not-exist")) {
            _ = try AWSSSO.parseProfileSettings(configContent: content, profileName: "orphan")
        }
    }

    @Test("legacy profile missing url/region throws profileMissingUrlOrRegion")
    func throwsOnLegacyMissingUrlRegion() {
        let content = """
        [profile bare]
        sso_account_id = 1
        sso_role_name = R
        """
        #expect(throws: AWSSSOError.profileMissingUrlOrRegion("bare")) {
            _ = try AWSSSO.parseProfileSettings(configContent: content, profileName: "bare")
        }
    }
}

@Suite("AWSSSO - readAccessToken")
struct AWSSSOTokenCacheTests {
    private func makeCacheDirectory() throws -> String {
        let dir = NSTemporaryDirectory() + "AWSSSOTokenCacheTests_\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeTokenFile(at directory: String, key: String, contents: String) throws {
        let path = (directory as NSString).appendingPathComponent(AWSSSO.sha1Hex(Data(key.utf8)) + ".json")
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private let modernSettings = AWSSSOProfileSettings(
        accountId: "111111111111",
        roleName: "AWSAdministratorAccess",
        startUrl: "https://example.awsapps.com/start#/",
        region: "eu-west-1",
        ssoSession: "my-sso"
    )

    @Test("returns accessToken when cache file is fresh")
    func returnsFreshToken() throws {
        let dir = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3_600))
        try writeTokenFile(
            at: dir,
            key: "my-sso",
            contents: #"{"accessToken":"OIDC_TOKEN","expiresAt":"\#(future)"}"#
        )
        let token = try AWSSSO.readAccessToken(
            cacheDirectory: dir, settings: modernSettings, profileName: "my-profile"
        )
        #expect(token == "OIDC_TOKEN")
    }

    @Test("throws tokenExpired when expiresAt is past")
    func throwsOnExpired() throws {
        let dir = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let past = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3_600))
        try writeTokenFile(
            at: dir, key: "my-sso",
            contents: #"{"accessToken":"OLD","expiresAt":"\#(past)"}"#
        )
        #expect(throws: AWSSSOError.tokenExpired(profile: "my-profile")) {
            _ = try AWSSSO.readAccessToken(
                cacheDirectory: dir, settings: modernSettings, profileName: "my-profile"
            )
        }
    }

    @Test("throws tokenCacheNotFound when file missing")
    func throwsOnMissingFile() throws {
        let dir = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(throws: AWSSSOError.tokenCacheNotFound(profile: "my-profile")) {
            _ = try AWSSSO.readAccessToken(
                cacheDirectory: dir, settings: modernSettings, profileName: "my-profile"
            )
        }
    }

    @Test("throws tokenCacheMalformed when JSON is bad")
    func throwsOnMalformed() throws {
        let dir = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try writeTokenFile(at: dir, key: "my-sso", contents: "{not json")
        #expect(throws: AWSSSOError.tokenCacheMalformed(profile: "my-profile")) {
            _ = try AWSSSO.readAccessToken(
                cacheDirectory: dir, settings: modernSettings, profileName: "my-profile"
            )
        }
    }

    @Test("legacy settings use startUrl as cache key")
    func legacyUsesStartUrl() throws {
        let dir = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3_600))
        let legacy = AWSSSOProfileSettings(
            accountId: "2",
            roleName: "R",
            startUrl: "https://legacy.example/start",
            region: "us-east-1",
            ssoSession: nil
        )
        try writeTokenFile(
            at: dir, key: legacy.startUrl,
            contents: #"{"accessToken":"LEGACY","expiresAt":"\#(future)"}"#
        )
        let token = try AWSSSO.readAccessToken(
            cacheDirectory: dir, settings: legacy, profileName: "legacy-profile"
        )
        #expect(token == "LEGACY")
    }
}

private final class AWSSSOStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status: Int = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var captured: URLRequest?
    nonisolated(unsafe) static var simulateNetworkError: Bool = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.captured = request
        if Self.simulateNetworkError {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        guard let url = request.url,
              let resp = HTTPURLResponse(
                url: url, statusCode: Self.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              )
        else { return }
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func reset() {
        status = 200
        body = Data()
        captured = nil
        simulateNetworkError = false
    }

    static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [AWSSSOStubProtocol.self]
        return URLSession(configuration: cfg)
    }
}

@Suite("AWSSSO - fetchRoleCredentials")
struct AWSSSOFetchTests {
    private let settings = AWSSSOProfileSettings(
        accountId: "111111111111",
        roleName: "AWSAdministratorAccess",
        startUrl: "https://example.awsapps.com/start#/",
        region: "eu-west-1",
        ssoSession: "my-sso"
    )

    @Test("200 response: URL host/path/query/header match AWS spec and credentials decode")
    func happyPath() async throws {
        AWSSSOStubProtocol.reset()
        let exp = Int64(Date().addingTimeInterval(3_600).timeIntervalSince1970 * 1_000)
        AWSSSOStubProtocol.body = Data(#"""
        {"roleCredentials":{"accessKeyId":"AK","secretAccessKey":"SK","sessionToken":"ST","expiration":\#(exp)}}
        """#.utf8)

        let creds = try await AWSSSO.fetchRoleCredentials(
            accessToken: "BEARER", settings: settings, profileName: "p",
            session: AWSSSOStubProtocol.makeSession()
        )

        let req = try #require(AWSSSOStubProtocol.captured)
        let url = try #require(req.url)
        #expect(req.httpMethod == "GET")
        #expect(url.host == "portal.sso.eu-west-1.amazonaws.com")
        #expect(url.path == "/federation/credentials")
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(queryItems.contains(URLQueryItem(name: "account_id", value: "111111111111")))
        #expect(queryItems.contains(URLQueryItem(name: "role_name", value: "AWSAdministratorAccess")))
        #expect(req.value(forHTTPHeaderField: "x-amz-sso_bearer_token") == "BEARER")
        #expect(creds.accessKeyId == "AK")
        #expect(creds.secretAccessKey == "SK")
        #expect(creds.sessionToken == "ST")
        #expect(creds.expiration > Date())
    }

    @Test("401 maps to sessionUnauthorized")
    func unauthorized() async throws {
        AWSSSOStubProtocol.reset()
        AWSSSOStubProtocol.status = 401
        await #expect(throws: AWSSSOError.sessionUnauthorized(profile: "p")) {
            _ = try await AWSSSO.fetchRoleCredentials(
                accessToken: "T", settings: settings, profileName: "p",
                session: AWSSSOStubProtocol.makeSession()
            )
        }
    }

    @Test("403 maps to roleNotAccessible carrying role and account")
    func forbidden() async throws {
        AWSSSOStubProtocol.reset()
        AWSSSOStubProtocol.status = 403
        await #expect(
            throws: AWSSSOError.roleNotAccessible(role: "AWSAdministratorAccess", account: "111111111111")
        ) {
            _ = try await AWSSSO.fetchRoleCredentials(
                accessToken: "T", settings: settings, profileName: "p",
                session: AWSSSOStubProtocol.makeSession()
            )
        }
    }

    @Test("5xx maps to portalError with status code")
    func serverError() async throws {
        AWSSSOStubProtocol.reset()
        AWSSSOStubProtocol.status = 503
        await #expect(throws: AWSSSOError.portalError(profile: "p", status: 503)) {
            _ = try await AWSSSO.fetchRoleCredentials(
                accessToken: "T", settings: settings, profileName: "p",
                session: AWSSSOStubProtocol.makeSession()
            )
        }
    }

    @Test("network failure maps to networkFailure")
    func networkFailure() async throws {
        AWSSSOStubProtocol.reset()
        AWSSSOStubProtocol.simulateNetworkError = true
        await #expect(throws: AWSSSOError.self) {
            _ = try await AWSSSO.fetchRoleCredentials(
                accessToken: "T", settings: settings, profileName: "p",
                session: AWSSSOStubProtocol.makeSession()
            )
        }
    }

    @Test("200 with credentials whose expiration is past throws credentialsAlreadyExpired")
    func credentialsAlreadyExpired() async throws {
        AWSSSOStubProtocol.reset()
        let pastMs = Int64(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1_000)
        AWSSSOStubProtocol.body = Data(#"""
        {"roleCredentials":{"accessKeyId":"AK","secretAccessKey":"SK","sessionToken":"ST","expiration":\#(pastMs)}}
        """#.utf8)
        await #expect(throws: AWSSSOError.credentialsAlreadyExpired(profile: "p")) {
            _ = try await AWSSSO.fetchRoleCredentials(
                accessToken: "T", settings: settings, profileName: "p",
                session: AWSSSOStubProtocol.makeSession()
            )
        }
    }

    @Test("200 with malformed JSON throws responseDecodeFailed")
    func malformedResponse() async throws {
        AWSSSOStubProtocol.reset()
        AWSSSOStubProtocol.body = Data("not json".utf8)
        await #expect(throws: AWSSSOError.responseDecodeFailed(profile: "p")) {
            _ = try await AWSSSO.fetchRoleCredentials(
                accessToken: "T", settings: settings, profileName: "p",
                session: AWSSSOStubProtocol.makeSession()
            )
        }
    }
}
