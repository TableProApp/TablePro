import Foundation

/// The text the driver runs. A page the grid asks for travels as a tagged spec; everything else is a
/// request line the history shows and the editor takes:
///
///     GET user#42                 SCAN user#?limit=20          READ {"rowsLimit": "10"}
///     PUT user#42 {"profile:name": "Ann"}    DELETE user#42    DELETE user#42 profile:name
///
/// A key with spaces is written as a JSON string, and binary bytes as `b64:<base64>`.
public enum BigtableStatement: Sendable, Equatable {
    case browse(BigtableBrowseSpec)
    case request(BigtableRequest)

    public static let browseTag = "BIGTABLE_BROWSE:"

    public static func encode(_ spec: BigtableBrowseSpec) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return browseTag + ((try? encoder.encode(spec)) ?? Data()).base64EncodedString()
    }

    public static func parse(_ text: String) throws -> BigtableStatement {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(browseTag) {
            guard let data = Data(base64Encoded: String(trimmed.dropFirst(browseTag.count))),
                  let spec = try? JSONDecoder().decode(BigtableBrowseSpec.self, from: data) else {
                throw BigtableError.malformedResponse(String(localized: "The browse request is damaged. Reopen the table."))
            }
            return .browse(spec)
        }
        return .request(try BigtableRequest.parse(trimmed))
    }
}

public struct BigtableRequest: Sendable, Equatable {
    public enum Verb: String, Sendable, CaseIterable {
        case get = "GET"
        case scan = "SCAN"
        case read = "READ"
        case put = "PUT"
        case delete = "DELETE"
    }

    public let verb: Verb
    /// The table the request names with `table/`, or nil for the table open in the editor's tab.
    public let table: String?
    public let key: Data?
    public let column: String?
    public let limit: Int?
    public let body: String?

    public init(verb: Verb, table: String? = nil, key: Data? = nil, column: String? = nil, limit: Int? = nil, body: String? = nil) {
        self.verb = verb
        self.table = table
        self.key = key
        self.column = column
        self.limit = limit
        self.body = body
    }

    /// `GET events/user#42` names the table before the first slash; a key holding a slash is
    /// written as a JSON string, `GET events/"a/b"`.
    public static func parse(_ text: String) throws -> BigtableRequest {
        var scanner = RequestScanner(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let verbWord = scanner.word(), let verb = Verb(rawValue: verbWord.uppercased()) else {
            throw BigtableError.configuration(usage)
        }
        switch verb {
        case .read:
            let rest = scanner.rest()
            var table: String?
            var body = rest
            if let brace = rest.firstIndex(of: "{"), brace != rest.startIndex {
                table = rest[..<brace].trimmingCharacters(in: .whitespaces).nonEmpty
                body = String(rest[brace...])
            }
            guard body.hasPrefix("{") else {
                throw BigtableError.configuration(String(localized: "READ needs a ReadRows JSON body, such as READ events {\"rowsLimit\": \"10\"}."))
            }
            return BigtableRequest(verb: .read, table: table, body: body)
        case .scan:
            let target = try scanner.target()
            let limit = scanner.query["limit"].flatMap(Int.init)
            return BigtableRequest(verb: .scan, table: target.table, key: target.key, limit: limit)
        case .get, .delete, .put:
            let target = try scanner.target()
            guard let key = target.key else {
                throw BigtableError.configuration(String(format: String(localized: "%@ needs a row key."), verb.rawValue))
            }
            if verb == .put {
                let body = scanner.rest()
                guard body.hasPrefix("{") else {
                    throw BigtableError.configuration(String(localized: "PUT needs a JSON object of cells, such as PUT events/user#42 {\"profile:name\": \"Ann\"}."))
                }
                return BigtableRequest(verb: .put, table: target.table, key: key, body: body)
            }
            let column = verb == .delete ? scanner.word() : nil
            return BigtableRequest(verb: verb, table: target.table, key: key, column: column)
        }
    }

    /// The request line as the history shows it and as `parse` reads it back.
    public func text(defaultTable: String?) -> String {
        var parts = [verb.rawValue]
        if verb == .read {
            parts.append(contentsOf: [table, body].compactMap { $0 })
            return parts.joined(separator: " ")
        }
        let keyText = key.map(Self.keyToken) ?? ""
        let tableName = table ?? defaultTable
        parts.append(tableName.map { $0 + "/" + keyText } ?? keyText)
        if let column { parts.append(column) }
        if let body { parts.append(body) }
        return parts.joined(separator: " ")
    }

    /// A key that would not read back as one bare word goes in JSON quotes.
    static func keyToken(_ key: Data) -> String {
        let display = BigtableBytes.display(key)
        let plain = !display.isEmpty && display.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) && scalar != "\"" && scalar != "/" && scalar != "?"
        }
        if plain { return display }
        let data = (try? JSONSerialization.data(withJSONObject: [display], options: [])) ?? Data()
        let array = String(bytes: data, encoding: .utf8) ?? ""
        return String(array.dropFirst().dropLast())
    }

    static let usage = String(
        localized: "Enter a request such as GET events/user#42, SCAN events/user#?limit=20, PUT events/user#42 {\"profile:name\": \"Ann\"} or DELETE events/user#42."
    )
}

