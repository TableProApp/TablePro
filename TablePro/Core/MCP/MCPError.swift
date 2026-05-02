import Foundation

enum MCPError: Error, Sendable {
    case parseError
    case invalidRequest(String)
    case methodNotFound(String)
    case invalidParams(String)
    case internalError(String)
    case notConnected(UUID)
    case forbidden(String, context: [String: String]? = nil)
    case timeout(String, context: [String: String]? = nil)
    case resultTooLarge
    case serverDisabled
    case notFound(String)
    case expired(String)
    case userCancelled

    var code: Int {
        switch self {
        case .parseError: -32_700
        case .invalidRequest: -32_600
        case .methodNotFound: -32_601
        case .invalidParams: -32_602
        case .internalError: -32_603
        case .notConnected: -32_000
        case .forbidden: -32_001
        case .timeout: -32_002
        case .resultTooLarge: -32_003
        case .serverDisabled: -32_004
        case .notFound: -32_005
        case .expired: -32_006
        case .userCancelled: -32_007
        }
    }

    var message: String {
        switch self {
        case .parseError:
            "Parse error"
        case .invalidRequest(let detail):
            "Invalid request: \(detail)"
        case .methodNotFound(let method):
            "Method not found: \(method)"
        case .invalidParams(let detail):
            "Invalid params: \(detail)"
        case .internalError(let detail):
            "Internal error: \(detail)"
        case .notConnected(let connectionId):
            "Not connected: \(connectionId)"
        case .forbidden(let detail, _):
            "Forbidden: \(detail)"
        case .timeout(let detail, _):
            "Timeout: \(detail)"
        case .resultTooLarge:
            "Result too large"
        case .serverDisabled:
            "MCP server is disabled"
        case .notFound(let detail):
            "Not found: \(detail)"
        case .expired(let detail):
            "Expired: \(detail)"
        case .userCancelled:
            "User cancelled"
        }
    }

    var isUserCancelled: Bool {
        if case .userCancelled = self { return true }
        return false
    }
}

extension MCPError: LocalizedError {
    var errorDescription: String? { message }
}
