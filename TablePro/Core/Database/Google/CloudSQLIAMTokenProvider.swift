import Foundation
import TableProGoogleCloud
import TableProPluginKit

/// Mints the OAuth access token that Cloud SQL accepts as the password of an IAM database user.
internal enum CloudSQLIAMTokenProvider {
    /// The scope `gcloud sql generate-login-token` and the Cloud SQL connectors request. It grants a
    /// database sign-in only, so a leaked password cannot call any other Google API.
    static let scopes = ["https://www.googleapis.com/auth/sqlservice.login"]

    static func provider(
        fields: [String: String],
        readFile: (String) -> Data?,
        environment: [String: String],
        http: any GoogleHTTPClient
    ) throws -> any GoogleAccessTokenProviding {
        do {
            switch fields["awsAuth"] {
            case GoogleCloudSQLAuthFields.serviceAccount:
                let key = try GoogleServiceAccountKey.parse(
                    fieldValue: fields[GoogleCloudSQLAuthFields.serviceAccountKeyFieldId] ?? "",
                    readFile: readFile
                )
                return GoogleTokenProviders.serviceAccount(key, scopes: scopes, http: http)
            default:
                let credentials = try GoogleApplicationDefaultCredentials.load(
                    path: nil,
                    readFile: readFile,
                    environment: environment
                )
                return GoogleTokenProviders.applicationDefault(credentials, scopes: scopes, http: http)
            }
        } catch let error as GoogleAuthError {
            throw CloudSQLIAMAuthError.authentication(error)
        }
    }

    static func accessToken(from provider: any GoogleAccessTokenProviding) async throws -> String {
        do {
            return try await provider.accessToken()
        } catch let error as GoogleAuthError {
            throw CloudSQLIAMAuthError.authentication(error)
        }
    }
}

internal enum CloudSQLIAMAuthError: LocalizedError, Equatable {
    case authentication(GoogleAuthError)

    var errorDescription: String? {
        switch self {
        case .authentication(let error):
            return GoogleAuthErrorMessages.message(for: error)
        }
    }
}

/// Bounds each token request by what is left of the connect deadline, so a slow token endpoint
/// fails the connect on time instead of after the transport's hour-long default.
internal struct CloudSQLIAMDeadlineHTTPClient: GoogleHTTPClient {
    let base: any GoogleHTTPClient
    let timeout: TimeInterval

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = min(request.timeoutInterval, timeout)
        return try await base.send(request)
    }
}
