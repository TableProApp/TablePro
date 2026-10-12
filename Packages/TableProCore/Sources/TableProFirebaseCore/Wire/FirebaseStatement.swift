import Foundation

/// The text the driver runs. A page the grid asks for travels as a tagged spec; everything else is
/// a request line the user can read in the history and type in the editor:
///
///     GET users/alice                 PATCH users/alice?updateMask=age {"age": 31}
///     QUERY {"structuredQuery": ...}  POST users {"name": "Bob"}        DELETE users/alice
///
/// The Realtime Database takes the same verbs against a node: `GET /chats?shallow=true`,
/// `PUT /config/maintenance false`, `PATCH`, `POST` and `DELETE`.
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

        public var isRead: Bool {
            self == .get || self == .query
        }
    }

    public let method: Method
    public let path: String
    public let query: [URLQueryItem]
    public let body: String?

    public init(method: Method, path: String, query: [URLQueryItem] = [], body: String? = nil) {
        self.method = method
        self.path = path
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
            query = RealtimeDatabaseReadPlan.parseRawQuery(String(target[target.index(after: mark)...]))
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

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
        return FirebaseRequest(method: method, path: path, query: query, body: body.isEmpty ? nil : body)
    }

    public func queryValue(_ name: String) -> String? {
        query.first { $0.name == name }?.value
    }

    /// The request line as the history shows it and as `parse` reads it back.
    public var text: String {
        var line = method.rawValue + " " + (path.isEmpty ? "/" : path)
        if !query.isEmpty {
            line += "?" + query.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        }
        if let body { line += " " + body }
        return line
    }

    static let usage = String(
        localized: "Enter a request such as GET users/alice, QUERY {\"structuredQuery\": {...}}, PATCH users/alice {\"age\": 31} or DELETE users/alice."
    )
}

public enum FirebaseStatementClassifier {
    public enum Tier: Sendable, Equatable {
        case read
        case write
        case destructive
    }

    /// Text that is neither a browse nor a request line counts as a write, so the read-only gate
    /// refuses what it cannot read rather than letting it through.
    public static func classify(_ text: String) -> Tier {
        guard let statement = try? FirebaseStatement.parse(text) else { return .write }
        switch statement {
        case .browse:
            return .read
        case .request(let request):
            switch request.method {
            case .get, .query: return .read
            case .delete: return .destructive
            case .put, .patch, .post: return .write
            }
        }
    }
}
