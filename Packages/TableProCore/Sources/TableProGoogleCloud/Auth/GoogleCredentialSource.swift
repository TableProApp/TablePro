import Foundation

/// Where a connection's Google credentials come from, for drivers that offer the two
/// non-interactive choices.
public enum GoogleCredentialSource: Sendable, Equatable {
    case applicationDefault
    /// A key file path or the pasted JSON key.
    case serviceAccountKey(String)
}

public struct GoogleCredentials: Sendable {
    public let tokenProvider: any GoogleAccessTokenProviding
    public let projectHint: String?
}

public extension GoogleTokenProviders {
    static func credentials(
        from source: GoogleCredentialSource,
        scopes: [String],
        restrictsUserLogin: Bool = false,
        readFile: (String) -> Data?,
        environment: [String: String],
        http: any GoogleHTTPClient
    ) throws -> GoogleCredentials {
        switch source {
        case .serviceAccountKey(let fieldValue):
            let key = try GoogleServiceAccountKey.parse(fieldValue: fieldValue, readFile: readFile)
            return GoogleCredentials(
                tokenProvider: serviceAccount(key, scopes: scopes, http: http),
                projectHint: key.projectId
            )
        case .applicationDefault:
            let credentials = try GoogleApplicationDefaultCredentials.load(
                path: nil,
                readFile: readFile,
                environment: environment
            )
            return GoogleCredentials(
                tokenProvider: applicationDefault(
                    credentials,
                    scopes: scopes,
                    restrictsUserLogin: restrictsUserLogin,
                    http: http
                ),
                projectHint: credentials.projectHint
            )
        }
    }
}
