import Foundation

/// Where a browse starts reading. Kafka has no ORDER BY and no skip-N, so a scan is defined by
/// an anchor plus a direction, which is the vocabulary every Kafka UI converges on.
enum KafkaStartMode: Sendable, Equatable {
    /// The most recent messages. The default, because a debugger nearly always wants the tail.
    case newest
    /// The oldest messages the log still holds.
    case oldest
    /// A literal offset, applied to every partition in the scan.
    case offset(Int64)
    /// The first message at or after a wall-clock time, resolved by ListOffsets.
    case timestamp(Int64)
    /// Per-partition offsets resolved by an earlier call. This is what makes paging stable:
    /// page two reads the anchor page one resolved instead of re-deriving "newest" against a
    /// tail that has moved on.
    case resolved([Int32: Int64])
}

struct KafkaConsumeQuery: Sendable {
    var topic: String
    var start: KafkaStartMode = .newest
    var limit: Int = 100
    var skip: Int = 0
    var partitions: [Int32]?
}

struct KafkaProduceQuery: Sendable {
    var topic: String
    var partition: Int32?
    var key: String?
    var value: String?
    var headers: [KafkaRecordHeader]
}

enum KafkaStatement: Sendable {
    case consume(KafkaConsumeQuery)
    case produce(KafkaProduceQuery)
    case showTopics
    case showBrokers
    case showGroups
    case describeGroup(String)
    case describeTopic(String)
    case showCluster
}

/// A small command language for the query editor.
///
/// Kafka has no textual query language of its own, so this follows the shape Redis uses: the
/// driver generates the string in `buildBrowseQuery` and parses it back here, and the same
/// vocabulary is what a user types by hand. Keeping one grammar for both means the string the
/// grid runs is the string a user can copy, edit and re-run.
enum KafkaQL {
    /// Both LIMIT and SKIP are bounded by the same ceiling, which is the browse engine's
    /// over-fetch cap: past it the driver could not honour the request anyway.
    static let maximumLimit = 50_000

    static func parse(_ input: String) throws -> KafkaStatement {
        var tokens = try Tokenizer.tokenize(input)
        guard let head = tokens.next()?.uppercased() else {
            throw KafkaError.syntax(String(localized: "Empty statement."))
        }

        switch head {
        case "CONSUME", "SELECT":
            return .consume(try parseConsume(&tokens))
        case "PRODUCE":
            return .produce(try parseProduce(&tokens))
        case "SHOW":
            return try parseShow(&tokens)
        case "DESCRIBE", "DESC":
            return try parseDescribe(&tokens)
        default:
            throw KafkaError.syntax(String(
                format: String(localized: "%@ is not a Kafka command. Try CONSUME, PRODUCE, SHOW or DESCRIBE."),
                head
            ))
        }
    }

    // MARK: - CONSUME

    private static func parseConsume(_ tokens: inout Tokenizer) throws -> KafkaConsumeQuery {
        // `SELECT * FROM topic` is accepted so the habit transfers, but it is sugar: there are
        // no projections and no WHERE, and pretending otherwise would mislead.
        if tokens.peek() == "*" { _ = tokens.next() }
        if tokens.peek()?.uppercased() == "FROM" { _ = tokens.next() }

        guard let topic = tokens.next() else {
            throw KafkaError.syntax(String(localized: "CONSUME needs a topic name."))
        }
        var query = KafkaConsumeQuery(topic: unquote(topic))

        while let keyword = tokens.next()?.uppercased() {
            switch keyword {
            case "FROM":
                query.start = try parseStart(&tokens)
            case "LIMIT":
                query.limit = try intValue(&tokens, keyword: "LIMIT")
            case "SKIP", "OFFSET":
                query.skip = try intValue(&tokens, keyword: keyword)
            case "PARTITION", "PARTITIONS":
                query.partitions = try partitionList(&tokens)
            default:
                throw KafkaError.syntax(String(
                    format: String(localized: "Unexpected %@ in a CONSUME statement."),
                    keyword
                ))
            }
        }
        guard query.limit > 0, query.limit <= maximumLimit else {
            throw KafkaError.syntax(String(
                format: String(localized: "LIMIT must be between 1 and %d."),
                maximumLimit
            ))
        }
        // Unbounded SKIP is not a rude input, it is a crash: a negative one traps in
        // dropFirst and a huge one overflows the skip+limit addition downstream.
        guard query.skip >= 0, query.skip <= maximumLimit else {
            throw KafkaError.syntax(String(
                format: String(localized: "SKIP must be between 0 and %d."),
                maximumLimit
            ))
        }
        return query
    }

