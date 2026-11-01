import Foundation

// One reader for EXPLAIN, MySQL's DESCRIBE of a statement and a bare ANALYZE. It fails closed: an option it does not
// know, or one it cannot read because it is quoted, may run the statement, and a text with no statement it can find
// is unreadable.
public enum SQLExplainStatement {
    public enum Reading: Equatable, Sendable {
        case describesObject
        case explains(statementStart: Int, runsStatement: Bool)
        case unreadable
    }

    public static let keywords: Set<String> = ["EXPLAIN", "ANALYZE", "DESCRIBE", "DESC"]

    public static let statementStarts: Set<String> = [
        "SELECT", "WITH", "INSERT", "UPDATE", "DELETE", "MERGE", "REPLACE", "UPSERT", "CREATE", "ALTER", "DROP",
        "TRUNCATE", "TABLE", "VALUES", "CALL", "EXECUTE", "COPY", "DO",
    ]

    static let executingOptions: Set<String> = ["ANALYZE", "ANALYSE"]

    static let valuedOptions: Set<String> = ["FORMAT", "TYPE", "USING"]

    // PostgreSQL, CockroachDB, Trino, MySQL, SQLite, Oracle, Snowflake and ClickHouse options and settings that only
    // plan or describe.
    static let planningOptions: Set<String> = Set([
        "VERBOSE", "COSTS", "SETTINGS", "GENERIC_PLAN", "BUFFERS", "SERIALIZE", "WAL", "TIMING", "SUMMARY", "MEMORY",
        "OPT", "VEC", "DISTSQL", "TYPES", "DDL", "SHAPE", "GIST", "REDACT", "MEMO", "ENV", "CATALOG", "JSON",
        "EXTENDED", "PARTITIONS", "QUERY", "PLAN", "FOR", "AST", "SYNTAX", "PIPELINE", "ESTIMATE", "TREE", "FULL",
        "HEADER", "DESCRIPTION", "INDEXES", "PROJECTIONS", "ACTIONS", "SORTING", "KEEP_LOGICAL_STEPS",
        "DISTRIBUTED", "GRAPH", "COMPACT", "ONELINE", "RUN_PASSES", "DUMP_PASSES", "PASSES", "DUMP_TREE", "DUMP_AST",
        "RUN_QUERY_TREE_PASSES", "QUERY_TREE_PASSES",
    ]).union(valuedOptions)

    // A word here is not part of a name, so `EXPLAIN PRAGMA query_only(1)` is not read as a described object.
    static let notNameWords: Set<String> = statementStarts.subtracting(["TABLE"]).union(executingOptions).union([
        "PRAGMA", "SET", "USE", "EXEC", "ATTACH", "DETACH", "VACUUM", "LOAD", "IMPORT", "EXPORT", "INSTALL",
    ])

    static let signatureWords: Set<String> = ["FUNCTION", "PROCEDURE"]

    private static let equals = UInt16(UnicodeScalar("=").value)
    private static let period = UInt16(UnicodeScalar(".").value)
    private static let zero = UInt16(UnicodeScalar("0").value)
    private static let comma = UInt16(UnicodeScalar(",").value)

    public static func read(_ statement: String, grammar: SQLLexicalGrammar) -> (keyword: String, reading: Reading)? {
        let text = statement as NSString
        let tokens = TSQLTokens.read(text, grammar: grammar)
        guard let keyword = tokens.first?.word, keywords.contains(keyword) else { return nil }
        let end = tokens.firstIndex { $0.kind == .terminator } ?? tokens.count
        let rest = tokens[1..<end]
        if namesObject(rest, in: text) { return (keyword, .describesObject) }
        let reader = Reader(text: text, grammar: grammar, tokens: Array(tokens[..<end]))
        return (keyword, reader.reading(runs: executingOptions.contains(keyword)))
    }

    private static func namesObject(_ tokens: ArraySlice<TSQLTokens.Token>, in text: NSString) -> Bool {
        guard let first = tokens.first else { return false }
        let takesSignature = tokens.contains { $0.word.map(signatureWords.contains) == true }
        return tokens.allSatisfy { token in
            switch token.kind {
            case .word(let word):
                return !notNameWords.contains(word)
            case .name, .quoted:
                return true
            case .open, .close:
                return takesSignature
            case .comma:
                return takesSignature && token.depth > first.depth
            case .other:
                let unit = text.character(at: token.location)
                return unit == period || (unit >= 0x30 && unit <= 0x39)
            case .terminator:
                return true
            }
        }
    }

