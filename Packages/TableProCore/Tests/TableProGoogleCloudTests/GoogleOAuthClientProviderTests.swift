import Foundation
@testable import TableProGoogleCloud
import Testing

@Suite("OAuth client token provider")
struct GoogleOAuthClientProviderTests {
    private let client = GoogleOAuthClient(clientId: "desktop-client", clientSecret: "desktop-secret")
    private let okJSON = #"{"access_token":"oauth-token","expires_in":3600}"#
    private let invalidGrantJSON = #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#

    @Test("A pasted refresh token wins over a stored one")
    func pastedWins() async throws {
        let http = StubGoogleHTTPClient(json: okJSON)
        let store = GoogleInMemoryRefreshTokenStore(["desktop-client": "stored-token"])
        let provider = GoogleTokenProviders.oauthClient(client, pastedRefreshToken: " pasted-token\n", store: store, http: http)

        #expect(try await provider.accessToken() == "oauth-token")
        let fields = FormBody.fields(try #require(http.requests.first))
        #expect(fields["refresh_token"] == "pasted-token")
        #expect(fields["grant_type"] == "refresh_token")
        #expect(fields["client_id"] == "desktop-client")
        #expect(fields["client_secret"] == "desktop-secret")
    }

    @Test("The stored refresh token is used when nothing is pasted")
    func storedUsed() async throws {
        let http = StubGoogleHTTPClient(json: okJSON)
        let store = GoogleInMemoryRefreshTokenStore(["desktop-client": "stored-token"])
        for pasted in [nil, "", "   "] as [String?] {
            let provider = GoogleTokenProviders.oauthClient(client, pastedRefreshToken: pasted, store: store, http: http)
            #expect(try await provider.accessToken() == "oauth-token")
        }
        #expect(http.requests.map { FormBody.fields($0)["refresh_token"] } == ["stored-token", "stored-token", "stored-token"])
    }

    @Test("No refresh token anywhere requires sign-in without a request")
    func noTokenRequiresSignIn() async {
        let http = StubGoogleHTTPClient(json: okJSON)
        let store = GoogleInMemoryRefreshTokenStore(["other-client": "unrelated"])
        let provider = GoogleTokenProviders.oauthClient(client, pastedRefreshToken: nil, store: store, http: http)

        await #expect(throws: GoogleAuthError.signInRequired) {
            _ = try await provider.accessToken()
        }
        #expect(http.requests.isEmpty)
        #expect(GoogleAuthError.signInRequired.requiresSignIn)
    }

