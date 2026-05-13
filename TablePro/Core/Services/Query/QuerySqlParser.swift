import Foundation

enum QuerySqlParser {
    private static let tableNameRegex = try? NSRegularExpression(
        pattern: #"(?i)^\s*SELECT\s+.+?\s+FROM\s+(?:\[([^\]]+)\]|[`"]([^`"]+)[`"]|([\w$]+))\s*(?:WHERE|ORDER|LIMIT|GROUP|HAVING|OFFSET|FETCH|$|;)"#,
        options: []
    )

    private static let mongoCollectionRegex = try? NSRegularExpression(
        pattern: #"^\s*db\.(\w+)\."#,
        options: []
    )

    private static let mongoBracketCollectionRegex = try? NSRegularExpression(
        pattern: #"^\s*db\["([^"]+)"\]"#,
        options: []
    )

    static func extractTableName(from sql: String) -> String? {
        let nsRange = NSRange(sql.startIndex..., in: sql)

        if let regex = tableNameRegex,
           let match = regex.firstMatch(in: sql, options: [], range: nsRange) {
            for group in 1...3 {
                let r = match.range(at: group)
                if r.location != NSNotFound, let range = Range(r, in: sql) {
                    return String(sql[range])
                }
            }
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
        return ColumnType.parseEnumValues(from: "ENUM(\(valuesString))")
    }
}
