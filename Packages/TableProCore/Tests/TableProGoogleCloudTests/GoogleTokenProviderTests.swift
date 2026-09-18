import Foundation
@testable import TableProGoogleCloud
import Testing

private final class CountingTokenSource: GoogleAccessTokenSource, @unchecked Sendable {
    private let lock = NSLock()
    private var fetches = 0
    private let lifetime: TimeInterval
    private let now: GoogleClock
    private let delay: Duration
    private let failuresBeforeSuccess: Int

    init(
        lifetime: TimeInterval = 3_600,
        now: @escaping GoogleClock,
        delay: Duration = .zero,
        failuresBeforeSuccess: Int = 0
    ) {
        self.lifetime = lifetime
        self.now = now
        self.delay = delay
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    var fetchCount: Int {
        lock.withLock { fetches }
    }

    func fetchAccessToken() async throws -> GoogleAccessToken {
        let attempt = lock.withLock { () -> Int in
            fetches += 1
            return fetches
        }
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        if attempt <= failuresBeforeSuccess {
            throw GoogleAuthError.transport("timedOut")
        }
        return GoogleAccessToken(value: "token-\(attempt)", expiresAt: now().addingTimeInterval(lifetime))
    }
}

@Suite("Token cache")
struct GoogleTokenCacheTests {
    @Test("Concurrent callers share one in-flight request")
    func singleFlight() async throws {
        let clock = TestClock()
        let source = CountingTokenSource(now: clock.now, delay: .milliseconds(200))
        let provider = GoogleCachedAccessTokenProvider(source: source, now: clock.now)

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<25 {
                group.addTask { try await provider.accessToken() }
            }
            var collected: [String] = []
            for try await token in group {
                collected.append(token)
            }
            return collected
        }

        #expect(tokens.count == 25)
        #expect(Set(tokens) == ["token-1"])
        #expect(source.fetchCount == 1)
    }

    @Test("A token is reused until 300 seconds before it expires")
    func refreshMargin() async throws {
        let clock = TestClock()
        let source = CountingTokenSource(lifetime: 3_600, now: clock.now)
        let provider = GoogleCachedAccessTokenProvider(source: source, now: clock.now)

        #expect(try await provider.accessToken() == "token-1")
        clock.advance(by: 3_299)
        #expect(try await provider.accessToken() == "token-1")
        #expect(source.fetchCount == 1)
        clock.advance(by: 2)
        #expect(try await provider.accessToken() == "token-2")
        #expect(source.fetchCount == 2)
    }

    @Test("Invalidation drops the cached token")
    func invalidation() async throws {
        let clock = TestClock()
        let source = CountingTokenSource(now: clock.now)
        let provider = GoogleCachedAccessTokenProvider(source: source, now: clock.now)

        _ = try await provider.accessToken()
        await provider.invalidateCachedToken()
        #expect(try await provider.accessToken() == "token-2")
    }

    @Test("A failed refresh is not cached and the next call retries")
    func failureNotCached() async throws {
        let clock = TestClock()
        let source = CountingTokenSource(now: clock.now, failuresBeforeSuccess: 1)
        let provider = GoogleCachedAccessTokenProvider(source: source, now: clock.now)

        await #expect(throws: GoogleAuthError.transport("timedOut")) {
            _ = try await provider.accessToken()
        }
        #expect(try await provider.accessToken() == "token-2")
    }

    @Test("The public service account provider sends one request for concurrent callers")
    func publicProviderSingleFlight() async throws {
        let rsa = try #require(TestRSAKey.shared)
        let http = StubGoogleHTTPClient { request in
            try await Task.sleep(for: .milliseconds(150))
            return try StubGoogleHTTPClient.reply(to: request, status: 200, json: #"{"access_token":"shared","expires_in":3600}"#)
        }
        let key = try GoogleServiceAccountKey.parse(json: Data(rsa.serviceAccountJSON().utf8))
        let provider = GoogleTokenProviders.serviceAccount(key, scopes: [], http: http)

        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 {
                group.addTask { try await provider.accessToken() }
            }
            for try await token in group {
                #expect(token == "shared")
            }
        }
        #expect(http.requests.count == 1)
    }
}