    private struct Reader {
        let text: NSString
        let grammar: SQLLexicalGrammar
        let tokens: [TSQLTokens.Token]
        let code: NSString

        init(text: NSString, grammar: SQLLexicalGrammar, tokens: [TSQLTokens.Token]) {
            self.text = text
            self.grammar = grammar
            self.tokens = tokens
            self.code = SQLCodeProjection.code(of: text as String, grammar: grammar) as NSString
        }

        func reading(runs startsRunning: Bool) -> Reading {
            var runs = startsRunning
            var index = 1
            while index < tokens.count {
                let token = tokens[index]
                switch token.kind {
                case .word(let word) where statementStarts.contains(word):
                    return .explains(statementStart: start(after: index - 1), runsStatement: runs)
                case .word(let word):
                    if !planningOptions.contains(word) { runs = true }
                    index += 1
                    if isEquals(index) {
                        index = afterValue(index + 1)
                    } else if valuedOptions.contains(word) {
                        index = afterValue(index)
                    }
                case .open where opensStatement(index):
                    return .explains(statementStart: start(after: index - 1), runsStatement: runs)
                case .open:
                    let close = closing(index)
                    if optionListMayRun(from: index, to: close) { runs = true }
                    index = close + 1
                case .comma:
                    index += 1
                case .other where isEquals(index):
                    index += 1
                case .name, .quoted:
                    runs = true
                    index += 1
                case .other, .close, .terminator:
                    return .unreadable
                }
            }
            return .unreadable
        }

        // Where the explained statement starts, its leading comments included: the first character after the last
        // option that is not blank.
        private func start(after index: Int) -> Int {
            var cursor = end(of: index)
            while cursor < text.length, StatementBlank.blankLength(in: text, at: cursor) > 0 {
                cursor += StatementBlank.blankLength(in: text, at: cursor)
            }
            return cursor
        }

        private func end(of index: Int) -> Int {
            let token = tokens[index]
            if token.kind == .quoted, let span = SQLNonCodeSpan.span(at: token.location, in: text, grammar: grammar) {
                return span.end
            }
            let limit = index + 1 < tokens.count ? tokens[index + 1].location : text.length
            var cursor = token.location + 1
            while cursor < limit, StatementBlank.blankLength(in: code, at: cursor) == 0 {
                cursor += 1
            }
            return cursor
        }

        private func isEquals(_ index: Int) -> Bool {
            guard index < tokens.count, tokens[index].kind == .other else { return false }
            return text.character(at: tokens[index].location) == equals
        }

        private func afterValue(_ index: Int) -> Int {
            guard index < tokens.count else { return index }
            switch tokens[index].kind {
            case .word(let word):
                return statementStarts.contains(word) ? index : index + 1
            case .name, .quoted, .other:
                return index + 1
            default:
                return index
            }
        }

        private func opensStatement(_ index: Int) -> Bool {
            var cursor = index
            while cursor < tokens.count, tokens[cursor].kind == .open {
                cursor += 1
            }
            return cursor < tokens.count && tokens[cursor].word.map(statementStarts.contains) == true
        }

        private func closing(_ index: Int) -> Int {
            let depth = tokens[index].depth
            var cursor = index + 1
            while cursor < tokens.count, !(tokens[cursor].kind == .close && tokens[cursor].depth == depth) {
                cursor += 1
            }
            return cursor
        }

        // Each option's name is the first token of its item. One that is quoted or unknown may run it, and so does
        // ANALYZE unless PostgreSQL's FALSE, OFF or 0 alone follows it.
        private func optionListMayRun(from open: Int, to close: Int) -> Bool {
            let depth = tokens[open].depth + 1
            var items: [[TSQLTokens.Token]] = [[]]
            for token in tokens[(open + 1)..<min(close, tokens.count)] {
                if token.kind == .comma, token.depth == depth {
                    items.append([])
                } else {
                    items[items.count - 1].append(token)
                }
            }
            return items.contains { item in
                guard let first = item.first else { return false }
                guard let word = first.word else { return true }
                if planningOptions.contains(word) { return false }
                return !(executingOptions.contains(word) && item.count == 2 && turnsOptionOff(item[1]))
            }
        }

        private func turnsOptionOff(_ token: TSQLTokens.Token) -> Bool {
            if let word = token.word { return word == "FALSE" || word == "OFF" }
            guard token.kind == .other, code.character(at: token.location) == zero else { return false }
            let next = token.location + 1
            return next == code.length || StatementBlank.blankLength(in: code, at: next) > 0
                || code.character(at: next) == SqlLexer.closeParen || code.character(at: next) == comma
        }
    }
}
