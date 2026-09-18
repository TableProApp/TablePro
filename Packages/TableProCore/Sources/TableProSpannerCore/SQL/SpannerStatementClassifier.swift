import Foundation

public indirect enum SpannerStatementKind: Sendable, Equatable {
    case query
    case dml
    case ddl
    case begin
    case commit
    case rollback
    case unsupportedTransactionControl(String)
    case explain(statement: String, analyze: Bool)
}

public enum SpannerStatementClassifier {
    public static func classify(_ sql: String, dialect: SpannerDialect = .googleSQL) -> SpannerStatementKind {
        var cursor = SpannerSQLCursor(sql, nestsBlockComments: dialect == .postgreSQL)
        cursor.skipNoise(skippingHints: true)
        if cursor.peek == "(" { return .query }
        guard let keyword = cursor.readWord()?.uppercased() else { return .query }
        switch keyword {
        case "EXPLAIN":
            return explain(after: cursor)
        case "INSERT", "UPDATE", "DELETE":
            return .dml
        case "CREATE", "ALTER", "DROP", "RENAME", "GRANT", "REVOKE", "ANALYZE":
            return .ddl
        case "BEGIN":
            return transactionControl(.begin, after: cursor, sql: sql)
        case "COMMIT":
            return transactionControl(.commit, after: cursor, sql: sql)
        case "ROLLBACK":
            return transactionControl(.rollback, after: cursor, sql: sql)
        case "START":
            return startTransaction(after: cursor, sql: sql)
        case "SET":
            return setStatement(after: cursor, sql: sql)
        case "SAVEPOINT", "RELEASE":
            return .unsupportedTransactionControl(sql)
        default:
            return .query
        }
    }

    public static func strippingLeadingNoise(_ sql: String, dialect: SpannerDialect = .googleSQL) -> Substring {
        var cursor = SpannerSQLCursor(sql, nestsBlockComments: dialect == .postgreSQL)
        cursor.skipNoise(skippingHints: true)
        return cursor.remainder
    }

    private static let optionalTransactionWords: Set<String> = ["TRANSACTION", "WORK"]
    private static let parenthesizedQueryWords: Set<String> = ["SELECT", "WITH", "GRAPH"]

    private static func transactionControl(
        _ kind: SpannerStatementKind,
        after start: SpannerSQLCursor,
        sql: String
    ) -> SpannerStatementKind {
        var cursor = start
        cursor.skipNoise(skippingHints: false)
        var lookahead = cursor
        if let word = lookahead.readWord()?.uppercased(), optionalTransactionWords.contains(word) {
            cursor = lookahead
        }
        return cursor.isAtStatementEnd ? kind : .unsupportedTransactionControl(sql)
    }

    private static func startTransaction(after start: SpannerSQLCursor, sql: String) -> SpannerStatementKind {
        var cursor = start
        cursor.skipNoise(skippingHints: false)
        guard cursor.readWord()?.uppercased() == "TRANSACTION" else { return .query }
        return cursor.isAtStatementEnd ? .begin : .unsupportedTransactionControl(sql)
    }

    private static func setStatement(after start: SpannerSQLCursor, sql: String) -> SpannerStatementKind {
        var cursor = start
        cursor.skipNoise(skippingHints: false)
        let word = cursor.readWord()?.uppercased()
        return word == "TRANSACTION" ? .unsupportedTransactionControl(sql) : .query
    }

    private static func explain(after start: SpannerSQLCursor) -> SpannerStatementKind {
        var cursor = start
        cursor.skipNoise(skippingHints: false)
        if cursor.peek == "(", let options = optionList(at: cursor) {
            return .explain(statement: options.rest.trimmedStatement, analyze: options.analyze)
        }
        var lookahead = cursor
        guard lookahead.readWord()?.uppercased() == "ANALYZE" else {
            return .explain(statement: cursor.remainder.trimmedStatement, analyze: false)
        }
        return .explain(statement: lookahead.remainder.trimmedStatement, analyze: true)
    }

    private static func optionList(at start: SpannerSQLCursor) -> (rest: Substring, analyze: Bool)? {
        var cursor = start
        cursor.advance()
        cursor.skipNoise(skippingHints: false)
        guard cursor.peek != "(" else { return nil }
        var lookahead = cursor
        if let first = lookahead.readWord()?.uppercased(), parenthesizedQueryWords.contains(first) {
            return nil
        }
        var analyze = false
        while let scalar = cursor.peek, scalar != ")" {
            if let word = cursor.readWord() {
                analyze = analyze || word.uppercased() == "ANALYZE"
                continue
            }
            cursor.advance()
        }
        guard cursor.peek == ")" else { return nil }
        cursor.advance()
        return (cursor.remainder, analyze)
    }
}

private extension Substring {
    var trimmedStatement: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