@Suite("Token endpoint responses")
struct GoogleTokenEndpointTests {
    @Test("expires_in drives the expiry and defaults to an hour")
    func expiry() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let explicit = try GoogleTokenEndpoint.tokenResponse(
            from: Data(#"{"access_token":"a","expires_in":120}"#.utf8),
            receivedAt: start
        )
        #expect(explicit.expiresAt == start.addingTimeInterval(120))
        let missing = try GoogleTokenEndpoint.tokenResponse(from: Data(#"{"access_token":"a"}"#.utf8), receivedAt: start)
        #expect(missing.expiresAt == start.addingTimeInterval(3_600))
        let text = try GoogleTokenEndpoint.tokenResponse(
            from: Data(#"{"access_token":"a","expires_in":"60","refresh_token":"r"}"#.utf8),
            receivedAt: start
        )
        #expect(text.expiresAt == start.addingTimeInterval(60))
        #expect(text.refreshToken == "r")
    }

    @Test("A response without an access token is invalid")
    func missingAccessToken() {
        for body in [#"{"expires_in":3600}"#, #"{"access_token":""}"#, "not json"] {
            #expect(throws: GoogleAuthError.invalidTokenResponse) {
                _ = try GoogleTokenEndpoint.tokenResponse(from: Data(body.utf8), receivedAt: Date())
            }
        }
    }

    @Test("A rejection keeps the OAuth error code and drops the description")
    func rejectionKeepsErrorOnly() async throws {
        let http = StubGoogleHTTPClient(
            status: 401,
            json: #"{"error":"invalid_client","error_description":"The OAuth client was not found: secret-detail"}"#
        )
        let provider = GoogleTokenProviders.applicationDefault(
            .authorizedUser(clientId: "c", clientSecret: "s", refreshToken: "r", quotaProjectId: nil),
            scopes: [],
            http: http
        )
        do {
            _ = try await provider.accessToken()
            Issue.record("Expected a rejection")
        } catch let error as GoogleAuthError {
            #expect(error == .tokenRequestRejected(status: 401, oauthError: "invalid_client"))
            #expect(error.isAuthenticationFailure)
            #expect(!error.requiresSignIn)
            #expect(!String(describing: error).contains("secret-detail"))
        }
    }

    @Test("Unusual error codes are dropped rather than carried")
    func sanitizedErrorCode() {
        #expect(GoogleTokenEndpoint.oauthError(in: Data(#"{"error":"<script>"}"#.utf8)) == nil)
        #expect(GoogleTokenEndpoint.oauthError(in: Data(#"{"error":{"code":403,"status":"PERMISSION_DENIED"}}"#.utf8))
            == "PERMISSION_DENIED")
        #expect(GoogleTokenEndpoint.oauthError(in: Data("<html>".utf8)) == nil)
    }

    @Test("Form values are percent encoded completely")
    func formEncoding() {
        let encoded = GoogleTokenEndpoint.formEncoded([(name: "a b", value: "x&y=z+/?:é")])
        #expect(encoded == "a%20b=x%26y%3Dz%2B%2F%3F%3A%C3%A9")
    }
}

@Suite("Application default token providers")
struct GoogleApplicationDefaultProviderTests {
    @Test("authorized_user sends a refresh token grant")
    func authorizedUserGrant() async throws {
        let http = StubGoogleHTTPClient(json: #"{"access_token":"user-token","expires_in":3600}"#)
        let provider = GoogleTokenProviders.applicationDefault(
            .authorizedUser(clientId: "cid", clientSecret: "cs", refreshToken: "1//rt", quotaProjectId: "q"),
            scopes: ["ignored"],
            http: http
        )
        #expect(try await provider.accessToken() == "user-token")
        let request = try #require(http.requests.first)
        #expect(request.url == GoogleOAuthClient.tokenEndpoint)
        #expect(
            FormBody.fields(request)
                == ["grant_type": "refresh_token", "client_id": "cid", "client_secret": "cs", "refresh_token": "1//rt"]
        )
    }

