import Foundation

struct DynamoDBCancellationReason: Sendable, Equatable {
    let code: String
    let message: String?
}

enum DynamoDBError: Error, LocalizedError, Sendable, Equatable {
    case notConnected
    case configuration(String)
    case service(DynamoDBServiceError)
    case transport(String)
    case cancelled
    case timedOut(seconds: Int)
    case invalidStatement(String)
    case invalidValue(attribute: String, reason: String)
    case invalidResponse(String)
    case itemChanged(key: String)
    case itemMissing(key: String)
    case partialBatch(applied: Int, total: Int, failures: [String])

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Not connected to DynamoDB")
        case .configuration(let message):
            return message
        case .service(let error):
            return error.userMessage
        case .transport(let detail):
            return String(format: String(localized: "Connection failed: %@"), detail)
        case .cancelled:
            return String(localized: "Request was cancelled")
        case .timedOut(let seconds):
            return String(format: String(localized: "Stopped after %d seconds, the query timeout"), seconds)
        case .invalidStatement(let message):
            return message
        case .invalidValue(let attribute, let reason):
            guard !attribute.isEmpty else { return reason }
            return String(format: String(localized: "%@: %@"), attribute, reason)
        case .invalidResponse(let detail):
            return String(format: String(localized: "Invalid response: %@"), detail)
        case .itemChanged(let key):
            return String(format: String(
                localized: "The item %@ changed after it was loaded. Refresh the table and edit it again."
            ), key)
        case .itemMissing(let key):
            return String(format: String(localized: "The item %@ no longer exists."), key)
        case .partialBatch(let applied, let total, let failures):
            let summary = String(format: String(localized: "%1$d of %2$d were applied."), applied, total)
            return ([summary] + failures).joined(separator: "\n")
        }
    }
}

/// An error DynamoDB answered with. `code` is the part of `__type` after `#`, so
/// `com.amazonaws.dynamodb.v20120810#ConditionalCheckFailedException` and
/// `com.amazon.coral.validate#ValidationException` both compare by their short name.
struct DynamoDBServiceError: Sendable, Equatable {
    let code: String
    let message: String
    let httpStatus: Int
    let cancellationReasons: [DynamoDBCancellationReason]

    init(code: String, message: String, httpStatus: Int, cancellationReasons: [DynamoDBCancellationReason] = []) {
        self.code = code
        self.message = message
        self.httpStatus = httpStatus
        self.cancellationReasons = cancellationReasons
    }

    static func parse(body: Data, httpStatus: Int) -> DynamoDBServiceError {
        guard let json = try? DynamoDBJSON.parse(body) else {
            return DynamoDBServiceError(
                code: "HTTP\(httpStatus)",
                message: String(format: String(localized: "HTTP %d with a body of %d bytes"), httpStatus, body.count),
                httpStatus: httpStatus
            )
        }
        let rawType = json["__type"]?.stringValue ?? "HTTP\(httpStatus)"
        let code = rawType.split(separator: "#").last.map(String.init) ?? rawType
        let message = json["message"]?.stringValue ?? json["Message"]?.stringValue ?? code
        let reasons = (json["CancellationReasons"]?.arrayValue ?? []).map { reason in
            DynamoDBCancellationReason(
                code: reason["Code"]?.stringValue ?? "None",
                message: reason["Message"]?.stringValue
            )
        }
        return DynamoDBServiceError(code: code, message: message, httpStatus: httpStatus, cancellationReasons: reasons)
    }

    enum Category: Equatable {
        case throttling
        case transient
        case expiredCredentials
        case clockSkew
        case authentication
        case fatal
    }

    var category: Category {
        if Self.throttlingCodes.contains(code) { return .throttling }
        if Self.transientCodes.contains(code) || httpStatus >= 500 { return .transient }
        if code == "ExpiredTokenException" || code == "ExpiredToken" { return .expiredCredentials }
        if Self.skewCodes.contains(code) || isSignatureExpiry { return .clockSkew }
        if Self.authenticationCodes.contains(code) { return .authentication }
        return .fatal
    }

    var isConditionalCheckFailure: Bool {
        code == "ConditionalCheckFailedException"
    }

    private var isSignatureExpiry: Bool {
        guard code == "InvalidSignatureException" else { return false }
        let lowered = message.lowercased()
        return lowered.contains("signature expired") || lowered.contains("signature not yet current")
    }

    private static let throttlingCodes: Set<String> = [
        "ProvisionedThroughputExceededException",
        "ThrottlingException",
        "RequestLimitExceeded",
        "LimitExceededException",
        "TransactionInProgressException",
        "ReplicatedWriteConflictException",
        "ItemCollectionSizeLimitExceededException"
    ]

    private static let transientCodes: Set<String> = [
        "InternalServerError",
        "InternalFailure",
        "ServiceUnavailable",
        "ServiceUnavailableException"
    ]

    private static let skewCodes: Set<String> = [
        "RequestTimeTooSkewed",
        "RequestExpired",
        "RequestInTheFuture"
    ]

    private static let authenticationCodes: Set<String> = [
        "UnrecognizedClientException",
        "InvalidSignatureException",
        "MissingAuthenticationTokenException",
        "MissingAuthenticationToken",
        "IncompleteSignatureException",
        "InvalidClientTokenId"
    ]

    var userMessage: String {
        var text: String
        if category == .authentication {
            text = String(format: String(localized: "Authentication failed: %@"), message)
        } else {
            text = String(format: String(localized: "DynamoDB error: [%1$@] %2$@"), code, message)
        }
        let failures = cancellationReasons.enumerated().compactMap { index, reason -> String? in
            guard reason.code != "None" else { return nil }
            let detail = reason.message.map { " \($0)" } ?? ""
            return String(format: String(localized: "Action %1$d: %2$@%3$@"), index + 1, reason.code, detail)
        }
        if !failures.isEmpty {
            text += "\n" + failures.joined(separator: "\n")
        }
        return text
    }
}
