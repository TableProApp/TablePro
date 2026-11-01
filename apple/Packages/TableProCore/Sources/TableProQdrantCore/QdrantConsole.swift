import Foundation

public struct QdrantConsoleRequest: Sendable, Equatable {
    public let method: String
    public let path: String
    public let body: String?

    public init(method: String, path: String, body: String?) {
        self.method = method
        self.path = path
        self.body = body
    }

    /// The POST endpoints that only read. Retrieving points by id is a POST to `/points` itself.
    static let readSuffixes: [[String]] = [
        ["points"], ["points", "scroll"], ["points", "search"], ["points", "query"], ["points", "count"],
        ["points", "recommend"], ["points", "discover"], ["points", "facet"],
        ["points", "search", "batch"], ["points", "query", "batch"], ["points", "recommend", "batch"],
        ["points", "discover", "batch"], ["points", "search", "groups"], ["points", "query", "groups"],
        ["points", "recommend", "groups"], ["points", "search", "matrix", "pairs"],
        ["points", "search", "matrix", "offsets"]
    ]

    public var isRead: Bool {
        if method == "GET" || method == "HEAD" { return true }
        guard method == "POST" else { return false }
        let route = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let segments = route.split(separator: "/").map { $0.lowercased() }
        guard segments.count >= 3, segments[0] == "collections" else { return false }
        return Self.readSuffixes.contains { Array(segments.dropFirst(2)) == $0 }
    }
}

/// One REST request typed in the editor: `METHOD /path`, then an optional JSON body on the same
/// line or on the lines below it.
public enum QdrantConsoleParser {
    static let methods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]

    public static func parse(_ input: String) -> QdrantConsoleRequest? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let header = lines.first else { return nil }
        let following = lines.count > 1
            ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        let parts = header.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        guard methods.contains(method) else { return nil }
        let path = String(parts[1])
        guard path.hasPrefix("/"), !path.hasPrefix("//") else { return nil }
        let inline = parts.count > 2 ? String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let body = inline.isEmpty ? following : inline
        return QdrantConsoleRequest(method: method, path: path, body: body.isEmpty ? nil : body)
    }
}

public enum QdrantPathEncoding {
    private static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_.")
        return set
    }()

    public static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// The path keeps its own query string (`?wait=true`): assigning it whole to `URLComponents.path`
    /// would encode the `?` and send the request to a path that does not exist.
    public static func resolve(_ path: String, against base: URL) -> URL? {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("://"),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let requested = URLComponents(string: path)
        else { return nil }
        components.percentEncodedPath = requested.percentEncodedPath
        components.percentEncodedQuery = requested.percentEncodedQuery
        return components.url
    }
}

public enum QdrantOperations {
    public static let exportTag = "QDRANT_EXPORT:"

    /// The console request that removes one collection. Plain request text, so the confirmation shows
    /// it verbatim and the query classifier tiers it destructive by its verb.
    public static func deleteCollection(named name: String, objectType: String) -> String? {
        guard objectType.uppercased() == "TABLE", !name.isEmpty else { return nil }
        return "DELETE /collections/\(QdrantPathEncoding.segment(name))"
    }

    /// An empty filter matches every point, which keeps the collection and its config.
    public static func deleteAllPoints(collection: String) -> String? {
        guard !collection.isEmpty else { return nil }
        return "POST /collections/\(QdrantPathEncoding.segment(collection))/points/delete?wait=true\n{\"filter\":{}}"
    }

    public static func encodeExport(collection: String) -> String {
        exportTag + Data(collection.utf8).base64EncodedString()
    }

    public static func decodeExport(_ query: String) -> String? {
        guard query.hasPrefix(exportTag),
              let data = Data(base64Encoded: String(query.dropFirst(exportTag.count))),
              let collection = String(data: data, encoding: .utf8),
              !collection.isEmpty
        else { return nil }
        return collection
    }
}
