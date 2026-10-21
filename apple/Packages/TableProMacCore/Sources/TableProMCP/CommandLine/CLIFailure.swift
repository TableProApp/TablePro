import Foundation

public enum CLIExitCode: Int32, Sendable, Equatable {
    case success = 0
    case failure = 1
    case usage = 2
    case refused = 3
    case timedOut = 4
}

public struct CLIFailure: Error, Sendable, Equatable {
    public let exitCode: CLIExitCode
    public let message: String

    public init(_ exitCode: CLIExitCode, _ message: String) {
        self.exitCode = exitCode
        self.message = message
    }

    public static func usage(_ message: String) -> CLIFailure {
        CLIFailure(.usage, message)
    }

    // A tool error's text is `<code>: <message>` (developers/mcp-protocol.mdx, Tool errors).
    public static func fromToolError(text: String) -> CLIFailure {
        guard let separator = text.range(of: ": ") else {
            return CLIFailure(.failure, text)
        }
        let code = String(text[..<separator.lowerBound])
        let message = String(text[separator.upperBound...])
        switch code {
        case "denied", "user_cancelled":
            return CLIFailure(.refused, message)
        case "timeout":
            return CLIFailure(.timedOut, message)
        case "invalid_argument":
            return CLIFailure(.usage, message)
        case "not_found", "not_connected", "unsupported", "query_failed", "internal_failure":
            return CLIFailure(.failure, message)
        default:
            return CLIFailure(.failure, text)
        }
    }

    public static func fromRpcError(code: Int, message: String) -> CLIFailure {
        switch code {
        case JsonRpcErrorCode.forbidden, JsonRpcErrorCode.serverDisabled,
             JsonRpcErrorCode.unauthenticated, JsonRpcErrorCode.expired:
            return CLIFailure(.refused, message)
        case JsonRpcErrorCode.requestTimeout:
            return CLIFailure(.timedOut, message)
        case JsonRpcErrorCode.invalidParams:
            return CLIFailure(.usage, message)
        default:
            return CLIFailure(.failure, message)
        }
    }
}
