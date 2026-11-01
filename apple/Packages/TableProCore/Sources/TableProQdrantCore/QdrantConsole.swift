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

    // What the review sheet shows, the classifier tiers and the driver runs are this one string.
    public var text: String {
        guard let body else { return "\(method) \(path)" }
        return "\(method) \(path)\n\(body)"
    }

    public var kind: QdrantRequestKind { QdrantRequestKind.of(method: method, path: path) }
}

// `METHOD /path`, then an optional JSON body that may start on the request line and go on below it.
public enum QdrantConsoleParser {
    static let methods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]

    public static func parse(_ input: String) -> QdrantConsoleRequest? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let newline = trimmed.firstIndex(where: \.isNewline)
        let header = newline.map { trimmed[..<$0] } ?? trimmed[...]
        let following = newline.map { trimmed[trimmed.index(after: $0)...] } ?? ""

        let parts = header.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        guard methods.contains(method) else { return nil }
        let path = String(parts[1])
        guard path.hasPrefix("/"), !path.hasPrefix("//") else { return nil }
        let inline = parts.count > 2 ? parts[2] : ""
        let body = [inline, following]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return QdrantConsoleRequest(method: method, path: path, body: body.isEmpty ? nil : body)
    }
}

public struct QdrantRequestKind: Sendable, Equatable {
    public enum Tier: Sendable, Equatable {
        case read
        case write
        case remove
    }

    public let tier: Tier
    // A snapshot is written to the server's disk, and recovering one fetches a URL from the server.
    public let touchesServerFiles: Bool

    public init(tier: Tier, touchesServerFiles: Bool) {
        self.tier = tier
        self.touchesServerFiles = touchesServerFiles
    }

    // The POSTs under `/collections/<name>/` that only read. Retrieving points by id is a POST to `points`.
    static let readRoutes: Set<[String]> = [
        ["points"], ["points", "scroll"], ["points", "search"], ["points", "query"], ["points", "count"],
        ["points", "recommend"], ["points", "discover"], ["facet"],
        ["points", "search", "batch"], ["points", "query", "batch"], ["points", "recommend", "batch"],
        ["points", "discover", "batch"], ["points", "search", "groups"], ["points", "query", "groups"],
        ["points", "recommend", "groups"], ["points", "search", "matrix", "pairs"],
        ["points", "search", "matrix", "offsets"]
    ]

    // `/snapshots`, `/collections/{name}/snapshots` and `/collections/{name}/shards/{id}/snapshots`, by
    // position, so a collection that is itself named `snapshots` is not one.
    static func touchesSnapshots(_ route: [String]) -> Bool {
        if route.first == "snapshots" { return true }
        guard route.count >= 3, route[0] == "collections" else { return false }
        return route[2] == "snapshots" || (route.count >= 5 && route[2] == "shards" && route[4] == "snapshots")
    }

    public static func of(method: String, path: String) -> QdrantRequestKind {
        let verb = method.uppercased()
        guard let route = QdrantPathEncoding.segments(of: path) else {
            return QdrantRequestKind(tier: .write, touchesServerFiles: true)
        }
        let touchesServerFiles = touchesSnapshots(route)
        if verb == "GET" || verb == "HEAD" {
            return QdrantRequestKind(tier: .read, touchesServerFiles: touchesServerFiles)
        }
        let subroute = route.count >= 3 && route[0] == "collections" ? Array(route.dropFirst(2)) : []
        if verb == "POST", readRoutes.contains(subroute) {
            return QdrantRequestKind(tier: .read, touchesServerFiles: touchesServerFiles)
        }
        // A batch can carry deletes, and a POST ending in `delete` or `clear` removes points or payload. Some
        // routes delete through the body: a PUT of the payload replaces it whole, the cluster route drops
        // shard keys and replicas, and the aliases route deletes aliases.
        let removes = verb == "DELETE" || route.last == "delete" || route.last == "clear"
            || subroute == ["points", "batch"]
            || (verb == "PUT" && subroute == ["points", "payload"])
            || subroute.first == "cluster"
            || route == ["collections", "aliases"]
        return QdrantRequestKind(tier: removes ? .remove : .write, touchesServerFiles: touchesServerFiles)
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

    // Decoded and lowercased; nil for a dot segment, which would move the request to a route other than
    // the one it reads as.
    public static func segments(of path: String) -> [String]? {
        guard let requested = URLComponents(string: path) else { return nil }
        let segments = requested.percentEncodedPath.split(separator: "/").map { String($0) }
        var decoded: [String] = []
        for segment in segments {
            guard let text = segment.removingPercentEncoding, text != ".", text != "..", !text.contains("/") else {
                return nil
            }
            decoded.append(text.lowercased())
        }
        return decoded
    }

    // Assigning the path whole to `URLComponents.path` would encode the `?` of `?wait=true`.
    public static func resolve(_ path: String, against base: URL) -> URL? {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("://"),
              segments(of: path) != nil,
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

    public static func deleteCollection(named name: String, objectType: String) -> String? {
        guard objectType.uppercased() == "TABLE", !name.isEmpty else { return nil }
        return "DELETE /collections/\(QdrantPathEncoding.segment(name))"
    }

    // An empty filter matches every point and keeps the collection with its config and indexes.
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

    public static func isTagged(_ query: String) -> Bool {
        query.hasPrefix(QdrantBrowseQuery.tag) || query.hasPrefix(exportTag) || query.hasPrefix(QdrantInsertCheck.tag)
    }
}
