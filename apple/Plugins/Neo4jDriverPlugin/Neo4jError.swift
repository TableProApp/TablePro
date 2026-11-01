import Foundation

enum Neo4jError: Error, LocalizedError, Sendable {
    case notConnected
    case connectionFailed(String)
    case server(code: String, message: String)
    case cancelled

    init?(reply: BoltReply) {
        switch reply.outcome {
        case .success:
            return nil
        case .failure(let code, let message):
            self = .server(code: code, message: message)
        case .ignored:
            self = .cancelled
        }
    }

    static func detail(of error: Error) -> String {
        if case .connectionFailed(let detail) = error as? Neo4jError { return detail }
        return PluginNIOChannel.describe(error)
    }

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Not connected to Neo4j.")
        case .connectionFailed(let detail):
            return String(format: String(localized: "Could not connect to Neo4j: %@"), detail)
        case .server(_, let message):
            return message
        case .cancelled:
            return String(localized: "The query was cancelled.")
        }
    }

    // Only a failure of the session's own credentials; Forbidden on one database is not one.
    var isAuthenticationFailure: Bool {
        guard case .server(let code, _) = self else { return false }
        return Self.authenticationCodes.contains(code)
    }

    private static let authenticationCodes: Set<String> = [
        "Neo.ClientError.Security.Unauthorized",
        "Neo.ClientError.Security.CredentialsExpired",
        "Neo.ClientError.Security.TokenExpired",
        "Neo.ClientError.Security.AuthenticationRateLimit"
    ]
}
