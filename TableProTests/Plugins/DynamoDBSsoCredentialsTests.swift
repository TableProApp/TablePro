//
//  DynamoDBSsoCredentialsTests.swift
//  TableProTests
//
//  Tests for DynamoDBSso helpers (compiled via symlink from DynamoDBDriverPlugin).
//

import Foundation
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

@Suite("DynamoDBSso - INI parsing")
struct DynamoDBSsoIniTests {
    @Test("comment lines and empty lines are skipped")
    func skipsCommentsAndEmptyLines() {
        let content = """
        # hello
        ; semicolon comment

        [default]
        region = us-east-1
        """
        let sections = DynamoDBSso.parseIniSections(content)
        #expect(sections["default"]?["region"] == "us-east-1")
        #expect(sections.count == 1)
    }

    @Test("section + key/value parsed; URL with # in value preserved")
    func preservesHashInValues() {
        let sections = DynamoDBSso.parseIniSections(modernConfig)
        #expect(sections["sso-session my-sso"]?["sso_start_url"] == "https://example.awsapps.com/start#/")
    }

    @Test("orphan key before any section is dropped")
    func dropsOrphanKey() {
        let content = "rogue = value\n[default]\nregion = us-east-1\n"
        let sections = DynamoDBSso.parseIniSections(content)
        #expect(sections["default"]?["region"] == "us-east-1")
        #expect(sections.keys.contains("rogue") == false)
    }
}

@Suite("DynamoDBSso - parseProfileSettings")
struct DynamoDBSsoProfileTests {
    @Test("modern profile resolves all fields from sso-session block")
    func resolvesModernProfile() throws {
        let s = try DynamoDBSso.parseProfileSettings(configContent: modernConfig, profileName: "my-profile")
        #expect(s.accountId == "111111111111")
        #expect(s.roleName == "AWSAdministratorAccess")
        #expect(s.startUrl == "https://example.awsapps.com/start#/")
        #expect(s.region == "eu-west-1")
        #expect(s.ssoSession == "my-sso")
    }

    @Test("legacy profile resolves fields from profile block")
    func resolvesLegacyProfile() throws {
        let s = try DynamoDBSso.parseProfileSettings(configContent: modernConfig, profileName: "legacy-profile")
        #expect(s.startUrl == "https://legacy.awsapps.com/start")
        #expect(s.region == "us-east-1")
        #expect(s.ssoSession == nil)
    }

    @Test("missing profile throws profileNotFound")
    func throwsOnMissingProfile() {
        #expect(throws: SsoCredentialError.profileNotFound("ghost")) {
            _ = try DynamoDBSso.parseProfileSettings(configContent: modernConfig, profileName: "ghost")
        }
    }

    @Test("profile missing account/role throws profileMissingFields")
    func throwsOnIncompleteProfile() {
        let content = "[profile partial]\nsso_account_id = 1\n"
        #expect(throws: SsoCredentialError.profileMissingFields(profile: "partial")) {
            _ = try DynamoDBSso.parseProfileSettings(configContent: content, profileName: "partial")
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
        #expect(throws: SsoCredentialError.sessionNotFound(profile: "orphan", session: "does-not-exist")) {
            _ = try DynamoDBSso.parseProfileSettings(configContent: content, profileName: "orphan")
        }
    }

    @Test("legacy profile missing url/region throws profileMissingUrlOrRegion")
    func throwsOnLegacyMissingUrlRegion() {
        let content = """
        [profile bare]
        sso_account_id = 1
        sso_role_name = R
        """
        #expect(throws: SsoCredentialError.profileMissingUrlOrRegion("bare")) {
            _ = try DynamoDBSso.parseProfileSettings(configContent: content, profileName: "bare")
        }
    }
}

@Suite("DynamoDBSso - readAccessToken")
struct DynamoDBSsoTokenTests {
    private func makeCacheDirectory() throws -> String {
        let dir = NSTemporaryDirectory() + "DynamoDBSsoTokenTests_\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeTokenFile(at directory: String, key: String, contents: String) throws {
        let path = (directory as NSString).appendingPathComponent(DynamoDBSso.sha1Hex(Data(key.utf8)) + ".json")
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private let modernSettings = SsoProfileSettings(
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
        let token = try DynamoDBSso.readAccessToken(
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
        #expect(throws: SsoCredentialError.tokenExpired(profile: "my-profile")) {
            _ = try DynamoDBSso.readAccessToken(
                cacheDirectory: dir, settings: modernSettings, profileName: "my-profile"
            )
        }
    }

    @Test("throws tokenCacheNotFound when file missing")
    func throwsOnMissingFile() throws {
        let dir = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(throws: SsoCredentialError.tokenCacheNotFound(profile: "my-profile")) {
            _ = try DynamoDBSso.readAccessToken(
                cacheDirectory: dir, settings: modernSettings, profileName: "my-profile"
            )
        }
    }

    @Test("throws tokenCacheMalformed when JSON is bad")
    func throwsOnMalformed() throws {
        let dir = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try writeTokenFile(at: dir, key: "my-sso", contents: "{not json")
        #expect(throws: SsoCredentialError.tokenCacheMalformed(profile: "my-profile")) {
            _ = try DynamoDBSso.readAccessToken(
                cacheDirectory: dir, settings: modernSettings, profileName: "my-profile"
            )
        }
    }