    @Test("impersonated_service_account exchanges the source token at the IAM endpoint")
    func impersonation() async throws {
        let impersonationURL = try #require(
            URL(string: "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/t@p.iam.gserviceaccount.com:generateAccessToken")
        )
        let http = StubGoogleHTTPClient { request in
            if request.url == GoogleOAuthClient.tokenEndpoint {
                return try StubGoogleHTTPClient.reply(to: request, status: 200, json: #"{"access_token":"source","expires_in":3600}"#)
            }
            return try StubGoogleHTTPClient.reply(
                to: request,
                status: 200,
                json: #"{"accessToken":"impersonated","expireTime":"2099-01-01T00:00:00Z"}"#
            )
        }
        let provider = GoogleTokenProviders.applicationDefault(
            .impersonatedServiceAccount(
                impersonationURL: impersonationURL,
                source: .authorizedUser(clientId: "c", clientSecret: "s", refreshToken: "r", quotaProjectId: nil),
                quotaProjectId: nil
            ),
            scopes: ["https://www.googleapis.com/auth/spanner.data"],
            http: http
        )

        #expect(try await provider.accessToken() == "impersonated")
        let requests = http.requests
        #expect(requests.count == 2)
        let iamRequest = try #require(requests.last)
        #expect(iamRequest.url == impersonationURL)
        #expect(iamRequest.httpMethod == "POST")
        #expect(iamRequest.value(forHTTPHeaderField: "Authorization") == "Bearer source")
        let body = try #require(iamRequest.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["scope"] as? [String] == ["https://www.googleapis.com/auth/spanner.data"])
        #expect(object["lifetime"] as? String == "3600s")
        #expect(object["delegates"] == nil)
    }

    @Test("impersonated_service_account sends its delegates chain to the IAM endpoint")
    func impersonationDelegates() async throws {
        let impersonationURL = try #require(
            URL(string: "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/t@p.iam.gserviceaccount.com:generateAccessToken")
        )
        let delegates = [
            "projects/-/serviceAccounts/d1@p.iam.gserviceaccount.com",
            "projects/-/serviceAccounts/d2@p.iam.gserviceaccount.com"
        ]
        let http = StubGoogleHTTPClient { request in
            if request.url == GoogleOAuthClient.tokenEndpoint {
                return try StubGoogleHTTPClient.reply(to: request, status: 200, json: #"{"access_token":"source","expires_in":3600}"#)
            }
            return try StubGoogleHTTPClient.reply(
                to: request,
                status: 200,
                json: #"{"accessToken":"impersonated","expireTime":"2099-01-01T00:00:00Z"}"#
            )
        }
        let provider = GoogleTokenProviders.applicationDefault(
            .impersonatedServiceAccount(
                impersonationURL: impersonationURL,
                source: .authorizedUser(clientId: "c", clientSecret: "s", refreshToken: "r", quotaProjectId: nil),
                quotaProjectId: nil,
                delegates: delegates
            ),
            scopes: ["https://www.googleapis.com/auth/spanner.data"],
            http: http
        )

        #expect(try await provider.accessToken() == "impersonated")
        let iamRequest = try #require(http.requests.last)
        let body = try #require(iamRequest.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["delegates"] as? [String] == delegates)
    }

    @Test("A service account ADC file behaves like a service account key")
    func serviceAccountADC() async throws {
        let rsa = try #require(TestRSAKey.shared)
        let credentials = try GoogleApplicationDefaultCredentials.parse(json: Data(rsa.serviceAccountJSON().utf8))
        let http = StubGoogleHTTPClient(json: #"{"access_token":"sa","expires_in":3600}"#)
        let provider = GoogleTokenProviders.applicationDefault(credentials, scopes: [], http: http)
        #expect(try await provider.accessToken() == "sa")
        #expect(FormBody.fields(try #require(http.requests.first))["grant_type"] == "urn:ietf:params:oauth:grant-type:jwt-bearer")
    }
}
