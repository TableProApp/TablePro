import UIKit

enum SQLSyntaxHighlighter {
    private static let maxHighlightLength = 10_000

    private static let defaultFont = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)

    private static let keywordRegex: Regex<Substring> = {
        let keywords = [
            "SELECT", "FROM", "WHERE", "INSERT", "UPDATE", "DELETE", "CREATE", "DROP", "ALTER",
            "TABLE", "INDEX", "VIEW", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "CROSS", "FULL",
            "ON", "AS", "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET", "UNION", "ALL",
            "SET", "INTO", "VALUES", "AND", "OR", "NOT", "NULL", "IS", "IN", "LIKE", "BETWEEN",
            "EXISTS", "DISTINCT", "ASC", "DESC", "BEGIN", "COMMIT", "ROLLBACK", "TRANSACTION",
            "CASE", "WHEN", "THEN", "ELSE", "END", "TRUE", "FALSE", "IF", "ELSE",
            "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "CONSTRAINT", "DEFAULT", "CHECK",
            "UNIQUE", "ADD", "COLUMN", "RENAME", "TO", "DATABASE", "SCHEMA", "USE",
            "GRANT", "REVOKE", "WITH", "RECURSIVE", "FETCH", "NEXT", "ROWS", "ONLY"
        ]
        let pattern = #"\b(?:"# + keywords.joined(separator: "|") + #")\b"#
        // swiftlint:disable:next force_try
        return try! Regex(pattern, as: Substring.self).ignoresCase()
    }()

    private static let functionRegex: Regex<Substring> = {
        let functions = [
            "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "IFNULL", "NULLIF",
            "UPPER", "LOWER", "TRIM", "LTRIM", "RTRIM", "LENGTH", "SUBSTRING", "SUBSTR",
            "CONCAT", "REPLACE", "REVERSE", "NOW", "CURRENT_TIMESTAMP", "CURRENT_DATE",
            "CAST", "CONVERT", "ROUND", "CEIL", "FLOOR", "ABS", "MOD",
            "DATE", "TIME", "YEAR", "MONTH", "DAY", "HOUR", "MINUTE", "SECOND",
            "GROUP_CONCAT", "STRING_AGG", "ARRAY_AGG", "JSON_EXTRACT", "JSON_VALUE"
        ]
        let pattern = #"\b(?:"# + functions.joined(separator: "|") + #")\s*(?=\()"#
        // swiftlint:disable:next force_try
        return try! Regex(pattern, as: Substring.self).ignoresCase()
    }()

    private static let numberRegex = #/\b\d+\.?\d*\b/#
    private static let lineCommentRegex = #/--[^\n]*/#
    private static let blockCommentRegex = #/\/\*[\s\S]*?\*\//#
    private static let stringRegex = #/'(?:[^']|'')*'/#

    static func highlight(_ textStorage: NSTextStorage, in editedRange: NSRange) {
        let fullLength = textStorage.length
        guard fullLength > 0, editedRange.location < fullLength else { return }

        let cappedLength = min(fullLength, maxHighlightLength)
        let nsString = textStorage.string as NSString

        let safeEditedRange = NSRange(
            location: editedRange.location,
            length: min(editedRange.length, fullLength - editedRange.location)
        )

        let highlightRange: NSRange
        if safeEditedRange.location == 0 && safeEditedRange.length >= cappedLength {
            highlightRange = NSRange(location: 0, length: cappedLength)
        } else {
            let lineStart = nsString.lineRange(for: NSRange(location: safeEditedRange.location, length: 0)).location
            let editEnd = min(NSMaxRange(safeEditedRange), cappedLength)
            let lineEnd = NSMaxRange(nsString.lineRange(for: NSRange(location: max(editEnd - 1, 0), length: 0)))
            highlightRange = NSRange(location: lineStart, length: min(lineEnd - lineStart, cappedLength - lineStart))
        }

        guard highlightRange.length > 0,
              let scanRange = Range(highlightRange, in: textStorage.string) else { return }

        textStorage.beginEditing()

        textStorage.setAttributes(
            [.foregroundColor: UIColor.label, .font: defaultFont],
            range: highlightRange
        )

        let fullText = textStorage.string
        let scanText = fullText[scanRange]
        var protected: [Range<String.Index>] = []

        apply(blockCommentRegex, color: .systemGray, scanText: scanText, in: fullText, on: textStorage, protected: &protected)
        apply(lineCommentRegex, color: .systemGray, scanText: scanText, in: fullText, on: textStorage, protected: &protected)
        apply(stringRegex, color: .systemRed, scanText: scanText, in: fullText, on: textStorage, protected: &protected)
        apply(keywordRegex, color: .systemBlue, scanText: scanText, in: fullText, on: textStorage, protected: &protected, recordsProtection: false)
        apply(functionRegex, color: .systemPurple, scanText: scanText, in: fullText, on: textStorage, protected: &protected, recordsProtection: false)
        apply(numberRegex, color: .systemOrange, scanText: scanText, in: fullText, on: textStorage, protected: &protected, recordsProtection: false)

        textStorage.endEditing()
    }

    private static func apply<Output>(
        _ regex: Regex<Output>,
        color: UIColor,
        scanText: Substring,
        in fullText: String,
        on storage: NSTextStorage,
        protected: inout [Range<String.Index>],
        recordsProtection: Bool = true
    ) {
        for match in scanText.matches(of: regex) {
            if protected.contains(where: { $0.overlaps(match.range) }) { continue }
            let nsRange = NSRange(match.range, in: fullText)
            storage.addAttribute(.foregroundColor, value: color, range: nsRange)
            if recordsProtection {
                protected.append(match.range)
            }
        }
    }
}
