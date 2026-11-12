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
        if let payload = FirebaseScalars.removingPrefix(browseTag, from: trimmed) {
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
        let lines = FirebaseScalars.split(trimmed, separator: "\n", maxSplits: 1, omittingEmpty: false)
        let header = lines.first ?? ""
        let parts = header.unicodeScalars
            .split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: isSeparator)
            .map(String.init)
        guard let verb = parts.first, let method = Method(rawValue: verb.uppercased()) else {
            throw FirebaseError.configuration(usage)
        }
        var target = parts.count > 1 ? parts[1] : ""
        var inlineBody = parts.count > 2 ? parts[2] : ""
        if method == .query, target.unicodeScalars.first == "{" {
            inlineBody = ([target, inlineBody].filter { !$0.isEmpty }).joined(separator: " ")
            target = ""
        }
        let following = lines.count > 1 ? lines[1] : ""
        let body = [inlineBody, following].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        var path = target
        var query: [URLQueryItem] = []
        let scalars = target.unicodeScalars
        if let mark = scalars.firstIndex(of: "?") {
            path = String(scalars[..<mark])
            query = parseQuery(String(scalars[scalars.index(after: mark)...]))
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
        return FirebaseScalars.split(trimmed, separator: "&").compactMap { pair in
            let parts = FirebaseScalars.split(pair, separator: "=", maxSplits: 1)
            guard let name = parts.first.map(decoded), !name.isEmpty else { return nil }
            return URLQueryItem(name: name, value: parts.count > 1 ? decoded(parts[1]) : "")
        }
    }

    public func queryValue(_ name: String) -> String? {
        query.first { $0.name == name }?.value
    }

    /// Escapes only what `parse` reads as structure, so an ID with a space, `&`, `=` or a leading `{` reads back whole
    /// and the rest of the line stays readable.
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
        .union(CharacterSet(charactersIn: "%?#&=/{"))

    private static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace
    }

    static func escaped(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            guard isSeparator(scalar) || escapedScalars.contains(scalar) else {
                result.append(scalar)
                continue
            }
            for byte in String(scalar).utf8 {
                result.append(contentsOf: String(format: "%%%02X", byte).unicodeScalars)
            }
        }
        return String(result)
    }

    // Not `removingPercentEncoding`: some Foundation builds drop a leading U+FEFF, which turns `%EF%BB%BFgeneral` into `general`.
    private static func decoded(_ text: String) -> String {
        let source = Array(text.utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(source.count)
        var index = 0
        while index < source.count {
            guard source[index] == UInt8(ascii: "%") else {
                bytes.append(source[index])
                index += 1
                continue
            }
            guard index + 2 < source.count, let high = hexValue(source[index + 1]), let low = hexValue(source[index + 2]) else {
                return text
            }
            bytes.append(high << 4 | low)
            index += 3
        }
        var result = String.UnicodeScalarView()
        var iterator = bytes.makeIterator()
        var codec = UTF8()
        while true {
            switch codec.decode(&iterator) {
            case .scalarValue(let scalar): result.append(scalar)
            case .emptyInput: return String(result)
            case .error: return text
            }
        }
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        default: nil
        }
    }

    private static func encodedPath(_ path: String) -> String {
        FirebaseScalars.split(path, separator: "/").map(escaped).joined(separator: "/")
    }

    private static func decodedPath(_ path: String) -> String {
        FirebaseScalars.split(path, separator: "/").map(decoded).joined(separator: "/")
    }
}

// Paths and request lines are written per Unicode scalar, so they are read back per scalar too. A Character
// joins a combining mark to the separator before it: `/` + U+0301 no longer splits, and " " + U+FE0F drops the mark.
package enum FirebaseScalars {
    package static func split(_ text: String, separator: Unicode.Scalar, maxSplits: Int = .max, omittingEmpty: Bool = true) -> [String] {
        text.unicodeScalars
            .split(separator: separator, maxSplits: maxSplits, omittingEmptySubsequences: omittingEmpty)
            .map(String.init)
    }

    package static func removingPrefix(_ prefix: String, from text: String) -> String? {
        guard text.unicodeScalars.starts(with: prefix.unicodeScalars) else { return nil }
        return String(text.unicodeScalars.dropFirst(prefix.unicodeScalars.count))
    }
}