    private static func parseStart(_ tokens: inout Tokenizer) throws -> KafkaStartMode {
        guard let mode = tokens.next()?.uppercased() else {
            throw KafkaError.syntax(String(localized: "FROM needs NEWEST, OLDEST, OFFSET, TIME or ANCHOR."))
        }
        switch mode {
        case "NEWEST", "LATEST", "END":
            return .newest
        case "OLDEST", "EARLIEST", "BEGINNING", "START":
            return .oldest
        case "OFFSET":
            return .offset(Int64(try intValue(&tokens, keyword: "OFFSET")))
        case "TIME", "TIMESTAMP":
            return .timestamp(try timestampValue(&tokens))
        case "ANCHOR":
            return .resolved(try anchorMap(&tokens))
        default:
            throw KafkaError.syntax(String(
                format: String(localized: "%@ is not a start position. Use NEWEST, OLDEST, OFFSET, TIME or ANCHOR."),
                mode
            ))
        }
    }

    /// `ANCHOR(0:120,1:80)` pins one offset per partition. It is machine-written by the browse
    /// path rather than typed, and it is what makes page two continue page one exactly.
    private static func anchorMap(_ tokens: inout Tokenizer) throws -> [Int32: Int64] {
        guard let raw = tokens.next() else {
            throw KafkaError.syntax(String(localized: "ANCHOR needs a partition:offset list."))
        }
        let body = raw.hasPrefix("(") ? String(raw.dropFirst().dropLast()) : raw
        var anchors: [Int32: Int64] = [:]
        for pair in body.split(separator: ",") {
            let parts = pair.split(separator: ":")
            guard parts.count == 2,
                  let partition = Int32(parts[0].trimmingCharacters(in: .whitespaces)),
                  let offset = Int64(parts[1].trimmingCharacters(in: .whitespaces)) else {
                throw KafkaError.syntax(String(
                    format: String(localized: "%@ is not a partition:offset pair."),
                    String(pair)
                ))
            }
            anchors[partition] = offset
        }
        return anchors
    }

    private static func partitionList(_ tokens: inout Tokenizer) throws -> [Int32] {
        guard let raw = tokens.next() else {
            throw KafkaError.syntax(String(localized: "PARTITION needs at least one partition number."))
        }
        let body = raw.hasPrefix("(") ? String(raw.dropFirst().dropLast()) : raw
        let values = body.split(separator: ",").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        guard !values.isEmpty else {
            throw KafkaError.syntax(String(localized: "PARTITION needs at least one partition number."))
        }
        return values
    }

    // MARK: - PRODUCE

    private static func parseProduce(_ tokens: inout Tokenizer) throws -> KafkaProduceQuery {
        if tokens.peek()?.uppercased() == "INTO" { _ = tokens.next() }
        guard let topic = tokens.next() else {
            throw KafkaError.syntax(String(localized: "PRODUCE needs a topic name."))
        }
        var query = KafkaProduceQuery(topic: unquote(topic), headers: [])

        while let keyword = tokens.next()?.uppercased() {
            switch keyword {
            case "KEY":
                query.key = unquote(try requireValue(&tokens, keyword: "KEY"))
            case "VALUE", "PAYLOAD":
                query.value = unquote(try requireValue(&tokens, keyword: keyword))
            case "PARTITION":
                query.partition = Int32(try intValue(&tokens, keyword: "PARTITION"))
            case "HEADER":
                let name = unquote(try requireValue(&tokens, keyword: "HEADER"))
                let value = unquote(try requireValue(&tokens, keyword: "HEADER"))
                query.headers.append(KafkaRecordHeader(key: name, value: Data(value.utf8)))
            default:
                throw KafkaError.syntax(String(
                    format: String(localized: "Unexpected %@ in a PRODUCE statement."),
                    keyword
                ))
            }
        }
        guard query.value != nil || query.key != nil else {
            throw KafkaError.syntax(String(localized: "PRODUCE needs at least a VALUE or a KEY."))
        }
        return query
    }

    // MARK: - SHOW and DESCRIBE

    private static func parseShow(_ tokens: inout Tokenizer) throws -> KafkaStatement {
        guard let what = tokens.next()?.uppercased() else {
            throw KafkaError.syntax(String(localized: "SHOW needs TOPICS, BROKERS, GROUPS or CLUSTER."))
        }
        switch what {
        case "TOPICS": return .showTopics
        case "BROKERS": return .showBrokers
        case "GROUPS", "CONSUMERS": return .showGroups
        case "CLUSTER": return .showCluster
        default:
            throw KafkaError.syntax(String(
                format: String(localized: "SHOW %@ is not supported. Try TOPICS, BROKERS, GROUPS or CLUSTER."),
                what
            ))
        }
    }

