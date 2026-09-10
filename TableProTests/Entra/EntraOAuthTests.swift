import Foundation
import TableProPluginKit
import Testing

@Suite("Entra ID device code flow")
struct EntraOAuthTests {
    @Test("Builds a form body with stable ordering and percent encoding")
    func encodesFormBody() throws {
        let body = EntraOAuth.formBody([
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "client_id": "abc"
        ])
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(text == "client_id=abc&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code")
    }

    @Test("Falls back to the organizations authority when no tenant is set")
    func buildsAuthorityURL() {
        #expect(
            EntraOAuth.authorityURL(tenantId: "", path: "devicecode")?.absoluteString
                == "https://login.microsoftonline.com/organizations/oauth2/v2.0/devicecode"
        )
        #expect(
            EntraOAuth.authorityURL(tenantId: "  contoso.onmicrosoft.com  ", path: "token")?.absoluteString
                == "https://login.microsoftonline.com/contoso.onmicrosoft.com/oauth2/v2.0/token"
        )
    }

    @Test("Requests the Azure SQL audience and a refresh token")
    func scopeTargetsAzureSQL() {
        #expect(EntraOAuth.sqlScope.contains("https://database.windows.net/.default"))
        #expect(EntraOAuth.sqlScope.contains("offline_access"))
    }

    @Test("Parses a device authorization response, defaulting the poll interval")
    func parsesDeviceAuthorization() throws {
        let json = """
        {
          "device_code": "DC",
          "user_code": "ABCD-EFGH",
          "verification_uri": "https://microsoft.com/devicelogin",
          "message": "Enter the code",
          "expires_in": 900
        }
        """
        let auth = try EntraOAuth.parseDeviceAuthorization(Data(json.utf8))
        #expect(auth.deviceCode == "DC")
        #expect(auth.userCode == "ABCD-EFGH")
        #expect(auth.verificationUri == "https://microsoft.com/devicelogin")
        #expect(auth.expiresIn == 900)
        #expect(auth.interval == 5)
    }

    @Test("Rejects a malformed device authorization response")
    func rejectsMalformedDeviceAuthorization() {
        #expect(throws: EntraOAuthError.unexpectedResponse) {
            try EntraOAuth.parseDeviceAuthorization(Data("{}".utf8))
        }
    }

    @Test("Maps each polling outcome to its own state")
    func interpretsPollingStates() {
        func poll(_ code: String) -> EntraOAuth.TokenPoll {
            EntraOAuth.interpretTokenResponse(
                status: 400,
                data: Data("{\"error\":\"\(code)\"}".utf8),
                now: Date()
            )
        }
        #expect(poll("authorization_pending") == .pending)
        #expect(poll("slow_down") == .slowDown)
        #expect(poll("access_denied") == .denied)
        #expect(poll("expired_token") == .expired)
        #expect(poll("code_expired") == .expired)
        #expect(poll("something_else") == .failed("something_else"))
    }

    @Test("Turns a successful token response into an expiry date")
    func parsesToken() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let json = """
        {"access_token":"AT","refresh_token":"RT","expires_in":3600}
        """
        let poll = EntraOAuth.interpretTokenResponse(status: 200, data: Data(json.utf8), now: now)
        guard case .token(let token) = poll else {
            Issue.record("expected a token, got \(poll)")
            return
        }
        #expect(token.accessToken == "AT")
        #expect(token.refreshToken == "RT")
        #expect(token.expiresAt == now.addingTimeInterval(3_600))
    }

    @Test("A token response without expires_in still gets a bounded lifetime")
    func defaultsTokenLifetime() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let token = try #require(
            EntraOAuth.parseToken(Data("{\"access_token\":\"AT\"}".utf8), now: now)
        )
        #expect(token.refreshToken == nil)
        #expect(token.expiresAt == now.addingTimeInterval(3_600))
    }

    @Test("Only the states an interactive sign-in can fix report needsSignIn")
    func classifiesSignInNeed() {
        #expect(EntraOAuthError.signInRequired.needsSignIn)
        #expect(EntraOAuthError.interactionRequired.needsSignIn)
        #expect(EntraOAuthError.refreshRejected.needsSignIn)
        #expect(!EntraOAuthError.notConfigured.needsSignIn)
        #expect(!EntraOAuthError.network("offline").needsSignIn)
        #expect(!EntraOAuthError.accessDenied.needsSignIn)
    }
}