    @Test("invalid_grant clears the stored token and the next attempt requires sign-in")
    func invalidGrantClearsStored() async {
        let http = StubGoogleHTTPClient(status: 400, json: invalidGrantJSON)
        let store = GoogleInMemoryRefreshTokenStore(["desktop-client": "stored-token", "other-client": "keep"])
        let provider = GoogleTokenProviders.oauthClient(client, pastedRefreshToken: nil, store: store, http: http)

        await #expect(throws: GoogleAuthError.tokenRequestRejected(status: 400, oauthError: "invalid_grant")) {
            _ = try await provider.accessToken()
        }
        #expect(store.refreshToken(for: "desktop-client") == nil)
        #expect(store.refreshToken(for: "other-client") == "keep")
        await #expect(throws: GoogleAuthError.signInRequired) {
            _ = try await provider.accessToken()
        }
        #expect(http.requests.count == 1)
    }

    @Test("A rejected pasted token falls back to the token saved by sign-in")
    func rejectedPastedFallsBackToStored() async throws {
        let http = StubGoogleHTTPClient { request in
            let refreshToken = FormBody.fields(request)["refresh_token"]
            if refreshToken == "pasted" {
                return try StubGoogleHTTPClient.reply(to: request, status: 400, json: #"{"error":"invalid_grant"}"#)
            }
            return try StubGoogleHTTPClient.reply(to: request, status: 200, json: #"{"access_token":"oauth-token","expires_in":3600}"#)
        }
        let store = GoogleInMemoryRefreshTokenStore(["desktop-client": "stored-token"])
        let provider = GoogleTokenProviders.oauthClient(client, pastedRefreshToken: "pasted", store: store, http: http)

        #expect(try await provider.accessToken() == "oauth-token")
        #expect(http.requests.map { FormBody.fields($0)["refresh_token"] } == ["pasted", "stored-token"])
        #expect(store.refreshToken(for: "desktop-client") == "stored-token")
    }

    @Test("A pasted token refused as an unauthorized client falls back to the stored token")
    func unauthorizedPastedFallsBackToStored() async throws {
        let http = StubGoogleHTTPClient { request in
            let refreshToken = FormBody.fields(request)["refresh_token"]
            if refreshToken == "pasted" {
                return try StubGoogleHTTPClient.reply(to: request, status: 400, json: #"{"error":"unauthorized_client"}"#)
            }
            return try StubGoogleHTTPClient.reply(to: request, status: 200, json: #"{"access_token":"oauth-token","expires_in":3600}"#)
        }
        let store = GoogleInMemoryRefreshTokenStore(["desktop-client": "stored-token"])
        let provider = GoogleTokenProviders.oauthClient(client, pastedRefreshToken: "pasted", store: store, http: http)

        #expect(try await provider.accessToken() == "oauth-token")
        #expect(http.requests.map { FormBody.fields($0)["refresh_token"] } == ["pasted", "stored-token"])
        #expect(store.refreshToken(for: "desktop-client") == "stored-token")
    }

    @Test("A pasted token refused with HTTP 401 and a matching stored token is not retried or removed")
    func unauthorizedPastedSameAsStored() async {
        let http = StubGoogleHTTPClient(status: 401, json: #"{"error":"unauthorized_client"}"#)
        let store = GoogleInMemoryRefreshTokenStore(["desktop-client": "same"])
        let provider = GoogleTokenProviders.oauthClient(client, pastedRefreshToken: "same", store: store, http: http)

        await #expect(throws: GoogleAuthError.tokenRequestRejected(status: 401, oauthError: "unauthorized_client")) {
            _ = try await provider.accessToken()
        }
        #expect(http.requests.count == 1)
        #expect(store.refreshToken(for: "desktop-client") == "same")
    }

    @Test("A stored token refused as an unauthorized client is kept")
    func unauthorizedStoredKept() async {
        let http = StubGoogleHTTPClient(status: 400, json: #"{"error":"unauthorized_client"}"#)
        let store = GoogleInMemoryRefreshTokenStore(["desktop-client": "stored-token"])
        let provider = GoogleTokenProviders.oauthClient(client, pastedRefreshToken: "pasted", store: store, http: http)

        await #expect(throws: GoogleAuthError.tokenRequestRejected(status: 400, oauthError: "unauthorized_client")) {
            _ = try await provider.accessToken()
        }
        #expect(http.requests.count == 2)
        #expect(store.refreshToken(for: "desktop-client") == "stored-token")
    }

    @Test("A rejected pasted token with nothing stored requires sign-in and leaves the store empty")
    func rejectedPastedWithoutStored() async {
        let http = StubGoogleHTTPClient(status: 400, json: invalidGrantJSON)
        let store = GoogleInMemoryRefreshTokenStore([:])
        let provider = GoogleTokenProviders.oauthClient(client, pastedRefreshToken: "pasted", store: store, http: http)

        do {
            _ = try await provider.accessToken()
            Issue.record("Expected invalid_grant")
        } catch let error as GoogleAuthError {
            #expect(error.requiresSignIn)
            #expect(error.isAuthenticationFailure)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
        #expect(http.requests.count == 1)
        #expect(store.refreshToken(for: "desktop-client") == nil)
    }

    @Test("A token that another sign-in replaced meanwhile is not removed")
    func replacedTokenSurvives() async {
        let store = GoogleInMemoryRefreshTokenStore(["desktop-client": "old-token"])
        let http = StubGoogleHTTPClient { request in
            store.save("new-token", for: "desktop-client")
            return try StubGoogleHTTPClient.reply(
                to: request,
                status: 400,
                json: #"{"error":"invalid_grant"}"#
            )
        }
        let provider = GoogleTokenProviders.oauthClient(client, pastedRefreshToken: nil, store: store, http: http)
        _ = try? await provider.accessToken()
        #expect(store.refreshToken(for: "desktop-client") == "new-token")
    }

    @Test("Other rejections leave the stored token alone")
    func otherRejectionKeepsToken() async {
        let http = StubGoogleHTTPClient(status: 500, json: #"{"error":"internal_failure"}"#)
        let store = GoogleInMemoryRefreshTokenStore(["desktop-client": "stored-token"])
        let provider = GoogleTokenProviders.oauthClient(client, pastedRefreshToken: nil, store: store, http: http)

        await #expect(throws: GoogleAuthError.tokenRequestRejected(status: 500, oauthError: "internal_failure")) {
            _ = try await provider.accessToken()
        }
        #expect(store.refreshToken(for: "desktop-client") == "stored-token")
    }

    @Test("A rotated refresh token replaces the stored one")
    func rotatedTokenSaved() async throws {
        let http = StubGoogleHTTPClient(json: #"{"access_token":"a","expires_in":3600,"refresh_token":"rotated"}"#)
        let store = GoogleInMemoryRefreshTokenStore(["desktop-client": "stored-token"])
        let provider = GoogleTokenProviders.oauthClient(client, pastedRefreshToken: nil, store: store, http: http)

        _ = try await provider.accessToken()
        #expect(store.refreshToken(for: "desktop-client") == "rotated")
    }
}

@Suite("Auth error classification")
struct GoogleAuthErrorTests {
    @Test("requiresSignIn covers signInRequired and invalid_grant only")
    func requiresSignIn() {
        #expect(GoogleAuthError.signInRequired.requiresSignIn)
        #expect(GoogleAuthError.tokenRequestRejected(status: 400, oauthError: "invalid_grant").requiresSignIn)
        #expect(!GoogleAuthError.tokenRequestRejected(status: 400, oauthError: "invalid_client").requiresSignIn)
        #expect(!GoogleAuthError.tokenRequestRejected(status: 401, oauthError: nil).requiresSignIn)
        #expect(!GoogleAuthError.oauthTimedOut.requiresSignIn)
    }

    @Test("isAuthenticationFailure adds rejected clients and HTTP 401")
    func authenticationFailure() {
        #expect(GoogleAuthError.signInRequired.isAuthenticationFailure)
        #expect(GoogleAuthError.tokenRequestRejected(status: 400, oauthError: "invalid_grant").isAuthenticationFailure)
        #expect(GoogleAuthError.tokenRequestRejected(status: 400, oauthError: "invalid_client").isAuthenticationFailure)
        #expect(GoogleAuthError.tokenRequestRejected(status: 400, oauthError: "unauthorized_client").isAuthenticationFailure)
        #expect(GoogleAuthError.tokenRequestRejected(status: 401, oauthError: nil).isAuthenticationFailure)
        #expect(!GoogleAuthError.tokenRequestRejected(status: 500, oauthError: nil).isAuthenticationFailure)
        #expect(!GoogleAuthError.tokenRequestRejected(status: 400, oauthError: "invalid_scope").isAuthenticationFailure)
        #expect(!GoogleAuthError.malformedPrivateKey.isAuthenticationFailure)
        #expect(!GoogleAuthError.transport("timedOut").isAuthenticationFailure)
    }

    @Test("invalid_grant is described for every credential kind")
    func invalidGrantMessage() {
        let message = GoogleAuthErrorMessages.message(for: .tokenRequestRejected(status: 400, oauthError: "invalid_grant"))
        #expect(message == "Google no longer accepts these credentials. Sign in again, or renew the key or the gcloud login.")
    }
}
