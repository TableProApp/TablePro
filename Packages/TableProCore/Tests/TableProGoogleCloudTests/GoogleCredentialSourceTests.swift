import Foundation
@testable import TableProGoogleCloud
import Testing

@Suite("Credential sources")
struct GoogleCredentialSourceTests {
    private static let userLogin = """
    {"type":"authorized_user","client_id":"cid","client_secret":"cs","refresh_token":"1//rt","quota_project_id":"quota"}
    """
    private static let loginScope = "https://www.googleapis.com/auth/sqlservice.login"

    private func userLoginCredentials(
        restrictsUserLogin: Bool,
        http: StubGoogleHTTPClient
    ) throws -> GoogleCredentials {
        try GoogleTokenProviders.credentials(
            from: .applicationDefault,
            scopes: [Self.loginScope],
            restrictsUserLogin: restrictsUserLogin,
            readFile: { $0 == GoogleApplicationDefaultCredentials.defaultPath ? Data(Self.userLogin.utf8) : nil },
            environment: [:],
            http: http
        )
    }

    @Test("A restricted user login asks for the requested scopes only")
    func restrictedUserLoginNamesItsScopes() async throws {
        let http = StubGoogleHTTPClient(json: #"{"access_token":"scoped","expires_in":3600}"#)
        let credentials = try userLoginCredentials(restrictsUserLogin: true, http: http)

        #expect(try await credentials.tokenProvider.accessToken() == "scoped")
        let request = try #require(http.requests.first)
        #expect(FormBody.fields(request) == [
            "grant_type": "refresh_token",
            "client_id": "cid",
            "client_secret": "cs",
            "refresh_token": "1//rt",
            "scope": Self.loginScope
        ])
        #expect(credentials.projectHint == "quota")
    }

    @Test("An unrestricted user login keeps every scope it was granted")
    func unrestrictedUserLoginNamesNoScope() async throws {
        let http = StubGoogleHTTPClient(json: #"{"access_token":"granted","expires_in":3600}"#)
        let credentials = try userLoginCredentials(restrictsUserLogin: false, http: http)

        _ = try await credentials.tokenProvider.accessToken()
        let request = try #require(http.requests.first)
        #expect(FormBody.fields(request)["scope"] == nil)
    }

    @Test("A service account key comes from the field, pasted or as a path")
    func serviceAccountKeyFromField() throws {
        let rsa = try #require(TestRSAKey.shared)
        let json = rsa.serviceAccountJSON(projectId: "key-project")
        let http = StubGoogleHTTPClient(json: "{}")

        let pasted = try GoogleTokenProviders.credentials(
            from: .serviceAccountKey(json),
            scopes: [],
            readFile: { _ in nil },
            environment: [:],
            http: http
        )
        #expect(pasted.projectHint == "key-project")

        let read = LockedBox<[String]>([])
        let fromPath = try GoogleTokenProviders.credentials(
            from: .serviceAccountKey("/keys/sa.json"),
            scopes: [],
            readFile: { path in
                read.mutate { $0.append(path) }
                return path == "/keys/sa.json" ? Data(json.utf8) : nil
            },
            environment: [GoogleApplicationDefaultCredentials.environmentVariable: "/keys/adc.json"],
            http: http
        )
        #expect(fromPath.projectHint == "key-project")
        #expect(read.value == ["/keys/sa.json"])
    }
}

@Suite("Deadline HTTP client")
struct GoogleDeadlineHTTPClientTests {
    @Test("Each request gets what is left of the budget as it goes out")
    func remainingIsReadPerRequest() async throws {
        let http = StubGoogleHTTPClient(json: "{}")
        let remaining = LockedBox<TimeInterval>(4)
        let client = GoogleDeadlineHTTPClient(base: http) { min($0, remaining.value) }
        let url = try #require(URL(string: "https://oauth2.googleapis.com/token"))

        _ = try await client.send(URLRequest(url: url, timeoutInterval: 30))
        remaining.mutate { $0 = 1 }
        _ = try await client.send(URLRequest(url: url, timeoutInterval: 30))
        _ = try await client.send(URLRequest(url: url, timeoutInterval: 0.5))

        #expect(http.requests.map(\.timeoutInterval) == [4, 1, 0.5])
    }
}
