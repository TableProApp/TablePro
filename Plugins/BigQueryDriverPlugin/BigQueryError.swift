import Foundation
import TableProGoogleCloud
import TableProPluginKit

internal enum BigQueryConfigurationError: Error, Sendable, Equatable {
    case missingField(String)
    case unknownAuthMethod
}

internal enum BigQueryError: PluginDriverError {
    case notConnected
    case configuration(BigQueryConfigurationError)
    case authentication(GoogleAuthError)
    case api(status: Int, message: String, reason: String?)
    case jobFailed(message: String, reason: String?)
    case invalidResponse
    case transport(String)
    case requestTimedOut
    case jobTimedOut(seconds: Int)
    case cancelled
    case parameterEncoding(BigQueryParameterEncodingError)
    case placeholderCount(found: Int, expected: Int)
    case unreadableBrowseRequest
    case ddlNotFound(String)
    case viewDefinitionNotFound(String)

    static let invalidAuthorizationSQLState = "28000"
    static let invalidQueryReason = "invalidQuery"

    private static let unauthorizedStatus = 401
    private static let partitionFilterMarker = "partition"

    static func wrap(_ error: Error) -> Error {
        switch error {
        case let error as BigQueryError:
            return error
        case let error as GoogleAuthError:
            return BigQueryError.authentication(error)
        case let error as BigQueryConfigurationError:
            return BigQueryError.configuration(error)
        case let error as BigQueryParameterEncodingError:
            return BigQueryError.parameterEncoding(error)
        case let error as SQLPlaceholderRewriteError:
            return wrap(placeholders: error)
        case is CancellationError:
            return BigQueryError.cancelled
        case let error as URLError:
            return wrap(urlError: error)
        default:
            return error
        }
    }

    var isInvalidQuery: Bool {
        switch self {
        case .api(_, _, let reason), .jobFailed(_, let reason):
            return reason == Self.invalidQueryReason
        default:
            return false
        }
    }

    var pluginErrorMessage: String {
        switch self {
        case .notConnected:
            return String(localized: "Not connected to BigQuery")
        case .configuration(let error):
            return Self.message(for: error)
        case .authentication(let error):
            return GoogleAuthErrorMessages.message(for: error)
        case .api(let status, let message, _):
            guard message.isEmpty else { return message }
            return String(format: String(localized: "BigQuery returned HTTP %lld."), Int64(status))
        case .jobFailed(let message, _):
            guard message.isEmpty else { return message }
            return String(localized: "The BigQuery job failed.")
        case .invalidResponse:
            return String(localized: "BigQuery returned a response that can't be read.")
        case .transport(let detail):
            return String(format: String(localized: "Can't reach BigQuery: %@"), detail)
        case .requestTimedOut:
            return String(localized: "The request to BigQuery timed out.")
        case .jobTimedOut(let seconds):
            return String(
                format: String(localized: "The BigQuery job did not finish within %lld seconds and was cancelled."),
                Int64(seconds)
            )
        case .cancelled:
            return String(localized: "Query was cancelled")
        case .parameterEncoding(let error):
            return Self.message(for: error)
        case .placeholderCount(let found, let expected):
            return String(
                format: String(localized: "The statement has %1$lld placeholders but %2$lld values were given."),
                Int64(found),
                Int64(expected)
            )
        case .unreadableBrowseRequest:
            return String(localized: "The table browse request can't be read.")
        case .ddlNotFound(let name):
            return String(format: String(localized: "No DDL found for %@."), name)
        case .viewDefinitionNotFound(let name):
            return String(format: String(localized: "No view definition found for %@."), name)
        }
    }

    var pluginErrorCode: Int? {
        guard case .api(let status, _, _) = self else { return nil }
        return status
    }

    var pluginSqlState: String? {
        switch self {
        case .authentication(let error):
            return error.isAuthenticationFailure ? Self.invalidAuthorizationSQLState : nil
        case .api(let status, _, _):
            return status == Self.unauthorizedStatus ? Self.invalidAuthorizationSQLState : nil
        default:
            return nil
        }
    }

    var pluginErrorDetail: String? {
        guard case .jobFailed(let message, _) = self,
              message.localizedCaseInsensitiveContains(Self.partitionFilterMarker)
        else {
            return nil
        }
        return String(localized: "This table requires a partition filter. Add a WHERE clause on the partition column.")
    }

    private static func wrap(placeholders error: SQLPlaceholderRewriteError) -> BigQueryError {
        switch error {
        case .countMismatch(let found, let expected):
            return .placeholderCount(found: found, expected: expected)
        }
    }

    private static func wrap(urlError error: URLError) -> BigQueryError {
        switch error.code {
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .requestTimedOut
        default:
            return .transport(error.localizedDescription)
        }
    }

    private static func message(for error: BigQueryConfigurationError) -> String {
        switch error {
        case .missingField(let key):
            return String(format: String(localized: "Enter the %@."), fieldLabel(key))
        case .unknownAuthMethod:
            return String(localized: "Choose an auth method for this connection.")
        }
    }

    private static func fieldLabel(_ key: String) -> String {
        switch key {
        case BigQueryConnectionFields.projectId:
            return String(localized: "Project ID")
        case BigQueryConnectionFields.serviceAccountKey:
            return String(localized: "Service Account Key")
        case BigQueryConnectionFields.oauthClientId:
            return String(localized: "OAuth Client ID")
        case BigQueryConnectionFields.oauthClientSecret:
            return String(localized: "OAuth Client Secret")
        default:
            return key
        }
    }

    private static func message(for error: BigQueryParameterEncodingError) -> String {
        switch error {
        case .notJSONArray(let position):
            return String(format: String(localized: "Value %lld is not a JSON array."), Int64(position))
        case .notJSONObject(let position):
            return String(format: String(localized: "Value %lld is not a JSON object."), Int64(position))
        case .notRange(let position):
            return String(format: String(localized: "Value %lld is not a range such as [start, end)."), Int64(position))
        case .notText(let position):
            return String(format: String(localized: "Value %lld is binary data, not text."), Int64(position))
        case .unsupportedType(let type):
            return String(format: String(localized: "Values of type %@ can't be written."), type)
        }
    }
}
