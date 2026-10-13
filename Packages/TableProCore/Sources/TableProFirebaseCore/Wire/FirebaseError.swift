import Foundation

public enum FirebaseError: Error, LocalizedError, Equatable, Sendable {
    case configuration(String)
    case notConnected
    case transport(String)
    /// The credential was refused outright: expired, revoked, or for another project.
    case authentication(String)
    /// The credential is valid but IAM or the security rules refuse this operation. Kept apart
    /// from an empty result so a blocked read never looks like a collection with no documents.
    case permissionDenied(operation: String, detail: String)
    case notFound(String)
    case precondition(String)
    case unsupported(String)
    case api(status: Int, message: String)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .configuration(let detail), .transport(let detail), .malformedResponse(let detail),
             .authentication(let detail), .notFound(let detail), .unsupported(let detail):
            return detail
        case .notConnected:
            return String(localized: "Not connected to Firebase.")
        case .permissionDenied(let operation, let detail):
            let lead = String(format: String(localized: "Permission denied: %@."), operation)
            return detail.isEmpty ? lead : lead + "\n" + detail
        case .precondition(let detail):
            return detail
        case .api(_, let message):
            return message
        }
    }

    /// `operation` names what was attempted, in the user's terms ("read users", "write /chats"),
    /// because Firebase's own denial text names neither the path nor the verb.
    public static func from(status: Int, body: Data, operation: String) -> FirebaseError {
        let message = apiMessage(from: body)
        switch status {
        case 401:
            return .authentication(message ?? String(localized: "Firebase refused the credential."))
        case 403:
            return .permissionDenied(operation: operation, detail: permissionHint(message))
        case 404:
            return .notFound(message ?? String(format: String(localized: "Not found: %@."), operation))
        case 409, 412:
            return .precondition(message ?? String(localized: "The data changed after it was read."))
        case 400 where apiStatus(from: body) == "FAILED_PRECONDITION":
            return .precondition(message ?? String(localized: "The data changed after it was read."))
        default:
            return .api(
                status: status,
                message: message ?? String(format: String(localized: "Firebase returned HTTP %d."), status)
            )
        }
    }

    /// The Realtime Database answers a rules denial with the bare words "Permission denied", and
    /// Firestore with a sentence that never mentions rules, so the hint says where to look.
    static func permissionHint(_ message: String?) -> String {
        let hint = String(
            localized: "The credential lacks the IAM role for this, or the security rules block it."
        )
        guard let message, !message.isEmpty else { return hint }
        if message.lowercased().trimmingCharacters(in: .punctuationCharacters) == "permission denied" {
            return hint
        }
        return message + "\n" + hint
    }

    /// Firestore names the failure in `error.status`, which tells a stale write or a missing
    /// index (`FAILED_PRECONDITION`) from a malformed request, all of them HTTP 400.
    static func apiStatus(from body: Data) -> String? {
        guard let json = try? FirebaseJSON.parse(body) else { return nil }
        let error = json.arrayValue?.first?["error"] ?? json["error"]
        return error?["status"]?.stringValue
    }

    /// Firestore errors are `{"error": {"message": ...}}` and Realtime Database errors are
    /// `{"error": "..."}`; both shapes are read here so the caller never sees raw JSON.
    public static func apiMessage(from body: Data) -> String? {
        guard let json = try? FirebaseJSON.parse(body) else {
            let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty ?? true) ? nil : text
        }
        if case .array(let items) = json, let first = items.first {
            return apiMessage(fromJSON: first)
        }
        return apiMessage(fromJSON: json)
    }

    private static func apiMessage(fromJSON json: FirebaseJSON) -> String? {
        if let error = json["error"] {
            if let text = error.stringValue, !text.isEmpty {
                return text
            }
            if let text = error["message"]?.stringValue, !text.isEmpty {
                return text
            }
        }
        if let text = json["message"]?.stringValue, !text.isEmpty {
            return text
        }
        return nil
    }
}
