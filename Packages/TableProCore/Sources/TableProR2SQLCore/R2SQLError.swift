import Foundation

public struct R2SQLAPIError: Decodable, Sendable, Equatable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

public enum R2SQLError: Error, LocalizedError, Equatable {
    case configuration(String)
    case notConnected
    case transport(String)
    case authentication(String)
    case query(R2SQLAPIError)
    case api([R2SQLAPIError])
    case malformedResponse(status: Int, body: String)
    case unsupported(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .configuration(let detail):
            return detail
        case .notConnected:
            return "Not connected to R2 SQL"
        case .transport(let detail):
            return detail
        case .authentication(let detail):
            return detail
        case .query(let error):
            return error.message
        case .api(let errors):
            let joined = errors.map(\.message).filter { !$0.isEmpty }.joined(separator: "\n")
            return joined.isEmpty ? "R2 SQL returned an unspecified error" : joined
        case .malformedResponse(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "R2 SQL returned an unreadable response (HTTP \(status))"
            }
            return "R2 SQL returned an unreadable response (HTTP \(status)): \(trimmed.prefix(200))"
        case .unsupported(let detail):
            return detail
        case .cancelled:
            return "Query was cancelled"
        }
    }
}

public enum R2SQLErrorText {
    public static let missingAccountId = "Account ID is required"
    public static let missingBucket = "Bucket is required"
    public static let missingToken = "API token is required"
    public static let invalidEndpoint = "Could not build the R2 SQL endpoint from the account ID and bucket"
    public static let noNamespace = "Select a namespace before browsing tables"
    public static let noViews = "R2 SQL does not support views"
    public static let readOnlyEngine = "R2 SQL is a read-only query engine"
}
