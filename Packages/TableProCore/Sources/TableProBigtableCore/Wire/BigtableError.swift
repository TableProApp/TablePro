import Foundation

public enum BigtableError: Error, LocalizedError, Equatable, Sendable {
    case configuration(String)
    case notConnected
    case transport(String)
    case authentication(String)
    /// IAM refused the operation. Kept apart from an empty result so a blocked read never looks
    /// like a table with no rows.
    case permissionDenied(operation: String, detail: String)
    case notFound(String)
    case unsupported(String)
    case api(status: Int, message: String)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .configuration(let detail), .transport(let detail), .malformedResponse(let detail),
             .authentication(let detail), .notFound(let detail), .unsupported(let detail):
            return detail
        case .notConnected:
            return String(localized: "Not connected to Bigtable.")
        case .permissionDenied(let operation, let detail):
            let lead = String(format: String(localized: "Permission denied: %@."), operation)
            return detail.isEmpty ? lead : lead + "\n" + detail
        case .api(_, let message):
            return message
        }
    }

    /// `operation` names what was attempted ("read events", "write a row of events"), because
    /// Google's denial text names the permission and not the table.
    public static func from(status: Int, body: Data, operation: String) -> BigtableError {
        let message = apiMessage(from: body)
        switch status {
        case 401:
            return .authentication(message ?? String(localized: "Google refused the credential."))
        case 403:
            return .permissionDenied(operation: operation, detail: message ?? "")
        case 404:
            return .notFound(message ?? String(format: String(localized: "Not found: %@."), operation))
        default:
            return .api(
                status: status,
                message: message ?? String(format: String(localized: "Bigtable returned HTTP %d."), status)
            )
        }
    }

    /// A streaming method answers an error as a one-element array, a unary one as an object.
    public static func apiMessage(from body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else {
            let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty ?? true) ? nil : text
        }
        let object = (json as? [[String: Any]])?.first ?? json as? [String: Any]
        let error = object?["error"] as? [String: Any]
        if let message = error?["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }
}
