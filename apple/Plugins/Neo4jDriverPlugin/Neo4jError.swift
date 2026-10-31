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

    var isAuthenticationFailure: Bool {
        if case .server(let code, _) = self { return code.hasPrefix("Neo.ClientError.Security") }
        return false
    }
}
