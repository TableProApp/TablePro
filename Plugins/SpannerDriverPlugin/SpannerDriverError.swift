import Foundation
import TableProGoogleCloud
import TableProPluginKit
import TableProSpannerCore

internal enum SpannerDriverError: PluginDriverError {
    case notConnected
    case configuration(SpannerConfigurationError)
    case authentication(GoogleAuthError)
    case server(SpannerAPIError)
    case execution(SpannerExecutionError)
    case transport(SpannerTransportError)
    case parameterEncoding(SpannerParameterEncodingError)
    case placeholderCount(found: Int, expected: Int)
    case objectNotFound(String)
    case cancelled

    static func wrap(_ error: Error) -> Error {
        switch error {
        case let error as SpannerDriverError:
            return error
        case let error as SpannerConfigurationError:
            return SpannerDriverError.configuration(error)
        case let error as GoogleAuthError:
            return SpannerDriverError.authentication(error)
        case let error as SpannerAPIError:
            return SpannerDriverError.server(error)
        case let error as SpannerExecutionError:
            return wrap(execution: error)
        case let error as SpannerTransportError:
            return error == .cancelled ? SpannerDriverError.cancelled : SpannerDriverError.transport(error)
        case let error as SpannerParameterEncodingError:
            return SpannerDriverError.parameterEncoding(error)
        case let error as SQLPlaceholderRewriteError:
            return wrap(placeholders: error)
        case is CancellationError:
            return SpannerDriverError.cancelled
        default:
            return error
        }
    }

    private static func wrap(execution error: SpannerExecutionError) -> SpannerDriverError {
        switch error {
        case .closed:
            return .notConnected
        case .parameterEncoding(let encoding):
            return .parameterEncoding(encoding)
        case .parameterCount(let found, let expected):
            return .placeholderCount(found: found, expected: expected)
        default:
            return .execution(error)
        }
    }

    private static func wrap(placeholders error: SQLPlaceholderRewriteError) -> SpannerDriverError {
        switch error {
        case .countMismatch(let found, let expected):
            return .placeholderCount(found: found, expected: expected)
        }
    }

    var pluginErrorMessage: String {
        switch self {
        case .notConnected:
            return String(localized: "Not connected to Spanner")
        case .configuration(let error):
            return Self.message(for: error)
        case .authentication(let error):
            return GoogleAuthErrorMessages.message(for: error)
        case .server(let error):
            return error.message
        case .execution(let error):
            return Self.message(for: error)
        case .transport(let error):
            return Self.message(for: error)
        case .parameterEncoding(let error):
            return Self.message(for: error)
        case .placeholderCount(let found, let expected):
            return String(
                format: String(localized: "The statement has %1$lld placeholders but %2$lld values were given."),
                Int64(found),
                Int64(expected)
            )
        case .objectNotFound(let name):
            return String(format: String(localized: "No DDL found for %@."), name)
        case .cancelled:
            return String(localized: "Query was cancelled")
        }
    }

    var pluginErrorCode: Int? {
        guard case .server(let error) = self else { return nil }
        return error.code ?? error.httpStatus
    }

    var pluginSqlState: String? {
        switch self {
        case .authentication(let error):
            return error.isAuthenticationFailure ? "28000" : nil
        case .server(let error):
            return error.isUnauthenticated ? "28000" : nil
        default:
            return nil
        }
    }

    private static func message(for error: SpannerConfigurationError) -> String {
        switch error {
        case .missingField(let key):
            return String(format: String(localized: "Enter the %@."), fieldLabel(key))
        case .invalidIdentifier(let key):
            return String(format: String(localized: "%@ contains characters Spanner does not allow."), fieldLabel(key))
        case .invalidEndpoint:
            return String(localized: "The REST endpoint is not a valid URL.")
        case .untrustedEndpoint:
            return String(localized: "The REST endpoint must be an https address under googleapis.com. Choose the Emulator auth method for a local emulator.")
        case .emulatorRequiresLoopback:
            return String(localized: "The emulator endpoint must be a local address, such as http://127.0.0.1:9020.")
        case .unknownAuthMethod:
            return String(localized: "Choose an auth method for this connection.")
        }
    }

    private static func fieldLabel(_ key: String) -> String {
        switch key {
        case "spProjectId":
            return String(localized: "Project ID")
        case "spInstanceId":
            return String(localized: "Instance ID")
        case "spDatabaseId":
            return String(localized: "Database")
        case "spEndpoint":
            return String(localized: "REST Endpoint")
        case "spServiceAccountJson":
            return String(localized: "Service Account Key")
        case "spOAuthClientId":
            return String(localized: "OAuth Client ID")
        case "spOAuthClientSecret":
            return String(localized: "OAuth Client Secret")
        default:
            return key
        }
    }

    private static func message(for error: SpannerExecutionError) -> String {
        switch error {
        case .transactionAlreadyOpen:
            return String(localized: "A transaction is already open. Commit or roll it back first.")
        case .noTransactionOpen:
            return String(localized: "No transaction is open.")
        case .transactionAborted:
            return String(localized: "Spanner aborted the transaction. Roll it back and run it again.")
        case .commitOutcomeUnknown:
            return String(localized: "The connection failed while Spanner was committing, so the changes may have been saved. Check the data before running it again.")
        case .explainNotSupported:
            return String(localized: "EXPLAIN works for queries and DML statements only.")
        case .explainAnalyzeNotSupported:
            return String(localized: "EXPLAIN ANALYZE runs the statement, so it is not available. Use EXPLAIN.")
        case .unsupportedTransactionControl:
            return String(localized: "Only BEGIN, COMMIT and ROLLBACK are supported for Spanner transactions.")
        case .schemaChangeStillRunning(let operation):
            return String(
                format: String(localized: "The schema change is still running on the server (%@)."),
                operation
            )
        case .parameterEncoding(let encoding):
            return message(for: encoding)
        case .parameterCount(let found, let expected):
            return SpannerDriverError.placeholderCount(found: found, expected: expected).pluginErrorMessage
        case .closed:
            return String(localized: "Not connected to Spanner")
        }
    }

    private static func message(for error: SpannerTransportError) -> String {
        switch error {
        case .closed:
            return String(localized: "Not connected to Spanner")
        case .cancelled:
            return String(localized: "Query was cancelled")
        case .timedOut:
            return String(localized: "The request to Spanner timed out.")
        case .network(let detail):
            return String(format: String(localized: "Can't reach Spanner: %@"), detail)
        case .invalidResponse:
            return String(localized: "Spanner returned a response that can't be read.")
        }
    }

    private static func message(for error: SpannerParameterEncodingError) -> String {
        switch error {
        case .notBoolean(let index):
            return String(format: String(localized: "Value %lld is not TRUE or FALSE."), Int64(index))
        case .notNumber(let index):
            return String(format: String(localized: "Value %lld is not a number."), Int64(index))
        case .notJSONArray(let index):
            return String(format: String(localized: "Value %lld is not a JSON array."), Int64(index))
        case .unsupportedType(let type):
            return String(format: String(localized: "Values of type %@ can't be written."), type)
        }
    }
}
