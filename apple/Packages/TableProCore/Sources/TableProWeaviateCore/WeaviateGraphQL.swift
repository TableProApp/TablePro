import Foundation

public enum WeaviateGraphQL {
    public static func looksLikeGraphQL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { return true }
        let lowered = trimmed.lowercased()
        return lowered.hasPrefix("query") || lowered.hasPrefix("mutation") || lowered.hasPrefix("subscription")
            || lowered.hasPrefix("fragment")
    }

    public static func requestBody(query: String) throws -> Data {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["query"] != nil {
            return try WeaviateJSON.data(object)
        }
        return try WeaviateJSON.data(["query": trimmed])
    }
}

public struct WeaviateConsoleRequest: Sendable, Equatable {
    public let method: String
    public let path: String
    public let body: String?

    public init(method: String, path: String, body: String?) {
        self.method = method
        self.path = path
        self.body = body
    }
}

public enum WeaviateConsoleParser {
    public static func parse(_ input: String) -> WeaviateConsoleRequest? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let newline = trimmed.firstIndex(where: \.isNewline) else {
            return parseHeader(trimmed, body: nil)
        }
        let header = String(trimmed[..<newline])
        let rest = trimmed[trimmed.index(after: newline)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return parseHeader(header, body: rest.isEmpty ? nil : rest)
    }

    /// The whole REST API lives under `/v1`, so any other path is prefixed rather than a hand-listed
    /// four: `GET /nodes` and `POST /batch/objects` used to reach the base URL and answer 404.
    private static func parseHeader(_ header: String, body: String?) -> WeaviateConsoleRequest? {
        let parts = header.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        guard ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"].contains(method) else {
            return nil
        }
        let rawPath = String(parts[1])
        guard rawPath.hasPrefix("/") else { return nil }
        var path = rawPath
        if path != "/", path != "/v1", !path.hasPrefix("/v1/"), !path.hasPrefix("/v1?") {
            path = "/v1" + path
        }
        let inlineBody = parts.count > 2
            ? String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        // A body can open on the request line and go on below it, as `POST /v1/graphql {`.
        let joined = [inlineBody, body ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
        return WeaviateConsoleRequest(method: method, path: path, body: joined.isEmpty ? nil : joined)
    }
}