/// Reads a request line one token at a time: words, a `table/key` target where the key may be a
/// JSON string, a `?name=value` query on the target, and whatever is left as the body.
private struct RequestScanner {
    private var text: Substring
    var query: [String: String] = [:]

    init(_ text: String) {
        self.text = Substring(text)
    }

    mutating func word() -> String? {
        skipSpace()
        let word = text.prefix { !$0.isWhitespace }
        guard !word.isEmpty else { return nil }
        text = text.dropFirst(word.count)
        return String(word)
    }

    mutating func rest() -> String {
        skipSpace()
        let remaining = String(text).trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        return remaining
    }

    mutating func target() throws -> (table: String?, key: Data?) {
        skipSpace()
        var table: String?
        if let slash = text.firstIndex(of: "/"), !text[..<slash].contains(where: { $0.isWhitespace || $0 == "\"" }) {
            table = String(text[..<slash]).nonEmpty
            text = text[text.index(after: slash)...]
        }
        var keyText: String?
        if text.first == "\"" {
            keyText = try quoted()
        } else {
            let raw = text.prefix { !$0.isWhitespace && $0 != "?" }
            text = text.dropFirst(raw.count)
            keyText = raw.isEmpty ? nil : String(raw)
        }
        if text.first == "?" {
            let raw = text.dropFirst().prefix { !$0.isWhitespace }
            text = text.dropFirst(raw.count + 1)
            for pair in raw.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if let name = parts.first { query[name] = parts.count > 1 ? parts[1] : "" }
            }
        }
        guard let keyText else { return (table, nil) }
        return (table, try BigtableBytes.parse(keyText))
    }

    private mutating func quoted() throws -> String {
        var index = text.index(after: text.startIndex)
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" && !escaped { break }
            escaped = character == "\\" && !escaped
            index = text.index(after: index)
        }
        guard index < text.endIndex else {
            throw BigtableError.configuration(String(localized: "A quoted row key is missing its closing quote."))
        }
        let literal = String(text[text.startIndex...index])
        text = text[text.index(after: index)...]
        guard let data = ("[" + literal + "]").data(using: .utf8),
              let value = (try? JSONSerialization.jsonObject(with: data) as? [String])?.first else {
            throw BigtableError.configuration(String(localized: "A quoted row key is not a valid JSON string."))
        }
        return value
    }

    private mutating func skipSpace() {
        text = text.drop { $0.isWhitespace }
    }
}

public enum BigtableStatementClassifier {
    public enum Tier: Sendable, Equatable {
        case read
        case write
        case destructive
    }

    /// Text that is neither a browse nor a request line counts as a write, so the read-only gate
    /// refuses what it cannot read.
    public static func classify(_ text: String) -> Tier {
        guard let statement = try? BigtableStatement.parse(text) else { return .write }
        switch statement {
        case .browse:
            return .read
        case .request(let request):
            switch request.verb {
            case .get, .scan, .read: return .read
            case .put: return .write
            case .delete: return .destructive
            }
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
