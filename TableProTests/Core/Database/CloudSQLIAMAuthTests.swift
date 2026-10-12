//
//  CloudSQLIAMAuthTests.swift
//  TableProTests
//

import Foundation
import TableProGoogleCloud
import TableProPluginKit
import Testing

@testable import TablePro

private final class RecordingGoogleHTTPClient: GoogleHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let body: Data
    private let status: Int

    init(body: String = #"{"access_token":"ya29.cloudsql","expires_in":3599,"token_type":"Bearer"}"#, status: Int = 200) {
        self.body = Data(body.utf8)
        self.status = status
    }

    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        let url = request.url ?? URL(fileURLWithPath: "/")
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
            throw URLError(.badServerResponse)
        }
        return (body, response)
    }
}

private final class CredentialFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var contents: [String: Data]
    private var reads: [String] = []

    init(_ contents: [String: String] = [:]) {
        self.contents = contents.mapValues { Data($0.utf8) }
    }

    var readPaths: [String] {
        lock.withLock { reads }
    }

    func read(_ path: String) -> Data? {
        lock.withLock {
            reads.append(path)
            return contents[path]
        }
    }

    func write(_ path: String, _ text: String) {
        lock.withLock { contents[path] = Data(text.utf8) }
    }
}

@MainActor
struct CloudSQLIAMAuthTests {
    private static let userLogin = """
    {"type":"authorized_user","client_id":"client.apps.googleusercontent.com",\
    "client_secret":"secret","refresh_token":"1//refresh"}
    """

    private static let otherUserLogin = """
    {"type":"authorized_user","client_id":"client.apps.googleusercontent.com",\
    "client_secret":"secret","refresh_token":"1//other"}
    """

    private static let serviceAccountKey = """
    {"type":"service_account","client_email":"reader@project.iam.gserviceaccount.com",\
    "private_key":"-----BEGIN PRIVATE KEY-----\\nAAAA\\n-----END PRIVATE KEY-----\\n","project_id":"project"}
    """

    private static let defaultPath = GoogleApplicationDefaultCredentials.defaultPath

    private func connection(type: DatabaseType, auth: String?) -> DatabaseConnection {
        var connection = DatabaseConnection(name: "cloudsql", type: type)
        if let auth {
            connection.additionalFields = ["awsAuth": auth]
        }
        return connection
    }

    private func authOptions(for type: DatabaseType) -> [String] {
        let picker = PluginManager.shared.additionalConnectionFields(for: type).first { $0.id == "awsAuth" }
        guard case .dropdown(let options) = picker?.fieldType else { return [] }
        return options.map(\.value)
    }

    private func cache(
        _ files: CredentialFiles,
        http: RecordingGoogleHTTPClient,
        environment: [String: String] = [:]
    ) -> CloudSQLIAMTokenCache {
        CloudSQLIAMTokenCache(readFile: { files.read($0) }, environment: { environment }, http: http)
    }

    private func formFields(_ request: URLRequest) -> [String: String] {
        let text = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        return fields
    }

    private func login(_ source: GoogleCredentialSource, connectionId: UUID = UUID()) -> CloudSQLIAMLogin {
        CloudSQLIAMLogin(connectionId: connectionId, source: source)
    }

    // MARK: - The picker

    @Test("MySQL and PostgreSQL offer Cloud SQL IAM next to AWS IAM on one picker")
    func pickerOffersCloudSQLIAM() {
        for type in [DatabaseType.mysql, .postgresql] {
            let options = authOptions(for: type)
            #expect(options == ["off", "accessKey", "profile", "sso", "gcpApplicationDefault", "gcpServiceAccount"])
            let fieldIds = PluginManager.shared.additionalConnectionFields(for: type).map(\.id)
            #expect(fieldIds.filter { $0 == "awsAuth" }.count == 1)
            #expect(fieldIds.contains(GoogleCloudSQLAuthFields.serviceAccountKeyFieldId))
        }
    }

    @Test("Engines without Cloud SQL IAM sign-in keep the AWS-only picker")
    func otherEnginesKeepAWSOnly() {
        #expect(authOptions(for: .mariadb) == ["off", "accessKey", "profile", "sso"])
        #expect(AWSAuthFields.standard().contains { $0.id == GoogleCloudSQLAuthFields.serviceAccountKeyFieldId } == false)
    }

