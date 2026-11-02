import Foundation

public struct KafkaQLSyntaxError: Error, Sendable, Equatable {
    public let message: String

    init(_ message: String) {
        self.message = message
    }
}

// The browse path writes these statements and parses them back, so the text the grid runs is text a user can edit and re-run.
public enum KafkaQL {
    // The browse engine's over-fetch cap: past it the driver could not honour LIMIT or SKIP anyway.
    static let maximumLimit = 50_000

    public static func parse(_ input: String) throws -> KafkaStatement {
        var tokens = try Tokenizer.tokenize(input)
        guard let head = tokens.next()?.uppercased() else {
            throw KafkaQLSyntaxError(String(localized: "Empty statement."))
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
        case "DROP":
            return try parseDrop(&tokens)
        default:
            throw KafkaQLSyntaxError(String(
                format: String(localized: "%@ is not a Kafka command. Try CONSUME, PRODUCE, SHOW, DESCRIBE or DROP."),
                head
            ))
        }
    }

    // MARK: - DROP

    // Not `DROP TABLE`: that is the text the app used to invent for engines with no SQL (#2884).
    private static func parseDrop(_ tokens: inout Tokenizer) throws -> KafkaStatement {
        guard let kind = tokens.next()?.uppercased(), kind == "TOPIC" else {
            throw KafkaQLSyntaxError(String(localized: "DROP needs TOPIC and a topic name."))
        }
        guard let topic = tokens.next() else {
            throw KafkaQLSyntaxError(String(localized: "DROP TOPIC needs a topic name."))
        }
        guard tokens.next() == nil else {
            throw KafkaQLSyntaxError(String(localized: "DROP TOPIC takes one topic name."))
        }
        return .dropTopic(unquote(topic))
    }

    // MARK: - CONSUME

