import Foundation

/// A grid page travels as a tagged spec; everything else is a request line the user can read in
/// the history and type in the editor, such as `PATCH users/alice?updateMask=age {"age": 31}`.
public enum FirebaseStatement: Sendable, Equatable {
    case browse(FirebaseBrowseSpec)
    case request(FirebaseRequest)

    public static let browseTag = "FIREBASE_BROWSE:"

    public static func encode(_ spec: FirebaseBrowseSpec) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(spec)) ?? Data()
        return browseTag + data.base64EncodedString()
    }

    public static func parse(_ text: String) throws -> FirebaseStatement {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(browseTag) {
            let payload = String(trimmed.dropFirst(browseTag.count))
            guard let data = Data(base64Encoded: payload),
                  let spec = try? JSONDecoder().decode(FirebaseBrowseSpec.self, from: data) else {
                throw FirebaseError.malformedResponse(String(localized: "The browse request is damaged. Reopen the collection."))
            }
            return .browse(spec)
        }
        return .request(try FirebaseRequest.parse(trimmed))
    }
}

public struct FirebaseRequest: Sendable, Equatable {
    public enum Method: String, Sendable, CaseIterable {
        case get = "GET"
        case query = "QUERY"
        case put = "PUT"
        case patch = "PATCH"
        case post = "POST"
        case delete = "DELETE"
    }

    public let method: Method
    public let path: String
    public let query: [URLQueryItem]
    public let body: String?

    public init(method: Method, path: String, query: [URLQueryItem] = [], body: String? = nil) {
        self.method = method
        self.path = RealtimeDatabasePath.normalized(path)
        self.query = query
        self.body = body
    }

    public static func parse(_ text: String) throws -> FirebaseRequest {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let header = lines.first.map(String.init) ?? ""
        let parts = header.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace).map(String.init)
        guard let verb = parts.first, let method = Method(rawValue: verb.uppercased()) else {
            throw FirebaseError.configuration(usage)
        }
        var target = parts.count > 1 ? parts[1] : ""
        var inlineBody = parts.count > 2 ? parts[2] : ""
        if method == .query, target.hasPrefix("{") {
            inlineBody = ([target, inlineBody].filter { !$0.isEmpty }).joined(separator: " ")
            target = ""
        }
        let following = lines.count > 1 ? String(lines[1]) : ""
        let body = [inlineBody, following].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        var path = target
        var query: [URLQueryItem] = []
        if let mark = target.firstIndex(of: "?") {
            path = String(target[..<mark])
            query = parseQuery(String(target[target.index(after: mark)...]))
        }

        if body.isEmpty {
            switch method {
            case .put, .patch, .post:
                throw FirebaseError.configuration(String(format: String(localized: "%@ needs a JSON body after the path."), method.rawValue))
            case .query:
                throw FirebaseError.configuration(String(localized: "QUERY needs a JSON body with a structuredQuery."))
            case .get, .delete:
                break
            }
        }
        return FirebaseRequest(method: method, path: decodedPath(path), query: query, body: body.isEmpty ? nil : body)
    }

    public static func parseQuery(_ text: String) -> [URLQueryItem] {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "?& \n"))
        return trimmed.split(separator: "&").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let name = parts.first.map(decoded), !name.isEmpty else { return nil }
            return URLQueryItem(name: name, value: parts.count > 1 ? decoded(parts[1]) : "")
        }
    }

    public func queryValue(_ name: String) -> String? {
        query.first { $0.name == name }?.value
    }

    /// Escapes only what `parse` splits on, so an ID with a space, `&` or `=` reads back whole and
    /// the rest of the line stays readable.
    public var text: String {
        var line = method.rawValue + " " + (path.isEmpty ? "/" : Self.encodedPath(path))
        if !query.isEmpty {
            line += "?" + query.map { Self.escaped($0.name) + "=" + Self.escaped($0.value ?? "") }.joined(separator: "&")
        }
        if let body { line += " " + body }
        return line
    }

    /// Kept out of the localized key, so a translator never edits a request and a test can run each one.
    static let usageExamples = [
        "GET users/alice",
        #"QUERY {"structuredQuery": {"from": [{"collectionId": "users"}]}}"#,
        #"PATCH users/alice {"age": 31}"#,
        "DELETE users/alice"
    ]

    static let usage = String(format: String(localized: "Enter a request such as %@, %@, %@ or %@."), arguments: usageExamples)

    private static let escapedScalars = CharacterSet.whitespacesAndNewlines
        .union(.controlCharacters)
        .union(CharacterSet(charactersIn: "%?#&=/"))

    static func escaped(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            guard escapedScalars.contains(scalar) else {
                result.append(scalar)
                continue
            }
            for byte in String(scalar).utf8 {
                result.append(contentsOf: String(format: "%%%02X", byte).unicodeScalars)
            }
        }
        return String(result)
    }

    private static func decoded(_ text: String) -> String {
        text.removingPercentEncoding ?? text
    }

    private static func encodedPath(_ path: String) -> String {
        path.split(separator: "/").map { escaped(String($0)) }.joined(separator: "/")
    }

    private static func decodedPath(_ path: String) -> String {
        path.split(separator: "/").map { decoded(String($0)) }.joined(separator: "/")
    }
}
