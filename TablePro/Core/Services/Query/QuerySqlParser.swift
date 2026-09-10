import Foundation
import TableProPluginKit

enum QuerySqlParser {
    private static let mongoCollectionRegex = try? NSRegularExpression(
        pattern: #"^\s*db\.(\w+)\."#,
        options: []
    )

    private static let mongoBracketCollectionRegex = try? NSRegularExpression(
        pattern: #"^\s*db\["([^"]+)"\]"#,
        options: []
    )

    private static let mongoGetCollectionRegex = try? NSRegularExpression(
        pattern: #"^\s*db\.getCollection\(\s*"((?:[^"\\]|\\.)*)"\s*\)"#,
        options: []
    )

    /// The table a result grid may be edited through, or `nil` when the statement reads from
    /// anything other than exactly one table.
    ///
    /// The generated `UPDATE` and `DELETE` name the table without a qualifier and rely on the
    /// session's own schema to resolve it. So a statement that spells a schema is only writable
    /// when that schema is the one the session is already pointed at; `browseSchema` supplies it.
    /// Any other schema stays read-only, because an unqualified write would land on whatever the
    /// session resolves rather than on the table the query read.
    static func extractTableName(
        from sql: String,
        dialect: SqlDialect = .generic,
        browseSchema: String? = nil
    ) -> String? {
        if let source = SelectSourceTableParser.singleSourceTable(in: sql, dialect: dialect) {
            guard let schema = source.schema else { return source.name }
            guard let browseSchema, matchesSessionSchema(schema, browseSchema) else { return nil }
            return source.name
        }

        let nsRange = NSRange(sql.startIndex..., in: sql)

        if let regex = mongoGetCollectionRegex,
           let match = regex.firstMatch(in: sql, options: [], range: nsRange),
           let range = Range(match.range(at: 1), in: sql) {
            return MongoCollectionAccessor.unescape(String(sql[range]))
        }

        if let regex = mongoBracketCollectionRegex,
           let match = regex.firstMatch(in: sql, options: [], range: nsRange),
           let range = Range(match.range(at: 1), in: sql) {
            return String(sql[range])
        }

        if let regex = mongoCollectionRegex,
           let match = regex.firstMatch(in: sql, options: [], range: nsRange),
           let range = Range(match.range(at: 1), in: sql) {
            return String(sql[range])
        }

        return nil
    }

    /// Compares case-insensitively. An unquoted identifier folds case on every engine TablePro
    /// reaches here, and a quoted one that differs only by case would still resolve to the same
    /// schema through the session, so treating them as equal cannot widen the write target.
    private static func matchesSessionSchema(_ parsed: String, _ session: String) -> Bool {
        parsed.compare(session, options: .caseInsensitive) == .orderedSame
    }

    /// Splices an ORDER BY into `sql` ahead of any row-limiting clause the user wrote.
    ///
    /// Appending it to the end instead produced `... LIMIT 100 ORDER BY "total" ASC`, a syntax
    /// error on every engine, and stripping the old ORDER BY took the user's LIMIT with it, which
    /// silently replaced their limit with the app's row cap.
    static func applyingOrderBy(_ orderClause: String, to sql: String, lexicalDialect: SqlDialect) -> String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let buffer = trimmed as NSString
        let splitOffset = SQLLimitDetector.firstRowLimitClauseOffset(trimmed, lexicalDialect: lexicalDialect)
        let head = splitOffset.map { buffer.substring(to: $0) } ?? trimmed
        let tail = splitOffset.map { buffer.substring(from: $0) } ?? ""

        let strippedHead = stripTrailingOrderBy(from: head)
        guard !orderClause.isEmpty else {
            /// `OFFSET n ROWS FETCH NEXT m ROWS ONLY` is only legal with an ORDER BY, so clearing
            /// the sort has to take that tail with it. A `LIMIT` tail stands on its own and stays.
            let keepsTail = tail.uppercased().hasPrefix("LIMIT")
            return [strippedHead, keepsTail ? tail : ""].filter { !$0.isEmpty }.joined(separator: " ")
        }
        return [strippedHead, "ORDER BY \(orderClause)", tail]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func stripTrailingOrderBy(from sql: String) -> String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let nsString = trimmed as NSString
        let pattern = "\\s+ORDER\\s+BY\\s+(?![^(]*\\))[^)]*$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return trimmed
        }
        let range = NSRange(location: 0, length: nsString.length)
        return regex.stringByReplacingMatches(in: trimmed, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseSQLiteCheckConstraintValues(createSQL: String, columnName: String) -> [String]? {
        let escapedName = NSRegularExpression.escapedPattern(for: columnName)
        let pattern = "CHECK\\s*\\(\\s*\"?\(escapedName)\"?\\s+IN\\s*\\(([^)]+)\\)\\s*\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let nsString = createSQL as NSString
        guard let match = regex.firstMatch(
            in: createSQL,
            range: NSRange(location: 0, length: nsString.length)
        ), match.numberOfRanges > 1 else {
            return nil
        }
        let valuesString = nsString.substring(with: match.range(at: 1))
        return EnumValueParser.parseMySQLEnumOrSet(from: "ENUM(\(valuesString))")
    }
}
