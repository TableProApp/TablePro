import Foundation

/// What the driver runs: a grid page as a tagged spec, or a request line such as
/// `GET events/user#42`, `SCAN events/user#?limit=20`, `READ events {"rowsLimit": "10"}`,
/// `INSERT events/user#42 {"profile:name": "Ann"}`, `PUT events/user#42 {"profile:name": null}`,
/// `DELETE events/user#42` or `DELETE events/user#42 profile:name`.
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
        case insert = "INSERT"
        case put = "PUT"
        case delete = "DELETE"
    }

    public let verb: Verb
    public let table: String
    public let key: Data?
    public let column: String?
    public let limit: Int?
    public let body: String?

    public init(verb: Verb, table: String, key: Data? = nil, column: String? = nil, limit: Int? = nil, body: String? = nil) {
        self.verb = verb
        self.table = table
        self.key = key
        self.column = column
        self.limit = limit
        self.body = body
    }

    /// The table comes before the first slash and the key after it. A key holding a space, a quote,
    /// a slash or a `?` is written as a JSON string: `GET events/"a/b"`.
    public static func parse(_ text: String) throws -> BigtableRequest {
        var scanner = RequestScanner(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let verbWord = scanner.word(), let verb = Verb(rawValue: verbWord.uppercased()) else {
            throw BigtableError.configuration(usage)
        }
        let request: BigtableRequest
        switch verb {
        case .read:
            guard let table = scanner.word(stoppingAt: "{") else { throw missingTable }
            let body = scanner.rest()
            guard body.hasPrefix("{") else {
                throw BigtableError.configuration(String(localized: "READ needs a ReadRows JSON body, such as READ events {\"rowsLimit\": \"10\"}."))
            }
            request = BigtableRequest(verb: .read, table: table, body: body)
        case .scan:
            let target = try scanner.target(tableOnly: true)
            request = BigtableRequest(verb: .scan, table: target.table, key: target.key, limit: try scanner.limit())
        case .get, .delete, .insert, .put:
            let target = try scanner.target(tableOnly: false)
            guard let key = target.key else {
                throw BigtableError.configuration(String(format: String(localized: "%@ needs a row key."), verb.rawValue))
            }
            switch verb {
            case .insert, .put:
                let body = scanner.rest()
                guard body.hasPrefix("{") else {
                    throw BigtableError.configuration(verb == .insert
                        ? String(localized: "INSERT needs a JSON object of cells, such as INSERT events/user#42 {\"profile:name\": \"Ann\"}.")
                        : String(localized: "PUT needs a JSON object of cells, such as PUT events/user#42 {\"profile:name\": \"Ann\"}."))
                }
                request = BigtableRequest(verb: verb, table: target.table, key: key, body: body)
            case .delete:
                request = BigtableRequest(verb: .delete, table: target.table, key: key, column: try scanner.column())
            default:
                request = BigtableRequest(verb: verb, table: target.table, key: key)
            }
        }
        guard scanner.isAtEnd else { throw BigtableError.configuration(usage) }
        return request
    }

    /// The request line as the history shows it and as `parse` reads it back.
    public var text: String {
        var parts = [verb.rawValue]
        if verb == .read {
            parts.append(table)
            parts.append(body ?? "{}")
            return parts.joined(separator: " ")
        }
        var target = table + "/" + (key.map { Self.token(BigtableBytes.display($0), reserved: "/?") } ?? "")
        if let limit { target += "?limit=\(limit)" }
        parts.append(target)
        if let column { parts.append(Self.token(column, reserved: "")) }
        if let body { parts.append(body) }
        return parts.joined(separator: " ")
    }

    /// The cells a write sets or deletes, all of which land in one atomic row mutation. A body maps
    /// `family:qualifier` to text, `b64:` text for bytes, or null to delete the cell.
    public func mutations() throws -> [BigtableMutation] {
        switch verb {
        case .get, .scan, .read:
            return []
        case .delete:
            return [try column.map { .deleteColumn(try BigtableColumn(name: $0)) } ?? .deleteRow]
        case .insert, .put:
            guard let data = body?.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw BigtableError.configuration(String(localized: "Write the cells as a JSON object, such as {\"profile:name\": \"Ann\"}."))
            }
            guard !object.isEmpty else {
                throw BigtableError.configuration(String(localized: "A write needs at least one cell. Bigtable does not store empty rows."))
            }
            return try object.keys.sorted().map { name in
                try Self.mutation(column: try BigtableColumn(name: name), name: name, value: object[name], allowsDelete: verb == .put)
            }
        }
    }

    private static func mutation(column: BigtableColumn, name: String, value: Any?, allowsDelete: Bool) throws -> BigtableMutation {
        switch value {
        case is NSNull:
            guard allowsDelete else {
                throw BigtableError.configuration(String(format: String(localized: "INSERT only sets cells. Leave %@ out, or delete it with PUT."), name))
            }
            return .deleteColumn(column)
        case let text as String:
            return .setCell(column, try BigtableBytes.parse(text))
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            return .setCell(column, Data((number.boolValue ? "true" : "false").utf8))
        case let number as NSNumber:
            return .setCell(column, Data(number.stringValue.utf8))
        default:
            throw BigtableError.configuration(String(
                format: String(localized: "The value of %@ must be text or null. Bigtable stores bytes, so a number is written as its digits."), name
            ))
        }
    }

    /// Text that would not read back as one bare word goes in JSON quotes.
    static func token(_ text: String, reserved: String) -> String {
        let plain = !text.isEmpty && !text.hasPrefix("\"") && text.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) && !reserved.unicodeScalars.contains(scalar)
        }
        if plain { return text }
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])) ?? Data()
        let array = String(bytes: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    static let usage = String(
        localized: "Enter a request such as GET events/user#42, SCAN events/user#?limit=20, PUT events/user#42 {\"profile:name\": \"Ann\"} or DELETE events/user#42."
    )

    static let missingTable = BigtableError.configuration(String(localized: "Name the table before the key, as in GET events/user#42."))
}