    private static func parseDescribe(_ tokens: inout Tokenizer) throws -> KafkaStatement {
        guard let what = tokens.next()?.uppercased() else {
            throw KafkaError.syntax(String(localized: "DESCRIBE needs GROUP or TOPIC."))
        }
        guard let name = tokens.next() else {
            throw KafkaError.syntax(String(localized: "DESCRIBE needs a name."))
        }
        switch what {
        case "GROUP": return .describeGroup(unquote(name))
        case "TOPIC": return .describeTopic(unquote(name))
        default:
            throw KafkaError.syntax(String(
                format: String(localized: "DESCRIBE %@ is not supported. Try GROUP or TOPIC."),
                what
            ))
        }
    }

    // MARK: - Helpers

    private static func requireValue(_ tokens: inout Tokenizer, keyword: String) throws -> String {
        guard let value = tokens.next() else {
            throw KafkaError.syntax(String(format: String(localized: "%@ needs a value."), keyword))
        }
        return value
    }

    private static func intValue(_ tokens: inout Tokenizer, keyword: String) throws -> Int {
        let raw = try requireValue(&tokens, keyword: keyword)
        guard let value = Int(raw) else {
            throw KafkaError.syntax(String(
                format: String(localized: "%@ needs a whole number, not %@."),
                keyword,
                raw
            ))
        }
        return value
    }

    /// Accepts either milliseconds since the epoch or an ISO 8601 instant, because a user
    /// reaching for "since time" has a clock reading, not an epoch.
    private static func timestampValue(_ tokens: inout Tokenizer) throws -> Int64 {
        let raw = unquote(try requireValue(&tokens, keyword: "TIME"))
        if let milliseconds = Int64(raw) { return milliseconds }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return Int64(date.timeIntervalSince1970 * 1000) }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) { return Int64(date.timeIntervalSince1970 * 1000) }
        throw KafkaError.syntax(String(
            format: String(localized: "%@ is not a time. Use milliseconds since the epoch or an ISO 8601 instant."),
            raw
        ))
    }

    /// Strips the delimiters and undoes the escaping `quote` applies. The tokenizer keeps a
    /// backslash escape intact so the delimiters can be found, so this is where it comes back
    /// off: without it, `VALUE "say \\"hi\\""` puts the backslashes on the topic.
    static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        let first = value.first
        let last = value.last
        guard first == last, first == "\"" || first == "'" || first == "`" else { return value }
        let inner = String(value.dropFirst().dropLast())
        guard inner.contains("\\") else { return inner }
        var unescaped = ""
        var escaping = false
        for character in inner {
            if escaping {
                unescaped.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                unescaped.append(character)
            }
        }
        if escaping { unescaped.append("\\") }
        return unescaped
    }

    static func quote(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    /// Splits on whitespace while keeping quoted strings and parenthesised lists whole.
    struct Tokenizer {
        private var tokens: [String]
        private var index = 0

        static func tokenize(_ input: String) throws -> Tokenizer {
            var tokens: [String] = []
            var current = ""
            var quote: Character?
            var depth = 0
            var escaped = false

            for character in input {
                if escaped {
                    current.append(character)
                    escaped = false
                    continue
                }
                if character == "\\", quote != nil {
                    escaped = true
                    current.append(character)
                    continue
                }
                if let active = quote {
                    current.append(character)
                    if character == active { quote = nil }
                    continue
                }
                switch character {
                case "\"", "'", "`":
                    quote = character
                    current.append(character)
                case "(":
                    depth += 1
                    current.append(character)
                case ")":
                    depth = max(0, depth - 1)
                    current.append(character)
                case " ", "\t", "\n", "\r", ",":
                    if depth > 0 {
                        current.append(character)
                    } else if !current.isEmpty {
                        tokens.append(current)
                        current = ""
                    }
                case ";":
                    if !current.isEmpty {
                        tokens.append(current)
                        current = ""
                    }
                default:
                    current.append(character)
                }
            }
            guard quote == nil else {
                throw KafkaError.syntax(String(localized: "A quoted value was never closed."))
            }
            if !current.isEmpty { tokens.append(current) }
            return Tokenizer(tokens: tokens)
        }

        private init(tokens: [String]) {
            self.tokens = tokens
        }

        mutating func next() -> String? {
            guard index < tokens.count else { return nil }
            defer { index += 1 }
            return tokens[index]
        }

        func peek() -> String? {
            index < tokens.count ? tokens[index] : nil
        }
    }
}
