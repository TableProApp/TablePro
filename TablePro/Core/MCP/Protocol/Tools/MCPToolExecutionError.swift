import Foundation

public enum MCPToolErrorCode: String, Sendable, Equatable {
    case invalidArgument = "invalid_argument"
    case notConnected = "not_connected"
    case notFound = "not_found"
    case denied = "denied"
    case timeout = "timeout"
    case unsupported = "unsupported"
    case queryFailed = "query_failed"
    case userCancelled = "user_cancelled"
    case internalFailure = "internal_failure"
}

public struct MCPToolExecutionError: Error, Sendable, Equatable {
    public let code: MCPToolErrorCode
    public let message: String

    public init(code: MCPToolErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    public var asToolResult: MCPToolCallResult {
        MCPToolCallResult(content: [.text("\(code.rawValue): \(message)")], isError: true)
    }

    public static func invalidArgument(_ message: String) -> MCPToolExecutionError {
        MCPToolExecutionError(code: .invalidArgument, message: message)
    }

    public static func denied(_ message: String) -> MCPToolExecutionError {
        MCPToolExecutionError(code: .denied, message: message)
    }

    public static func timedOut(_ message: String) -> MCPToolExecutionError {
        MCPToolExecutionError(code: .timeout, message: message)
    }

    public static func unsupported(_ message: String) -> MCPToolExecutionError {
        MCPToolExecutionError(code: .unsupported, message: message)
    }

    public static func notFound(_ message: String) -> MCPToolExecutionError {
        MCPToolExecutionError(code: .notFound, message: message)
    }

    public static func queryFailed(_ message: String) -> MCPToolExecutionError {
        MCPToolExecutionError(code: .queryFailed, message: message)
    }

    public static func from(_ error: DatabaseAccessError, secrets: [String] = []) -> MCPToolExecutionError {
        switch error {
        case .notConnected:
            return MCPToolExecutionError(
                code: .notConnected,
                message: String(localized: "The connection is not open. Call connect first.")
            )
        case .invalidArgument(let detail):
            return MCPToolExecutionError(code: .invalidArgument, message: MCPErrorRedactor.redact(detail, secrets: secrets))
        case .forbidden(let detail, _):
            return MCPToolExecutionError(code: .denied, message: MCPErrorRedactor.redact(detail, secrets: secrets))
        case .timeout(let detail, _):
            return MCPToolExecutionError(code: .timeout, message: MCPErrorRedactor.redact(detail, secrets: secrets))
        case .notFound(let detail):
            return MCPToolExecutionError(code: .notFound, message: MCPErrorRedactor.redact(detail, secrets: secrets))
        case .expired(let detail):
            return MCPToolExecutionError(code: .denied, message: MCPErrorRedactor.redact(detail, secrets: secrets))
        case .userCancelled:
            return MCPToolExecutionError(
                code: .userCancelled,
                message: String(localized: "The user cancelled this operation.")
            )
        case .dataSourceError(let detail):
            return MCPToolExecutionError(code: .queryFailed, message: MCPErrorRedactor.redact(detail, secrets: secrets))
        }
    }
}
