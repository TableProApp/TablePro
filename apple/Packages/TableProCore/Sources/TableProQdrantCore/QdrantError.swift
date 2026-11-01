import Foundation

public enum QdrantError: Error, LocalizedError, Equatable, Sendable {
    case configuration(String)
    case notConnected
    case transport(String)
    case authentication(String)
    case api(status: Int, message: String)
    case malformedResponse(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .configuration(let detail), .transport(let detail), .malformedResponse(let detail),
             .authentication(let detail):
            return detail
        case .notConnected:
            return String(localized: "Not connected to Qdrant.")
        case .api(_, let message):
            return message
        case .cancelled:
            return String(localized: "The request was cancelled.")
        }
    }

    public static func from(status: Int, body: Data) -> QdrantError {
        let message = apiMessage(from: body)
            ?? String(format: String(localized: "Qdrant returned HTTP %d."), status)
        if status == 401 || status == 403 {
            return .authentication(message)
        }
        return .api(status: status, message: message)
    }

    /// Qdrant puts the reason in `status.error`; a proxy in front of it may answer with plain text.
    public static func apiMessage(from body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) else {
            let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty ?? true) ? nil : text
        }
        guard let object = json as? [String: Any] else { return nil }
        if let status = object["status"] as? [String: Any],
           let error = status["error"] as? String, !error.isEmpty {
            return error
        }
        if let error = object["error"] as? String, !error.isEmpty {
            return error
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }
}
