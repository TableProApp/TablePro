import Foundation

public struct R2SQLAPIError: Decodable, Sendable, Equatable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case code, message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decodeIfPresent(Int.self, forKey: .code) ?? 0
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
    }
}

public enum R2SQLError: Error, LocalizedError, Equatable {
    case configuration(String)
    case notConnected
    case transport(String)
    case authentication(status: Int, errors: [R2SQLAPIError])
    case api(status: Int, errors: [R2SQLAPIError])
    case malformedResponse(status: Int, detail: String)
    case unexpectedResult(String)
    case unsupported(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .configuration(let detail), .transport(let detail), .unexpectedResult(let detail),
             .unsupported(let detail):
            return detail
        case .notConnected:
            return "Not connected to R2 SQL."
        case .authentication(let status, let errors):
            let reason = Self.joined(errors) ?? "HTTP \(status)"
            return "\(reason). The API token needs the R2 SQL, R2 Data Catalog and R2 Storage permissions for this account."
        case .api(let status, let errors):
            return Self.joined(errors) ?? "R2 SQL returned HTTP \(status) with no error message."
        case .malformedResponse(let status, let detail):
            return "R2 SQL returned a response TablePro could not read (HTTP \(status)): \(detail)"
        case .cancelled:
            return "The query was cancelled."
        }
    }

    private static func joined(_ errors: [R2SQLAPIError]) -> String? {
        let messages = errors.map(\.message).filter { !$0.isEmpty }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
}
