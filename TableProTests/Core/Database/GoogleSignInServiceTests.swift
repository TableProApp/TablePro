import Foundation
import TableProGoogleCloud
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Google OAuth sign-in")
struct GoogleSignInServiceTests {
    private struct StubDriverError: PluginDriverError {
        let pluginErrorMessage = "Request had invalid authentication credentials."
        let pluginSqlState: String?
    }

    private struct UnrelatedError: Error {}

    private let unauthenticated = StubDriverError(pluginSqlState: "28000")

    private let spannerOAuthFields = [
        "spAuthMethod": "oauth",
        "spOAuthClientId": "spanner-client.apps.googleusercontent.com",
        "spOAuthClientSecret": "spanner-secret"
    ]

    private let bigQueryOAuthFields = [
        "bqAuthMethod": "oauth",
        "bqOAuthClientId": "bigquery-client.apps.googleusercontent.com",
        "bqOAuthClientSecret": "bigquery-secret"
    ]

    @Test("An invalid authorization failure on a Spanner OAuth connection is offered a Google sign-in")
    func claimsSpannerOAuth() {
        #expect(GoogleSignInService.claims(unauthenticated, fields: spannerOAuthFields))
        #expect(
            ConnectionSignInRegistry.provider(for: unauthenticated, fields: spannerOAuthFields)?.kind == .googleOAuth
        )
    }

    @Test("An invalid authorization failure on a BigQuery OAuth connection is offered a Google sign-in")
    func claimsBigQueryOAuth() {
        #expect(GoogleSignInService.claims(unauthenticated, fields: bigQueryOAuthFields))
        #expect(
            ConnectionSignInRegistry.provider(for: unauthenticated, fields: bigQueryOAuthFields)?.kind == .googleOAuth
        )
    }

    @Test("A connection that does not sign in with OAuth is not claimed, because a browser sign-in cannot fix it")
    func ignoresOtherAuthMethods() {
        for fields in [
            ["spAuthMethod": "serviceAccount"],
            ["spAuthMethod": "adc"],
            ["spAuthMethod": "emulator"],
            ["bqAuthMethod": "serviceAccount"],
            ["bqAuthMethod": "adc"],
            [:]
        ] {
            #expect(!GoogleSignInService.claims(unauthenticated, fields: fields))
            #expect(ConnectionSignInRegistry.provider(for: unauthenticated, fields: fields) == nil)
        }
    }

    @Test("A failure that is not invalid authorization is not claimed on an OAuth connection")
    func ignoresOtherFailures() {
        let failures: [any Error] = [
            StubDriverError(pluginSqlState: nil),
            StubDriverError(pluginSqlState: "42000"),
            StubDriverError(pluginSqlState: "08001"),
            UnrelatedError()
        ]
        for error in failures {
            #expect(!GoogleSignInService.claims(error, fields: spannerOAuthFields))
            #expect(!GoogleSignInService.claims(error, fields: bigQueryOAuthFields))
            #expect(ConnectionSignInRegistry.provider(for: error, fields: spannerOAuthFields) == nil)
        }
    }

    @Test("Each engine's OAuth fields select their own auth method key")
    func findsTheActiveFieldSet() {
        #expect(GoogleOAuthConnectionFields.active(in: spannerOAuthFields) == .spanner)
        #expect(GoogleOAuthConnectionFields.active(in: bigQueryOAuthFields) == .bigQuery)
        #expect(GoogleOAuthConnectionFields.active(in: ["spAuthMethod": "serviceAccount"]) == nil)
        #expect(GoogleOAuthConnectionFields.active(in: ["spOAuthClientId": "client"]) == nil)
    }

    @Test("The OAuth client comes from the Spanner client fields")
    func readsSpannerClient() throws {
        let client = try GoogleSignInService.client(from: spannerOAuthFields)
        #expect(client.clientId == "spanner-client.apps.googleusercontent.com")
        #expect(client.clientSecret == "spanner-secret")
    }

    @Test("The OAuth client comes from the BigQuery client fields")
    func readsBigQueryClient() throws {
        let client = try GoogleSignInService.client(from: bigQueryOAuthFields)
        #expect(client.clientId == "bigquery-client.apps.googleusercontent.com")
        #expect(client.clientSecret == "bigquery-secret")
    }

    @Test("Whitespace around the client values is dropped, so the saved token is keyed the way the driver reads it")
    func trimsClientValues() throws {
        let client = try GoogleSignInService.client(from: [
            "spAuthMethod": "oauth",
            "spOAuthClientId": "  spanner-client \n",
            "spOAuthClientSecret": "\tspanner-secret "
        ])
        #expect(client == GoogleOAuthClient(clientId: "spanner-client", clientSecret: "spanner-secret"))
    }

    @Test("A missing or blank client ID or secret is reported instead of opening the browser")
    func rejectsIncompleteClient() {
        let incomplete: [[String: String]] = [
            ["spAuthMethod": "oauth", "spOAuthClientId": "spanner-client"],
            ["spAuthMethod": "oauth", "spOAuthClientSecret": "spanner-secret"],
            ["spAuthMethod": "oauth", "spOAuthClientId": "spanner-client", "spOAuthClientSecret": "  "],
            ["bqAuthMethod": "oauth", "bqOAuthClientId": "", "bqOAuthClientSecret": "bigquery-secret"],
            ["spOAuthClientId": "spanner-client", "spOAuthClientSecret": "spanner-secret"]
        ]
        for fields in incomplete {
            #expect(throws: GoogleSignInError.clientNotConfigured) {
                try GoogleSignInService.client(from: fields)
            }
        }
    }

    @Test("The refresh token from a sign-in is saved under the client ID")
    func storesRefreshToken() throws {
        let store = GoogleInMemoryRefreshTokenStore()
        let client = GoogleOAuthClient(clientId: "spanner-client", clientSecret: "spanner-secret")
        let tokens = GoogleOAuthTokens(accessToken: "access", refreshToken: "refresh", expiresAt: Date())

        try GoogleSignInService.storeRefreshToken(from: tokens, for: client, in: store)

        #expect(store.refreshToken(for: "spanner-client") == "refresh")
    }

    @Test("A sign-in that returns no refresh token fails and saves nothing")
    func rejectsMissingRefreshToken() {
        let client = GoogleOAuthClient(clientId: "spanner-client", clientSecret: "spanner-secret")
        for refreshToken in [nil, "", "  "] as [String?] {
            let store = GoogleInMemoryRefreshTokenStore()
            let tokens = GoogleOAuthTokens(accessToken: "access", refreshToken: refreshToken, expiresAt: Date())
            #expect(throws: GoogleSignInError.noRefreshToken) {
                try GoogleSignInService.storeRefreshToken(from: tokens, for: client, in: store)
            }
            #expect(store.refreshToken(for: "spanner-client") == nil)
        }
    }

    @Test("Every sign-in failure carries a message the prompt can show")
    func describesFailures() {
        let failures: [GoogleSignInError] = [
            .clientNotConfigured,
            .noRefreshToken,
            .authentication(.oauthDenied("access_denied")),
            .authentication(.oauthTimedOut)
        ]
        for failure in failures {
            #expect(failure.errorDescription?.isEmpty == false)
        }
        #expect(
            GoogleSignInError.authentication(.oauthTimedOut).errorDescription
                == GoogleAuthErrorMessages.message(for: .oauthTimedOut)
        )
    }

    @Test("Sign-in fields fill secure values from storage without replacing ones already present")
    func mergesSecureFields() {
        let stored = [
            "spAuthMethod": "oauth",
            "spOAuthClientId": "spanner-client",
            "spServiceAccountJson": "",
            "spOAuthRefreshToken": "typed-in-form"
        ]
        let keychain = [
            "spOAuthClientSecret": "spanner-secret",
            "spServiceAccountJson": "{}",
            "spOAuthRefreshToken": "from-keychain"
        ]

        let resolved = ConnectionSignInRegistry.fields(
            stored,
            secureFieldIds: ["spOAuthClientSecret", "spServiceAccountJson", "spOAuthRefreshToken", "spMissing"],
            loadSecureField: { keychain[$0] }
        )

        #expect(resolved["spOAuthClientSecret"] == "spanner-secret")
        #expect(resolved["spServiceAccountJson"] == "{}")
        #expect(resolved["spOAuthRefreshToken"] == "typed-in-form")
        #expect(resolved["spOAuthClientId"] == "spanner-client")
        #expect(resolved["spMissing"] == nil)
    }

    @Test("A connection saved without its client secret resolves one once storage supplies it")
    func resolvedFieldsProduceAClient() throws {
        let stored = ["bqAuthMethod": "oauth", "bqOAuthClientId": "bigquery-client"]
        #expect(throws: GoogleSignInError.clientNotConfigured) {
            try GoogleSignInService.client(from: stored)
        }

        let resolved = ConnectionSignInRegistry.fields(
            stored,
            secureFieldIds: ["bqOAuthClientSecret"],
            loadSecureField: { $0 == "bqOAuthClientSecret" ? "bigquery-secret" : nil }
        )

        let client = try GoogleSignInService.client(from: resolved)
        #expect(client == GoogleOAuthClient(clientId: "bigquery-client", clientSecret: "bigquery-secret"))
    }
}
