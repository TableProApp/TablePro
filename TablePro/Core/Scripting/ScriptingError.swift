//
//  ScriptingError.swift
//  TablePro
//

import Foundation

/// What a script sees when a command cannot be carried out.
///
/// AppleScript reports an error as a number and a string, and a script catches it with
/// `on error message number n`. The numbers are the Apple event ones a script author already knows,
/// so `errAENoSuchObject` for a name that matches nothing and `errAEEventFailed` for everything the
/// app refused, rather than a private numbering nobody can look up.
internal enum ScriptingError: LocalizedError {
    case noSuchObject(String)
    case badRequest(String)
    case refused(String)
    case failed(String)

    internal var number: Int {
        switch self {
        case .noSuchObject: -1_728
        case .badRequest: -50
        case .refused, .failed: -10_000
        }
    }

    internal var errorDescription: String? {
        switch self {
        case .noSuchObject(let detail), .badRequest(let detail),
             .refused(let detail), .failed(let detail):
            return detail
        }
    }

    /// Everything a command can throw, said in a script's own terms.
    ///
    /// A refusal keeps its own wording because that wording is the whole point: "this connection is
    /// read only for external clients" tells a script author what to change, and a generic failure
    /// does not.
    ///
    /// A driver's own error is the one that has to be scrubbed. It can carry a DSN, a file path or
    /// the account name, and it does not stop at the script: a failed query writes the same text to
    /// the history drawer, a notification and a `.public` log line. `secrets` is the connection's,
    /// and the redactor is the one the MCP tools already use.
    internal static func from(_ error: Error, secrets: [String] = []) -> ScriptingError {
        switch error {
        case let scripting as ScriptingError:
            return scripting
        case let gate as ExternalStatementGateError:
            let detail = gate.errorDescription ?? String(localized: "Operation not permitted")
            /// A refusal and a malformed request are different things to a script author: one means
            /// change the connection's settings, the other means change the script.
            if case .invalidArgument = gate {
                return .badRequest(detail)
            }
            return .refused(detail)
        case let execution as ExecutionGateError:
            return .refused(execution.errorDescription ?? String(localized: "Operation not permitted"))
        case let access as DatabaseAccessError:
            return from(access)
        case let routing as TabRouterError:
            if case .userCancelled = routing {
                return .refused(String(localized: "The operation was cancelled."))
            }
            if case .connectionNotFound = routing {
                return .noSuchObject(routing.errorDescription ?? "")
            }
            return .failed(routing.errorDescription ?? String(localized: "The operation failed."))
        case is CancellationError:
            return .failed(String(localized: "The operation was cancelled."))
        default:
            return .failed(MCPErrorRedactor.message(for: error, secrets: secrets))
        }
    }

    private static func from(_ error: DatabaseAccessError) -> ScriptingError {
        switch error {
        case .notFound(let detail):
            return .noSuchObject(detail)
        case .notConnected:
            return .failed(String(localized: "The connection is not open. Connect it first."))
        case .forbidden(let detail, _):
            return .refused(detail)
        case .userCancelled:
            return .refused(String(localized: "The operation was cancelled."))
        case .invalidArgument(let detail):
            return .badRequest(detail)
        case .timeout(let detail, _), .expired(let detail), .dataSourceError(let detail):
            return .failed(detail)
        }
    }
}