    @Test("The key field shows only for the service account mode, and is stored as a secret")
    func serviceAccountKeyFieldVisibility() throws {
        let field = try #require(
            GoogleCloudSQLAuthFields.standardWithAWS().first { $0.id == GoogleCloudSQLAuthFields.serviceAccountKeyFieldId }
        )
        #expect(field.visibleWhen == FieldVisibilityRule(fieldId: "awsAuth", values: ["gcpServiceAccount"]))
        #expect(field.isSecure)
    }

    @Test("Each picker value is read as one sign-in method")
    func classification() {
        #expect(connection(type: .postgresql, auth: "gcpApplicationDefault").iamSignIn == .googleCloud(.applicationDefault))
        #expect(connection(type: .mysql, auth: "gcpServiceAccount").iamSignIn == .googleCloud(.serviceAccount))
        #expect(connection(type: .postgresql, auth: "profile").iamSignIn == .aws(source: "profile"))
        for auth in ["off", "", nil] {
            #expect(connection(type: .mysql, auth: auth).iamSignIn == nil)
        }

        let google = connection(type: .postgresql, auth: "gcpApplicationDefault")
        #expect(google.usesGoogleCloudIAM && !google.usesAWSIAM && google.usesIAMToken)
        let aws = connection(type: .postgresql, auth: "sso")
        #expect(aws.usesAWSIAM && !aws.usesGoogleCloudIAM && aws.usesIAMToken)
        let plain = connection(type: .mysql, auth: "off")
        #expect(!plain.usesAWSIAM && !plain.usesGoogleCloudIAM && !plain.usesIAMToken)
    }

    @Test("Cloud SQL IAM hides the password field and the prompt")
    func hidesPassword() {
        #expect(PluginManager.shared.hidesPassword(for: connection(type: .postgresql, auth: "gcpApplicationDefault")))
        #expect(PluginManager.shared.hidesPassword(for: connection(type: .mysql, auth: "gcpServiceAccount")))
    }

    // MARK: - What mints the password

    @Test("The host mints a Google token for both Google modes, reading the key from its field")
    func googleModesMintThroughTheCache() {
        let adc = connection(type: .postgresql, auth: "gcpApplicationDefault")
        guard case .googleCloud(let adcLogin) = ConnectionCredentialResolver.iamPasswordMinter(for: adc, fields: adc.additionalFields) else {
            Issue.record("Expected a Google minter")
            return
        }
        #expect(adcLogin == CloudSQLIAMLogin(connectionId: adc.id, source: .applicationDefault))

        let serviceAccount = connection(type: .mysql, auth: "gcpServiceAccount")
        let fields = ["awsAuth": "gcpServiceAccount", "gcpServiceAccountKey": "/keys/sa.json"]
        guard case .googleCloud(let keyLogin) = ConnectionCredentialResolver.iamPasswordMinter(for: serviceAccount, fields: fields) else {
            Issue.record("Expected a Google minter")
            return
        }
        #expect(keyLogin.source == .serviceAccountKey("/keys/sa.json"))
    }

    @Test("AWS modes sign on the host unless the driver resolves them, and a password mints nothing")
    func awsAndPlainMinters() {
        let rds = connection(type: .postgresql, auth: "profile")
        guard case .aws(let signer) = ConnectionCredentialResolver.iamPasswordMinter(for: rds, fields: rds.additionalFields) else {
            Issue.record("Expected an AWS minter")
            return
        }
        #expect(signer.source == "profile")

        let keyspaces = connection(type: .cassandra, auth: "profile")
        #expect(ConnectionCredentialResolver.iamPasswordMinter(for: keyspaces, fields: keyspaces.additionalFields) == nil)
        let plain = connection(type: .mysql, auth: "off")
        #expect(ConnectionCredentialResolver.iamPasswordMinter(for: plain, fields: plain.additionalFields) == nil)
    }

    // MARK: - The token

    @Test("A user login's token is narrowed to Cloud SQL sign-in")
    func userLoginTokenIsScopedToSignIn() async throws {
        let http = RecordingGoogleHTTPClient()
        let tokens = cache(CredentialFiles([Self.defaultPath: Self.userLogin]), http: http)

        #expect(try await tokens.accessToken(for: login(.applicationDefault)) == "ya29.cloudsql")

        let request = try #require(http.requests.first)
        #expect(request.url == GoogleOAuthClient.tokenEndpoint)
        let fields = formFields(request)
        #expect(fields["grant_type"] == "refresh_token")
        #expect(fields["scope"] == "https://www.googleapis.com/auth/sqlservice.login")
    }

    @Test("Sign-ins of one connection share its token")
    func tokenIsShared() async throws {
        let http = RecordingGoogleHTTPClient()
        let tokens = cache(CredentialFiles([Self.defaultPath: Self.userLogin]), http: http)
        let connectionId = UUID()

        _ = try await tokens.accessToken(for: login(.applicationDefault, connectionId: connectionId))
        _ = try await tokens.accessToken(for: login(.applicationDefault, connectionId: connectionId))

        #expect(http.requests.count == 1)
    }

    @Test("A new gcloud login replaces the token")
    func newCredentialsReplaceTheToken() async throws {
        let http = RecordingGoogleHTTPClient()
        let files = CredentialFiles([Self.defaultPath: Self.userLogin])
        let tokens = cache(files, http: http)
        let connectionId = UUID()

        _ = try await tokens.accessToken(for: login(.applicationDefault, connectionId: connectionId))
        files.write(Self.defaultPath, Self.otherUserLogin)
        _ = try await tokens.accessToken(for: login(.applicationDefault, connectionId: connectionId))

        #expect(http.requests.map { formFields($0)["refresh_token"] } == ["1//refresh", "1//other"])
    }

    @Test("GOOGLE_APPLICATION_CREDENTIALS wins over the gcloud default file")
    func environmentPathWins() async throws {
        let files = CredentialFiles(["/keys/adc.json": Self.userLogin])
        let tokens = cache(
            files,
            http: RecordingGoogleHTTPClient(),
            environment: [GoogleApplicationDefaultCredentials.environmentVariable: "/keys/adc.json"]
        )

        _ = try await tokens.accessToken(for: login(.applicationDefault))

        #expect(files.readPaths == ["/keys/adc.json"])
    }

    @Test("Missing application default credentials say how to create them")
    func missingApplicationDefaultCredentials() async {
        let tokens = cache(CredentialFiles(), http: RecordingGoogleHTTPClient())
        await #expect(throws: CloudSQLIAMAuthError.authentication(.applicationDefaultCredentialsNotFound)) {
            _ = try await tokens.accessToken(for: login(.applicationDefault))
        }
        let message = CloudSQLIAMAuthError.authentication(.applicationDefaultCredentialsNotFound).errorDescription ?? ""
        #expect(message.contains("gcloud auth application-default login"))
    }

    @Test("The service account mode reads its key, pasted or from a path, and never the gcloud login")
    func serviceAccountKeySources() async {
        let files = CredentialFiles([Self.defaultPath: Self.userLogin, "/keys/sa.json": Self.serviceAccountKey])
        let http = RecordingGoogleHTTPClient()
        let tokens = cache(files, http: http)

        _ = try? await tokens.accessToken(for: login(.serviceAccountKey(Self.serviceAccountKey)))
        #expect(files.readPaths.isEmpty)
        _ = try? await tokens.accessToken(for: login(.serviceAccountKey("/keys/sa.json")))
        #expect(files.readPaths == ["/keys/sa.json"])
        #expect(http.requests.allSatisfy { formFields($0)["grant_type"] != "refresh_token" })
    }

    @Test("The service account mode without a key fails instead of using the gcloud login")
    func serviceAccountWithoutKeyFails() async {
        let tokens = cache(CredentialFiles([Self.defaultPath: Self.userLogin]), http: RecordingGoogleHTTPClient())
        await #expect(throws: CloudSQLIAMAuthError.authentication(.credentialFileUnreadable)) {
            _ = try await tokens.accessToken(for: login(.serviceAccountKey("")))
        }
    }

    @Test("A rejected token request surfaces Google's reason")
    func rejectedTokenRequest() async {
        let tokens = cache(
            CredentialFiles([Self.defaultPath: Self.userLogin]),
            http: RecordingGoogleHTTPClient(body: #"{"error":"invalid_grant"}"#, status: 400)
        )
        await #expect(throws: CloudSQLIAMAuthError.authentication(
            .tokenRequestRejected(status: 400, oauthError: "invalid_grant")
        )) {
            _ = try await tokens.accessToken(for: login(.applicationDefault))
        }
    }

    @Test("A login that never granted Cloud SQL sign-in says to log in again")
    func loginWithoutTheScope() {
        let error = CloudSQLIAMAuthError.authentication(.tokenRequestRejected(status: 400, oauthError: "invalid_scope"))
        #expect(error.errorDescription?.contains("gcloud auth application-default login") == true)
    }

    // MARK: - Transport

    @Test("A token sign-in raises SSL to Required, and leaves a verifying mode alone")
    func tokenSignInRequiresTLS() {
        for auth in ["gcpApplicationDefault", "gcpServiceAccount", "accessKey"] {
            for mode in [SSLMode.disabled, .preferred] {
                var connection = connection(type: .postgresql, auth: auth)
                connection.sslConfig.mode = mode
                #expect(connection.transportSSLConfiguration.mode == .required)
            }
            var verifying = connection(type: .postgresql, auth: auth)
            verifying.sslConfig.mode = .verifyIdentity
            #expect(verifying.transportSSLConfiguration.mode == .verifyIdentity)
        }
        #expect(connection(type: .mysql, auth: "off").transportSSLConfiguration.mode == .disabled)
    }

    @Test("Behind the Cloud SQL Auth Proxy a token sign-in keeps SSL as set")
    func proxyKeepsSSL() {
        let direct = connection(type: .mysql, auth: "gcpApplicationDefault")
        let proxied = DatabaseManager.shared.tunneledConnection(from: direct, localPort: 61_500, securesTransport: true)
        #expect(proxied.tunnelSecuresTransport)
        #expect(proxied.transportSSLConfiguration.mode == .disabled)

        let sshTunneled = DatabaseManager.shared.tunneledConnection(from: direct, localPort: 61_501)
        #expect(!sshTunneled.tunnelSecuresTransport)
        #expect(sshTunneled.transportSSLConfiguration.mode == .required)
    }
}