    private static func parseConsume(_ tokens: inout Tokenizer) throws -> KafkaConsumeQuery {
        // `SELECT * FROM topic` is sugar: there are no projections and no WHERE.
        if tokens.peek() == "*" { _ = tokens.next() }
        if tokens.peek()?.uppercased() == "FROM" { _ = tokens.next() }

        guard let topic = tokens.next() else {
            throw KafkaQLSyntaxError(String(localized: "CONSUME needs a topic name."))
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
                throw KafkaQLSyntaxError(String(
                    format: String(localized: "Unexpected %@ in a CONSUME statement."),
                    keyword
                ))
            }
        }
        guard query.limit > 0, query.limit <= maximumLimit else {
            throw KafkaQLSyntaxError(String(
                format: String(localized: "LIMIT must be between 1 and %d."),
                maximumLimit
            ))
        }
        // A negative SKIP traps in dropFirst and a huge one overflows skip + limit downstream.
        guard query.skip >= 0, query.skip <= maximumLimit else {
            throw KafkaQLSyntaxError(String(
                format: String(localized: "SKIP must be between 0 and %d."),
                maximumLimit
            ))
        }
        return query
    }

    private static func parseStart(_ tokens: inout Tokenizer) throws -> KafkaStartMode {
        guard let mode = tokens.next()?.uppercased() else {
            throw KafkaQLSyntaxError(String(localized: "FROM needs NEWEST, OLDEST, OFFSET, TIME, ANCHOR or TAIL."))
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
        case "TAIL":
            return .tail(try anchorMap(&tokens))
        default:
            throw KafkaQLSyntaxError(String(
                format: String(localized: """
                %@ is not a start position. Use NEWEST, OLDEST, OFFSET, TIME, ANCHOR or TAIL.
                """),
                mode
            ))
        }
    }

    private static func anchorMap(_ tokens: inout Tokenizer) throws -> [Int32: Int64] {
        guard let raw = tokens.next() else {
            throw KafkaQLSyntaxError(String(localized: "ANCHOR needs a partition:offset list."))
        }
        let body = raw.hasPrefix("(") ? String(raw.dropFirst().dropLast()) : raw
        var anchors: [Int32: Int64] = [:]
        for pair in body.split(separator: ",") {
            let parts = pair.split(separator: ":")
            guard parts.count == 2,
                  let partition = Int32(parts[0].trimmingCharacters(in: .whitespaces)),
                  let offset = Int64(parts[1].trimmingCharacters(in: .whitespaces)) else {
                throw KafkaQLSyntaxError(String(
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
            throw KafkaQLSyntaxError(String(localized: "PARTITION needs at least one partition number."))
        }
        let body = raw.hasPrefix("(") ? String(raw.dropFirst().dropLast()) : raw
        var values: [Int32] = []
        for entry in body.split(separator: ",") {
            let text = entry.trimmingCharacters(in: .whitespaces)
            // Dropping what does not parse would read a silently narrower page and report it as a success.
            guard let value = Int32(text) else {
                throw KafkaQLSyntaxError(String(
                    format: String(localized: "%@ is not a partition number."),
                    text
                ))
            }
            values.append(value)
        }
        guard !values.isEmpty else {
            throw KafkaQLSyntaxError(String(localized: "PARTITION needs at least one partition number."))
        }
        return values
    }

    // MARK: - PRODUCE

    private static func parseProduce(_ tokens: inout Tokenizer) throws -> KafkaProduceQuery {
        if tokens.peek()?.uppercased() == "INTO" { _ = tokens.next() }
        guard let topic = tokens.next() else {
            throw KafkaQLSyntaxError(String(localized: "PRODUCE needs a topic name."))
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
                throw KafkaQLSyntaxError(String(
                    format: String(localized: "Unexpected %@ in a PRODUCE statement."),
                    keyword
                ))
            }
        }
        guard query.value != nil || query.key != nil else {
            throw KafkaQLSyntaxError(String(localized: "PRODUCE needs at least a VALUE or a KEY."))
        }
        return query
    }

    // MARK: - SHOW and DESCRIBE

    private static func parseShow(_ tokens: inout Tokenizer) throws -> KafkaStatement {
        guard let what = tokens.next()?.uppercased() else {
            throw KafkaQLSyntaxError(String(localized: "SHOW needs TOPICS, BROKERS, GROUPS or CLUSTER."))
        }
        switch what {
        case "TOPICS":
            try requireEnd(&tokens, statement: "SHOW TOPICS")
            return .showTopics
        case "BROKERS":
            try requireEnd(&tokens, statement: "SHOW BROKERS")
            return .showBrokers
        case "GROUPS", "CONSUMERS":
            try requireEnd(&tokens, statement: "SHOW GROUPS")
            return .showGroups
        case "CLUSTER":
            try requireEnd(&tokens, statement: "SHOW CLUSTER")
            return .showCluster
        default:
            throw KafkaQLSyntaxError(String(
                format: String(localized: "SHOW %@ is not supported. Try TOPICS, BROKERS, GROUPS or CLUSTER."),
                what
            ))
        }
    }

    private static func parseDescribe(_ tokens: inout Tokenizer) throws -> KafkaStatement {
        guard let what = tokens.next()?.uppercased() else {
            throw KafkaQLSyntaxError(String(localized: "DESCRIBE needs GROUP or TOPIC."))
        }
        guard let name = tokens.next() else {
            throw KafkaQLSyntaxError(String(localized: "DESCRIBE needs a name."))
        }
        switch what {
        case "GROUP":
            try requireEnd(&tokens, statement: "DESCRIBE GROUP")
            return .describeGroup(unquote(name))
        case "TOPIC":
            try requireEnd(&tokens, statement: "DESCRIBE TOPIC")
            return .describeTopic(unquote(name))
        default:
            throw KafkaQLSyntaxError(String(
                format: String(localized: "DESCRIBE %@ is not supported. Try GROUP or TOPIC."),
                what
            ))
        }
    }

    // MARK: - Helpers

    private static func requireEnd(_ tokens: inout Tokenizer, statement: String) throws {
        guard let extra = tokens.next() else { return }
        throw KafkaQLSyntaxError(String(
            format: String(localized: "%@ takes nothing after it, and %@ was given."),
            statement,
            extra
        ))
    }

    private static func requireValue(_ tokens: inout Tokenizer, keyword: String) throws -> String {
        guard let value = tokens.next() else {
            throw KafkaQLSyntaxError(String(format: String(localized: "%@ needs a value."), keyword))
        }
        return value
    }

    private static func intValue(_ tokens: inout Tokenizer, keyword: String) throws -> Int {
        let raw = try requireValue(&tokens, keyword: keyword)
        guard let value = Int(raw) else {
            throw KafkaQLSyntaxError(String(
                format: String(localized: "%@ needs a whole number, not %@."),
                keyword,
                raw
            ))
        }
        return value
    }

    private static func timestampValue(_ tokens: inout Tokenizer) throws -> Int64 {
        let raw = unquote(try requireValue(&tokens, keyword: "TIME"))
        if let milliseconds = Int64(raw) { return milliseconds }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return Int64(date.timeIntervalSince1970 * 1_000) }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) { return Int64(date.timeIntervalSince1970 * 1_000) }
        throw KafkaQLSyntaxError(String(
            format: String(localized: "%@ is not a time. Use milliseconds since the epoch or an ISO 8601 instant."),
            raw
        ))
    }

    // By scalar, as the tokenizer reads: `Character` equality would take U+1FEF for a backtick.
    static func unquote(_ value: String) -> String {
        let scalars = value.unicodeScalars
        guard scalars.count >= 2, let first = scalars.first, let last = scalars.last,
              first == last, first == "\"" || first == "'" || first == "`" else { return value }
        let inner = scalars.dropFirst().dropLast()
        var unescaped = String.UnicodeScalarView()
        var escaping = false
        for scalar in inner {
            if escaping {
                unescaped.append(scalar)
                escaping = false
            } else if scalar == "\\" {
                escaping = true
            } else {
                unescaped.append(scalar)
            }
        }
        if escaping { unescaped.append("\\") }
        return String(unescaped)
    }

    // The backslash goes first: the tokenizer reads a backslash inside quotes as an escape and `unquote` strips it.
    public static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\", options: .literal)
            .replacingOccurrences(of: "\"", with: "\\\"", options: .literal)
        return "\"\(escaped)\""
    }

    // Reads Unicode scalars, as the app's statement gate does: `Character` equality is canonical equivalence, under
    // which U+037E is a `;` and U+1FEF a backtick. A `,` outside parentheses is a token of its own, never a blank.
    struct Tokenizer {
        private var tokens: [String]
        private var index = 0

        static func tokenize(_ input: String) throws -> Tokenizer {
            var tokens: [String] = []
            var current = String.UnicodeScalarView()
            var quote: Unicode.Scalar?
            var depth = 0
            var escaped = false

            func endWord() {
                guard !current.isEmpty else { return }
                tokens.append(String(current))
                current = String.UnicodeScalarView()
            }

            for scalar in input.unicodeScalars {
                if escaped {
                    current.append(scalar)
                    escaped = false
                    continue
                }
                if scalar == "\\", quote != nil {
                    escaped = true
                    current.append(scalar)
                    continue
                }
                if let active = quote {
                    current.append(scalar)
                    if scalar == active { quote = nil }
                    continue
                }
                switch scalar {
                case "\"", "'", "`":
                    quote = scalar
                    current.append(scalar)
                case "(":
                    depth += 1
                    current.append(scalar)
                case ")":
                    depth = max(0, depth - 1)
                    current.append(scalar)
                case " ", "\t", "\n", "\r":
                    if depth > 0 {
                        current.append(scalar)
                    } else {
                        endWord()
                    }
                case ",":
                    if depth > 0 {
                        current.append(scalar)
                    } else {
                        endWord()
                        tokens.append(",")
                    }
                case ";":
                    endWord()
                default:
                    current.append(scalar)
                }
            }
            guard quote == nil else {
                throw KafkaQLSyntaxError(String(localized: "A quoted value was never closed."))
            }
            endWord()
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