/// Reads a request line one token at a time.
private struct RequestScanner {
    private var text: Substring
    private var query: [String: String] = [:]

    init(_ text: String) {
        self.text = Substring(text)
    }

    var isAtEnd: Bool {
        text.allSatisfy(\.isWhitespace)
    }

    mutating func word(stoppingAt stop: Character? = nil) -> String? {
        skipSpace()
        let word = text.prefix { !$0.isWhitespace && $0 != stop }
        guard !word.isEmpty else { return nil }
        text = text.dropFirst(word.count)
        return String(word)
    }

    mutating func rest() -> String {
        let remaining = String(text).trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        return remaining
    }

    /// `table/key`, with an optional `?name=value` query after it. With `tableOnly`, a target with
    /// no slash is a table alone, as in `SCAN events`.
    mutating func target(tableOnly: Bool) throws -> (table: String, key: Data?) {
        skipSpace()
        let head = text.prefix { !$0.isWhitespace && $0 != "\"" && $0 != "?" }
        let table: String
        if let slash = head.firstIndex(of: "/") {
            table = String(text[..<slash])
            text = text[text.index(after: slash)...]
        } else if tableOnly, !head.isEmpty {
            table = String(head)
            text = text.dropFirst(head.count)
        } else {
            throw BigtableRequest.missingTable
        }
        guard !table.isEmpty else { throw BigtableRequest.missingTable }

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
        return (table, try keyText.map(BigtableBytes.parse))
    }

    func limit() throws -> Int? {
        guard query.keys.allSatisfy({ $0 == "limit" }) else {
            throw BigtableError.configuration(String(localized: "SCAN takes only ?limit=, as in SCAN events/user#?limit=20."))
        }
        guard let text = query["limit"] else { return nil }
        guard let limit = Int(text), limit > 0 else {
            throw BigtableError.configuration(String(format: String(localized: "\"%@\" is not a row limit. Use a whole number above 0."), text))
        }
        return limit
    }

    /// A column after the key: a JSON string, or the rest of the line, so a qualifier may hold a space.
    mutating func column() throws -> String? {
        skipSpace()
        if text.first == "\"" { return try quoted() }
        let column = rest()
        return column.isEmpty ? nil : column
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
            throw BigtableError.configuration(String(localized: "A quoted value is missing its closing quote."))
        }
        let literal = String(text[text.startIndex...index])
        text = text[text.index(after: index)...]
        guard let data = ("[" + literal + "]").data(using: .utf8),
              let value = (try? JSONSerialization.jsonObject(with: data) as? [String])?.first else {
            throw BigtableError.configuration(String(localized: "A quoted value is not a valid JSON string."))
        }
        return value
    }

    private mutating func skipSpace() {
        text = text.drop { $0.isWhitespace }
    }
}