@Suite("Entra ID token storage")
struct EntraTokenStoreTests {
    @Test("A token counts as stale once it is inside the refresh margin")
    func appliesRefreshMargin() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fresh = EntraStoredToken(
            accessToken: "AT", refreshToken: "RT", expiresAt: now.addingTimeInterval(3_600)
        )
        let nearlyExpired = EntraStoredToken(
            accessToken: "AT", refreshToken: "RT", expiresAt: now.addingTimeInterval(60)
        )
        let expired = EntraStoredToken(
            accessToken: "AT", refreshToken: "RT", expiresAt: now.addingTimeInterval(-1)
        )
        #expect(fresh.isFresh(asOf: now))
        #expect(!nearlyExpired.isFresh(asOf: now))
        #expect(!expired.isFresh(asOf: now))
    }

    @Test("Round-trips through the in-memory store")
    func roundTripsMemoryStore() {
        let store = EntraMemoryTokenStore()
        let token = EntraStoredToken(
            accessToken: "AT", refreshToken: "RT", expiresAt: Date(timeIntervalSince1970: 2_000_000)
        )
        store.save(token, key: "k")
        #expect(store.load(key: "k") == token)
        store.clear(key: "k")
        #expect(store.load(key: "k") == nil)
    }
}

@Suite("Entra ID credential resolution")
struct EntraCredentialResolverTests {
    private let clientFields = [
        EntraField.clientId: "11111111-2222-3333-4444-555555555555",
        EntraField.tenantId: "contoso.onmicrosoft.com"
    ]

    @Test("Without a client ID the connection is not configured, not merely signed out")
    func requiresClientId() async {
        let resolver = EntraCredentialResolver(store: EntraMemoryTokenStore())
        await #expect(throws: EntraOAuthError.notConfigured) {
            _ = try await resolver.accessToken(fields: [:])
        }
    }

    @Test("With no stored token the driver asks for a sign-in")
    func requiresSignInWhenNothingStored() async {
        let resolver = EntraCredentialResolver(store: EntraMemoryTokenStore())
        await #expect(throws: EntraOAuthError.signInRequired) {
            _ = try await resolver.accessToken(fields: clientFields)
        }
    }

    @Test("A token still inside its lifetime is returned without a network call")
    func returnsFreshToken() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let key = EntraCredentialResolver.cacheKey(fields: clientFields)
        let store = EntraMemoryTokenStore(seed: [
            key: EntraStoredToken(
                accessToken: "AT", refreshToken: "RT", expiresAt: now.addingTimeInterval(3_600)
            )
        ])
        let resolver = EntraCredentialResolver(store: store)
        let token = try await resolver.accessToken(fields: clientFields, now: now)
        #expect(token == "AT")
    }

    @Test("An expired token with no refresh token needs a fresh sign-in")
    func requiresSignInWhenRefreshTokenMissing() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let key = EntraCredentialResolver.cacheKey(fields: clientFields)
        let store = EntraMemoryTokenStore(seed: [
            key: EntraStoredToken(accessToken: "AT", refreshToken: nil, expiresAt: now)
        ])
        let resolver = EntraCredentialResolver(store: store)
        await #expect(throws: EntraOAuthError.signInRequired) {
            _ = try await resolver.accessToken(fields: self.clientFields, now: now)
        }
    }

    @Test("Cache key separates directories and applications")
    func cacheKeySeparatesTenants() {
        let a = EntraCredentialResolver.cacheKey(fields: [
            EntraField.clientId: "app-1", EntraField.tenantId: "tenant-a"
        ])
        let b = EntraCredentialResolver.cacheKey(fields: [
            EntraField.clientId: "app-1", EntraField.tenantId: "tenant-b"
        ])
        let c = EntraCredentialResolver.cacheKey(fields: [
            EntraField.clientId: "app-2", EntraField.tenantId: "tenant-a"
        ])
        #expect(a != b)
        #expect(a != c)
    }

    @Test("An unset tenant resolves to the organizations authority")
    func defaultsTenant() {
        #expect(EntraAppRegistration.tenantId(from: [:]) == EntraOAuth.defaultTenant)
        #expect(EntraAppRegistration.tenantId(from: [EntraField.tenantId: "  "]) == EntraOAuth.defaultTenant)
        #expect(EntraAppRegistration.tenantId(from: [EntraField.tenantId: " t "]) == "t")
    }
}

@Suite("Entra ID connection fields")
struct EntraAuthFieldsTests {
    @Test("Both fields appear only for the driver's own Entra option")
    func gatesOnTheDriverAuthMethod() {
        let fields = EntraAuthFields.standard(gatedBy: "mssqlAuthMethod", value: "entra")
        #expect(fields.count == 2)
        for field in fields {
            #expect(field.section == .authentication)
            #expect(field.visibleWhen?.fieldId == "mssqlAuthMethod")
            #expect(field.visibleWhen?.values == ["entra"])
        }
    }

    @Test("Entra ID replaces both built-in credentials")
    func hidesUsernameAndPassword() {
        let fields = EntraAuthFields.standard(gatedBy: "mssqlAuthMethod", value: "entra")
        #expect(fields.contains { $0.id == EntraField.tenantId && $0.hidesUsername })
        #expect(fields.contains { $0.id == EntraField.clientId && $0.hidesPassword })
    }

    @Test("Neither field is secure, so no token can be persisted through the form")
    func declaresNoSecretFields() {
        let fields = EntraAuthFields.standard(gatedBy: "mssqlAuthMethod", value: "entra")
        #expect(fields.allSatisfy { !$0.isSecure })
    }
}
