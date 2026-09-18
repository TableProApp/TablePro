import Foundation
import TableProGoogleCloud

internal enum GoogleOAuthConnectionFields: String, CaseIterable, Sendable {
    case spanner
    case bigQuery

    static let oauthMethod = "oauth"

    var authMethodKey: String {
        switch self {
        case .spanner:
            return "spAuthMethod"
        case .bigQuery:
            return "bqAuthMethod"
        }
    }

    var clientIdKey: String {
        switch self {
        case .spanner:
            return "spOAuthClientId"
        case .bigQuery:
            return "bqOAuthClientId"
        }
    }

    var clientSecretKey: String {
        switch self {
        case .spanner:
            return "spOAuthClientSecret"
        case .bigQuery:
            return "bqOAuthClientSecret"
        }
    }

    static func active(in fields: [String: String]) -> GoogleOAuthConnectionFields? {
        allCases.first { fields[$0.authMethodKey] == oauthMethod }
    }

    func client(from fields: [String: String]) -> GoogleOAuthClient? {
        guard let clientId = Self.trimmed(fields[clientIdKey]),
              let clientSecret = Self.trimmed(fields[clientSecretKey])
        else {
            return nil
        }
        return GoogleOAuthClient(clientId: clientId, clientSecret: clientSecret)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
