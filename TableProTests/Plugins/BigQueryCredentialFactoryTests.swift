import Foundation
import TableProGoogleCloud
import TableProPluginKit
import Testing

@Suite("BigQuery credential factory")
struct BigQueryCredentialFactoryTests {
    private static let serviceAccountJSON = """
        {"type":"service_account","client_email":"reader@key-project.iam.gserviceaccount.com",\
        "private_key":"-----BEGIN PRIVATE KEY-----\\nAAAA\\n-----END PRIVATE KEY-----\\n",\
        "project_id":"key-project"}
        """

    private static let authorizedUserJSON = """
        {"type":"authorized_user","client_id":"id","client_secret":"secret",\
        "refresh_token":"refresh","quota_project_id":"quota-project"}
        """

    private func credentials(
        _ fields: [String: String],
        password: String = "",
        files: [String: String] = [:],
        environment: [String: String] = [:]
    ) throws -> BigQueryCredentials {
        try BigQueryCredentialFactory.credentials(
            fields: fields,
            password: password,
            readFile: { path in files[path].map { Data($0.utf8) } },
            environment: environment,
            http: URLSessionGoogleHTTPClient(),
            refreshTokenStore: GoogleInMemoryRefreshTokenStore()
        )
    }

    @Test("A service account key supplies the project when none is configured")
    func serviceAccountProjectFromKey() throws {
        let resolved = try credentials(["bqServiceAccountJson": Self.serviceAccountJSON])
        #expect(resolved.projectId == "key-project")
    }

    @Test("A configured project wins over the key's project")
    func configuredProjectWins() throws {
        let resolved = try credentials([
            "bqServiceAccountJson": Self.serviceAccountJSON,
            "bqProjectId": "  billing-project "
        ])
        #expect(resolved.projectId == "billing-project")
    }

    @Test("The legacy password field still holds the key")
    func keyFromPassword() throws {
        let resolved = try credentials([:], password: Self.serviceAccountJSON)
        #expect(resolved.projectId == "key-project")
    }

    @Test("A missing key names the field")
    func missingKey() {
        #expect(throws: BigQueryConfigurationError.missingField("bqServiceAccountJson")) {
            _ = try credentials(["bqAuthMethod": "serviceAccount"])
        }
    }

    @Test("Application default credentials supply the quota project as a hint")
    func applicationDefaultProjectHint() throws {
        let resolved = try credentials(
            ["bqAuthMethod": "adc"],
            files: ["/tmp/adc.json": Self.authorizedUserJSON],
            environment: ["GOOGLE_APPLICATION_CREDENTIALS": "/tmp/adc.json"]
        )
        #expect(resolved.projectId == "quota-project")
    }

    @Test("OAuth needs a configured project")
    func oauthRequiresProject() {
        #expect(throws: BigQueryConfigurationError.missingField("bqProjectId")) {
            _ = try credentials([
                "bqAuthMethod": "oauth",
                "bqOAuthClientId": "client",
                "bqOAuthClientSecret": "secret"
            ])
        }
    }

    @Test("OAuth needs a client ID")
    func oauthRequiresClientId() {
        #expect(throws: BigQueryConfigurationError.missingField("bqOAuthClientId")) {
            _ = try credentials(["bqAuthMethod": "oauth", "bqProjectId": "p"])
        }
    }

    @Test("OAuth builds a provider without opening a browser")
    func oauthBuildsProvider() throws {
        let resolved = try credentials([
            "bqAuthMethod": "oauth",
            "bqOAuthClientId": "client",
            "bqOAuthClientSecret": "secret",
            "bqProjectId": "p"
        ])
        #expect(resolved.projectId == "p")
    }

    @Test("OAuth with no saved or pasted sign-in asks the user to sign in")
    func oauthWithoutTokenRequiresSignIn() async throws {
        let resolved = try credentials([
            "bqAuthMethod": "oauth",
            "bqOAuthClientId": "client",
            "bqOAuthClientSecret": "secret",
            "bqProjectId": "p"
        ])
        await #expect(throws: GoogleAuthError.signInRequired) {
            _ = try await resolved.tokenProvider.accessToken()
        }
    }

    @Test("An unknown auth method is refused")
    func unknownAuthMethod() {
        #expect(throws: BigQueryConfigurationError.unknownAuthMethod) {
            _ = try credentials(["bqAuthMethod": "kerberos"])
        }
    }
}

@Suite("BigQuery driver errors")
struct BigQueryErrorTests {
    @Test("A sign-in failure carries SQLSTATE 28000")
    func signInRequiredIsInvalidAuthorization() {
        let error = BigQueryError.authentication(.signInRequired)
        #expect(error.pluginSqlState == "28000")
    }

    @Test("A revoked refresh token carries SQLSTATE 28000")
    func invalidGrantIsInvalidAuthorization() {
        let error = BigQueryError.authentication(.tokenRequestRejected(status: 400, oauthError: "invalid_grant"))
        #expect(error.pluginSqlState == "28000")
    }

    @Test("An unreadable key file is not an authorization failure")
    func unreadableKeyIsNotInvalidAuthorization() {
        #expect(BigQueryError.authentication(.credentialFileUnreadable).pluginSqlState == nil)
    }

    @Test("HTTP 401 from BigQuery carries SQLSTATE 28000 and the status code")
    func unauthorizedResponse() {
        let error = BQErrorResponse.apiError(
            status: 401,
            data: Data(#"{"error":{"code":401,"message":"Request had invalid credentials."}}"#.utf8)
        )
        #expect(error.pluginSqlState == "28000")
        #expect(error.pluginErrorCode == 401)
        #expect(error.pluginErrorMessage == "Request had invalid credentials.")
    }

    @Test("An invalid query reason is recognised for the parameter memo")
    func invalidQueryReason() {
        let error = BQErrorResponse.apiError(
            status: 400,
            data: Data(#"{"error":{"code":400,"message":"Syntax error","errors":[{"reason":"invalidQuery"}]}}"#.utf8)
        )
        #expect(error.isInvalidQuery)
        #expect(error.pluginSqlState == nil)
    }

    @Test("A missing partition filter adds a hint")
    func partitionHint() {
        let message = "Cannot query over table 't' without a filter over column(s) 'd' "
            + "that can be used for partition elimination"
        let error = BigQueryError.jobFailed(message: message, reason: "invalidQuery")
        #expect(error.pluginErrorDetail != nil)
    }

    @Test("Google auth errors wrap into driver errors")
    func wrapsGoogleAuthErrors() {
        let wrapped = BigQueryError.wrap(GoogleAuthError.signInRequired)
        #expect((wrapped as? BigQueryError)?.pluginSqlState == "28000")
    }
}
