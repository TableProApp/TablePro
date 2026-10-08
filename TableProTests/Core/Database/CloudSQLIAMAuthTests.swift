//
//  CloudSQLIAMAuthTests.swift
//  TableProTests
//
//  Cloud SQL IAM sign-in: the picker offers it only where Cloud SQL runs, the connection classifies
//  it apart from AWS IAM, and the token comes from the credential the mode names.
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

@MainActor
struct CloudSQLIAMAuthTests {
    private static let authorizedUserADC = """
    {"type":"authorized_user","client_id":"client.apps.googleusercontent.com",\
    "client_secret":"secret","refresh_token":"1//refresh"}
    """

    private static let serviceAccountKey = """
    {"type":"service_account","client_email":"reader@project.iam.gserviceaccount.com",\
    "private_key":"-----BEGIN PRIVATE KEY-----\\nAAAA\\n-----END PRIVATE KEY-----\\n","project_id":"project"}
    """

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

    @Test("Engines Cloud SQL does not run keep the AWS-only picker")
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

    @Test("A Cloud SQL IAM mode is a token mode but not an AWS one")
    func classification() {
        for mode in ["gcpApplicationDefault", "gcpServiceAccount"] {
            let connection = connection(type: .postgresql, auth: mode)
            #expect(connection.usesGoogleCloudIAM)
            #expect(!connection.usesAWSIAM)
            #expect(connection.usesIAMToken)
        }
        let aws = connection(type: .postgresql, auth: "profile")
        #expect(aws.usesAWSIAM && !aws.usesGoogleCloudIAM && aws.usesIAMToken)
        for auth in ["off", nil] {
            let plain = connection(type: .mysql, auth: auth)
            #expect(!plain.usesAWSIAM && !plain.usesGoogleCloudIAM && !plain.usesIAMToken)
        }
    }

    @Test("Cloud SQL IAM hides the password field and the prompt")
    func hidesPassword() {
        #expect(PluginManager.shared.hidesPassword(for: connection(type: .postgresql, auth: "gcpApplicationDefault")))
        #expect(PluginManager.shared.hidesPassword(for: connection(type: .mysql, auth: "gcpServiceAccount")))
    }

    @Test("Application default credentials are exchanged at Google's token endpoint for the password")
    func applicationDefaultMintsToken() async throws {
        let http = RecordingGoogleHTTPClient()
        let provider = try CloudSQLIAMTokenProvider.provider(
            fields: ["awsAuth": "gcpApplicationDefault"],
            readFile: { $0 == GoogleApplicationDefaultCredentials.defaultPath ? Data(Self.authorizedUserADC.utf8) : nil },
            environment: [:],
            http: http
        )

        let token = try await CloudSQLIAMTokenProvider.accessToken(from: provider)

        #expect(token == "ya29.cloudsql")
        let request = try #require(http.requests.first)
        #expect(request.url == GoogleOAuthClient.tokenEndpoint)
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("grant_type=refresh_token"))
    }

    @Test("GOOGLE_APPLICATION_CREDENTIALS wins over the gcloud default file")
    func environmentPathWins() throws {
        var readPaths: [String] = []
        _ = try CloudSQLIAMTokenProvider.provider(
            fields: ["awsAuth": "gcpApplicationDefault"],
            readFile: { path in
                readPaths.append(path)
                return path == "/keys/adc.json" ? Data(Self.authorizedUserADC.utf8) : nil
            },
            environment: [GoogleApplicationDefaultCredentials.environmentVariable: "/keys/adc.json"],
            http: RecordingGoogleHTTPClient()
        )
        #expect(readPaths == ["/keys/adc.json"])
    }

    @Test("Missing application default credentials say how to create them")
    func missingADC() {
        #expect(throws: CloudSQLIAMAuthError.authentication(.applicationDefaultCredentialsNotFound)) {
            try CloudSQLIAMTokenProvider.provider(
                fields: ["awsAuth": "gcpApplicationDefault"],
                readFile: { _ in nil },
                environment: [:],
                http: RecordingGoogleHTTPClient()
            )
        }
        let message = CloudSQLIAMAuthError.authentication(.applicationDefaultCredentialsNotFound).errorDescription ?? ""
        #expect(message.contains("gcloud auth application-default login"))
    }

    @Test("The service account mode reads the key from the key field, as a path or as pasted JSON")
    func serviceAccountKeySources() throws {
        _ = try CloudSQLIAMTokenProvider.provider(
            fields: ["awsAuth": "gcpServiceAccount", "gcpServiceAccountKey": Self.serviceAccountKey],
            readFile: { _ in nil },
            environment: [:],
            http: RecordingGoogleHTTPClient()
        )
        _ = try CloudSQLIAMTokenProvider.provider(
            fields: ["awsAuth": "gcpServiceAccount", "gcpServiceAccountKey": "/keys/sa.json"],
            readFile: { $0 == "/keys/sa.json" ? Data(Self.serviceAccountKey.utf8) : nil },
            environment: [:],
            http: RecordingGoogleHTTPClient()
        )
    }

    @Test("The service account mode never falls back to application default credentials")
    func serviceAccountWithoutKeyFails() {
        #expect(throws: CloudSQLIAMAuthError.authentication(.credentialFileUnreadable)) {
            try CloudSQLIAMTokenProvider.provider(
                fields: ["awsAuth": "gcpServiceAccount"],
                readFile: { $0 == GoogleApplicationDefaultCredentials.defaultPath ? Data(Self.authorizedUserADC.utf8) : nil },
                environment: [:],
                http: RecordingGoogleHTTPClient()
            )
        }
    }

    @Test("A rejected token request surfaces Google's reason")
    func rejectedTokenRequest() async throws {
        let provider = try CloudSQLIAMTokenProvider.provider(
            fields: ["awsAuth": "gcpApplicationDefault"],
            readFile: { _ in Data(Self.authorizedUserADC.utf8) },
            environment: [:],
            http: RecordingGoogleHTTPClient(body: #"{"error":"invalid_grant"}"#, status: 400)
        )
        await #expect(throws: CloudSQLIAMAuthError.authentication(
            .tokenRequestRejected(status: 400, oauthError: "invalid_grant")
        )) {
            try await CloudSQLIAMTokenProvider.accessToken(from: provider)
        }
    }

    @Test("A token request never outlives the connect deadline")
    func deadlineCapsRequestTimeout() async throws {
        let http = RecordingGoogleHTTPClient()
        let client = CloudSQLIAMDeadlineHTTPClient(base: http, timeout: 4)
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else { return }

        _ = try await client.send(URLRequest(url: url, timeoutInterval: 30))
        _ = try await client.send(URLRequest(url: url, timeoutInterval: 2))

        #expect(http.requests.map(\.timeoutInterval) == [4, 2])
    }
}
