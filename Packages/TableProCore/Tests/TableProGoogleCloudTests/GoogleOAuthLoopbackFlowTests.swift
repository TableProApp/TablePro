import Foundation
@testable import TableProGoogleCloud
import Testing

private enum LoopbackBrowser {
    static func callbackURL(for authorizationURL: URL, query: [(name: String, value: String)]) -> URL? {
        guard let redirect = QueryItems.value("redirect_uri", in: authorizationURL),
              var components = URLComponents(string: redirect)
        else {
            return nil
        }
        components.path = "/"
        components.percentEncodedQuery = GoogleTokenEndpoint.formEncoded(query)
        return components.url
    }

    static func status(of url: URL?, method: String = "GET") async -> Int? {
        guard let url else { return nil }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = method
        guard let (_, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse
        else {
            return nil
        }
        return httpResponse.statusCode
    }

    static func listenerStopped(for authorizationURL: URL) async -> Bool {
        let probe = callbackURL(for: authorizationURL, query: [(name: "probe", value: "1")])
        for _ in 0..<20 {
            if await status(of: probe) == nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}

@Suite("OAuth loopback flow", .serialized)
struct GoogleOAuthLoopbackFlowTests {
    private let client = GoogleOAuthClient(clientId: "desktop.apps.googleusercontent.com", clientSecret: "desktop-secret")
    private let tokenJSON = #"{"access_token":"access","refresh_token":"1//refresh","expires_in":3600}"#

    @Test("Only the callback with the matching state completes the flow and the code is exchanged with PKCE")
    func completesWithMatchingState() async throws {
        let http = StubGoogleHTTPClient(json: tokenJSON)
        let authorizationURL = LockedBox<URL?>(nil)
        let statuses = LockedBox<[Int?]>([])
        let flow = GoogleOAuthLoopbackFlow(client: client, scopes: [], http: http, timeout: .seconds(15)) { url in
            authorizationURL.mutate { $0 = url }
            let state = QueryItems.value("state", in: url) ?? ""
            let wrongState = LoopbackBrowser.callbackURL(for: url, query: [(name: "state", value: "forged"), (name: "code", value: "evil")])
            let matching = LoopbackBrowser.callbackURL(for: url, query: [(name: "state", value: state), (name: "code", value: "4/good code")])
            let forged = await LoopbackBrowser.status(of: wrongState)
            let posted = await LoopbackBrowser.status(of: matching, method: "POST")
            let favicon = await LoopbackBrowser.status(of: matching?.appendingPathComponent("favicon.ico"))
            let accepted = await LoopbackBrowser.status(of: matching)
            statuses.mutate { $0 = [forged, posted, favicon, accepted] }
            return true
        }

        let tokens = try await flow.run()

        #expect(tokens.accessToken == "access")
        #expect(tokens.refreshToken == "1//refresh")
        #expect(statuses.value == [400, 400, 400, 200])

        let url = try #require(authorizationURL.value)
        #expect(url.host == "accounts.google.com")
        #expect(url.path == "/o/oauth2/v2/auth")
        #expect(QueryItems.value("client_id", in: url) == "desktop.apps.googleusercontent.com")
        #expect(QueryItems.value("response_type", in: url) == "code")
        #expect(QueryItems.value("scope", in: url) == GoogleOAuthClient.cloudPlatformScope)
        #expect(QueryItems.value("code_challenge_method", in: url) == "S256")
        #expect(QueryItems.value("access_type", in: url) == "offline")
        #expect(QueryItems.value("prompt", in: url) == "consent")
        let redirect = try #require(QueryItems.value("redirect_uri", in: url))
        #expect(redirect.hasPrefix("http://127.0.0.1:"))
        let challenge = try #require(QueryItems.value("code_challenge", in: url))

        let exchange = try #require(http.requests.first)
        #expect(http.requests.count == 1)
        #expect(exchange.url == GoogleOAuthClient.tokenEndpoint)
        let fields = FormBody.fields(exchange)
        #expect(fields["grant_type"] == "authorization_code")
        #expect(fields["code"] == "4/good code")
        #expect(fields["client_id"] == "desktop.apps.googleusercontent.com")
        #expect(fields["client_secret"] == "desktop-secret")
        #expect(fields["redirect_uri"] == redirect)
        let verifier = try #require(fields["code_verifier"])
        #expect(GoogleOAuthPKCE.challenge(for: verifier) == challenge)
        #expect(await LoopbackBrowser.listenerStopped(for: url))
    }

    @Test("A callback that arrives after the flow started waiting completes it")
    func callbackAfterWaiting() async throws {
        let http = StubGoogleHTTPClient(json: tokenJSON)
        let flow = GoogleOAuthLoopbackFlow(client: client, scopes: ["scope-a", "scope-b"], http: http, timeout: .seconds(15)) { url in
            let state = QueryItems.value("state", in: url) ?? ""
            #expect(QueryItems.value("scope", in: url) == "scope-a scope-b")
            Task.detached {
                try? await Task.sleep(for: .milliseconds(200))
                let callback = LoopbackBrowser.callbackURL(for: url, query: [(name: "code", value: "late"), (name: "state", value: state)])
                _ = await LoopbackBrowser.status(of: callback)
            }
            return true
        }

        let tokens = try await flow.run()
        #expect(tokens.accessToken == "access")
        #expect(FormBody.fields(try #require(http.requests.first))["code"] == "late")
    }

    @Test("An error callback with the matching state is a denial and nothing is exchanged")
    func denied() async throws {
        let http = StubGoogleHTTPClient(json: tokenJSON)
        let statuses = LockedBox<[Int?]>([])
        let flow = GoogleOAuthLoopbackFlow(client: client, scopes: [], http: http, timeout: .seconds(15)) { url in
            let state = QueryItems.value("state", in: url) ?? ""
            let callback = LoopbackBrowser.callbackURL(for: url, query: [(name: "error", value: "access_denied"), (name: "state", value: state)])
            let status = await LoopbackBrowser.status(of: callback)
            statuses.mutate { $0 = [status] }
            return true
        }

        await #expect(throws: GoogleAuthError.oauthDenied("access_denied")) {
            _ = try await flow.run()
        }
        #expect(statuses.value == [200])
        #expect(http.requests.isEmpty)
    }

    @Test("No callback before the timeout ends the flow and stops the listener")
    func timesOut() async throws {
        let http = StubGoogleHTTPClient(json: tokenJSON)
        let authorizationURL = LockedBox<URL?>(nil)
        let flow = GoogleOAuthLoopbackFlow(client: client, scopes: [], http: http, timeout: .milliseconds(300)) { url in
            authorizationURL.mutate { $0 = url }
            return true
        }

        await #expect(throws: GoogleAuthError.oauthTimedOut) {
            _ = try await flow.run()
        }
        #expect(http.requests.isEmpty)
        let url = try #require(authorizationURL.value)
        #expect(await LoopbackBrowser.listenerStopped(for: url))
    }

    @Test("Cancelling the calling task ends the flow and stops the listener")
    func cancellation() async throws {
        let http = StubGoogleHTTPClient(json: tokenJSON)
        let authorizationURL = LockedBox<URL?>(nil)
        let flow = GoogleOAuthLoopbackFlow(client: client, scopes: [], http: http, timeout: .seconds(30)) { url in
            authorizationURL.mutate { $0 = url }
            return true
        }

        let task = Task { try await flow.run() }
        for _ in 0..<250 where authorizationURL.value == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let url = try #require(authorizationURL.value)
        task.cancel()

        await #expect(throws: GoogleAuthError.oauthCancelled) {
            _ = try await task.value
        }
        #expect(http.requests.isEmpty)
        #expect(await LoopbackBrowser.listenerStopped(for: url))
    }

    @Test("A task cancelled before it starts never opens the browser")
    func cancelledBeforeStart() async {
        let opened = LockedBox(false)
        let flow = GoogleOAuthLoopbackFlow(client: client, scopes: [], http: StubGoogleHTTPClient(json: tokenJSON)) { _ in
            opened.mutate { $0 = true }
            return true
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await flow.run()
        }
        await #expect(throws: GoogleAuthError.oauthCancelled) {
            _ = try await task.value
        }
        #expect(!opened.value)
    }

    @Test("A browser that cannot be opened ends the flow")
    func browserUnavailable() async {
        let flow = GoogleOAuthLoopbackFlow(client: client, scopes: [], http: StubGoogleHTTPClient(json: tokenJSON)) { _ in
            false
        }
        await #expect(throws: GoogleAuthError.oauthCancelled) {
            _ = try await flow.run()
        }
    }
}