    @Test("legacy settings use startUrl as cache key")
    func legacyUsesStartUrl() throws {
        let dir = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3_600))
        let legacy = SsoProfileSettings(
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
        let token = try DynamoDBSso.readAccessToken(
            cacheDirectory: dir, settings: legacy, profileName: "legacy-profile"
        )
        #expect(token == "LEGACY")
    }
}

private final class SsoStubProtocol: URLProtocol, @unchecked Sendable {
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
        cfg.protocolClasses = [SsoStubProtocol.self]
        return URLSession(configuration: cfg)
    }
}

@Suite("DynamoDBSso - fetchRoleCredentials")
struct DynamoDBSsoFetchTests {
    private let settings = SsoProfileSettings(
        accountId: "111111111111",
        roleName: "AWSAdministratorAccess",
        startUrl: "https://example.awsapps.com/start#/",
        region: "eu-west-1",
        ssoSession: "my-sso"
    )

    @Test("200 response: URL host/path/query/header match AWS spec and credentials decode")
    func happyPath() async throws {
        SsoStubProtocol.reset()
        let exp = Int64(Date().addingTimeInterval(3_600).timeIntervalSince1970 * 1_000)
        SsoStubProtocol.body = Data(#"""
        {"roleCredentials":{"accessKeyId":"AK","secretAccessKey":"SK","sessionToken":"ST","expiration":\#(exp)}}
        """#.utf8)

        let creds = try await DynamoDBSso.fetchRoleCredentials(
            accessToken: "BEARER", settings: settings, profileName: "p",
            session: SsoStubProtocol.makeSession()
        )

        let req = try #require(SsoStubProtocol.captured)
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
    }

    @Test("401 maps to sessionUnauthorized")
    func unauthorized() async throws {
        SsoStubProtocol.reset()
        SsoStubProtocol.status = 401
        await #expect(throws: SsoCredentialError.sessionUnauthorized(profile: "p")) {
            _ = try await DynamoDBSso.fetchRoleCredentials(
                accessToken: "T", settings: settings, profileName: "p",
                session: SsoStubProtocol.makeSession()
            )
        }
    }

    @Test("403 maps to roleNotAccessible carrying role and account")
    func forbidden() async throws {
        SsoStubProtocol.reset()
        SsoStubProtocol.status = 403
        await #expect(
            throws: SsoCredentialError.roleNotAccessible(role: "AWSAdministratorAccess", account: "111111111111")
        ) {
            _ = try await DynamoDBSso.fetchRoleCredentials(
                accessToken: "T", settings: settings, profileName: "p",
                session: SsoStubProtocol.makeSession()
            )
        }
    }

    @Test("5xx maps to portalError with status code")
    func serverError() async throws {
        SsoStubProtocol.reset()
        SsoStubProtocol.status = 503
        await #expect(throws: SsoCredentialError.portalError(profile: "p", status: 503)) {
            _ = try await DynamoDBSso.fetchRoleCredentials(
                accessToken: "T", settings: settings, profileName: "p",
                session: SsoStubProtocol.makeSession()
            )
        }
    }

    @Test("network failure maps to networkFailure")
    func networkFailure() async throws {
        SsoStubProtocol.reset()
        SsoStubProtocol.simulateNetworkError = true
        await #expect(throws: SsoCredentialError.self) {
            _ = try await DynamoDBSso.fetchRoleCredentials(
                accessToken: "T", settings: settings, profileName: "p",
                session: SsoStubProtocol.makeSession()
            )
        }
    }

    @Test("200 with credentials whose expiration is past throws credentialsAlreadyExpired")
    func credentialsAlreadyExpired() async throws {
        SsoStubProtocol.reset()
        let pastMs = Int64(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1_000)
        SsoStubProtocol.body = Data(#"""
        {"roleCredentials":{"accessKeyId":"AK","secretAccessKey":"SK","sessionToken":"ST","expiration":\#(pastMs)}}
        """#.utf8)
        await #expect(throws: SsoCredentialError.credentialsAlreadyExpired(profile: "p")) {
            _ = try await DynamoDBSso.fetchRoleCredentials(
                accessToken: "T", settings: settings, profileName: "p",
                session: SsoStubProtocol.makeSession()
            )
        }
    }

    @Test("200 with malformed JSON throws responseDecodeFailed")
    func malformedResponse() async throws {
        SsoStubProtocol.reset()
        SsoStubProtocol.body = Data("not json".utf8)
        await #expect(throws: SsoCredentialError.responseDecodeFailed(profile: "p")) {
            _ = try await DynamoDBSso.fetchRoleCredentials(
                accessToken: "T", settings: settings, profileName: "p",
                session: SsoStubProtocol.makeSession()
            )
        }
    }
}
