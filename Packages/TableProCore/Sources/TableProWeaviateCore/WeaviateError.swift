import Foundation

public enum WeaviateError: Error, LocalizedError, Equatable, Sendable {
    case configuration(String)
    case notConnected
    case transport(String)
    case authentication(String)
    case api(status: Int, message: String)
    case malformedResponse(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .configuration(let detail), .transport(let detail), .malformedResponse(let detail):
            return detail
        case .notConnected:
            return String(localized: "Not connected to Weaviate.")
        case .authentication(let detail):
            return detail
        case .api(_, let message):
            return message
        case .cancelled:
            return String(localized: "The request was cancelled.")
        }
    }

    public static func from(status: Int, body: Data) -> WeaviateError {
        let message = apiMessage(from: body)
            ?? String(format: String(localized: "Weaviate returned HTTP %d."), status)
        if status == 401 || status == 403 {
            return .authentication(message)
        }
        return .api(status: status, message: message)
    }

    public static func apiMessage(from body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) else {
            let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty ?? true) ? nil : text
        }
        if let object = json as? [String: Any] {
            if let errors = object["error"] as? [[String: Any]] {
                let messages = errors.compactMap { $0["message"] as? String }.filter { !$0.isEmpty }
                if !messages.isEmpty {
                    return messages.joined(separator: "\n")
                }
            }
            if let error = object["error"] as? String, !error.isEmpty {
                return error
            }
            if let message = object["message"] as? String, !message.isEmpty {
                return message
            }
        }
        return nil
    }
}
