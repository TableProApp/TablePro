import Foundation

public struct TrinoQueryError: Decodable, Sendable, Equatable {
    public let message: String
    public let errorCode: Int?
    public let errorName: String?
    public let errorType: String?

    public init(message: String, errorCode: Int? = nil, errorName: String? = nil, errorType: String? = nil) {
        self.message = message
        self.errorCode = errorCode
        self.errorName = errorName
        self.errorType = errorType
    }

    private enum CodingKeys: String, CodingKey {
        case message, errorCode, errorName, errorType
    }
}

public enum TrinoError: Error, LocalizedError, Equatable {
    case invalidConfiguration(String)
    case notConnected
    case transport(String)
    case httpStatus(code: Int, body: String)
    case authenticationFailed(String)
    case query(TrinoQueryError)
    case invalidResponse(String)
    case cancelled
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail):
            return detail
        case .notConnected:
            return "Not connected to Trino"
        case .transport(let detail):
            return detail
        case .httpStatus(let code, let body):
            return body.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(body)"
        case .authenticationFailed(let detail):
            return detail
        case .query(let error):
            if let name = error.errorName, !name.isEmpty {
                return "\(name): \(error.message)"
            }
            return error.message
        case .invalidResponse(let detail):
            return detail
        case .cancelled:
            return "Query was cancelled"
        case .timedOut:
            return "Timed out waiting for Trino"
        }
    }
}
