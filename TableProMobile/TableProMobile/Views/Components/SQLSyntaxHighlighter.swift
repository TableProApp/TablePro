import UIKit

enum SQLSyntaxHighlighter {
    private static let maxHighlightLength = 10_000

    private static let defaultFont = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)

    private static let keywordPattern: NSRegularExpression = {
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
        let pattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    private static let functionPattern: NSRegularExpression = {
        let functions = [
            "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "IFNULL", "NULLIF",
            "UPPER", "LOWER", "TRIM", "LTRIM", "RTRIM", "LENGTH", "SUBSTRING", "SUBSTR",
            "CONCAT", "REPLACE", "REVERSE", "NOW", "CURRENT_TIMESTAMP", "CURRENT_DATE",
            "CAST", "CONVERT", "ROUND", "CEIL", "FLOOR", "ABS", "MOD",
            "DATE", "TIME", "YEAR", "MONTH", "DAY", "HOUR", "MINUTE", "SECOND",
            "GROUP_CONCAT", "STRING_AGG", "ARRAY_AGG", "JSON_EXTRACT", "JSON_VALUE"
        ]
        let pattern = "\\b(" + functions.joined(separator: "|") + ")\\s*(?=\\()"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    private static let numberPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "\\b\\d+\\.?\\d*\\b", options: [])
    }()

    private static let singleLineCommentPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "--[^\\n]*", options: [])
    }()

    private static let blockCommentPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "/\\*[\\s\\S]*?\\*/", options: [])
    }()

    private static let stringPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "'(?:[^']|'')*'", options: [])
    }()

    static func highlight(_ textStorage: NSTextStorage, in editedRange: NSRange) {
        let fullLength = textStorage.length
        guard fullLength > 0 else { return }
        guard editedRange.location < fullLength else { return }

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

        guard highlightRange.length > 0 else { return }

        let text = nsString.substring(with: highlightRange) as NSString

        textStorage.beginEditing()

        let defaultAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.label,
            .font: defaultFont
        ]
        textStorage.setAttributes(defaultAttrs, range: highlightRange)

        var protectedRanges: [NSRange] = []

        blockCommentPattern.enumerateMatches(in: text as String, range: NSRange(location: 0, length: text.length)) { match, _, _ in
            guard let matchRange = match?.range else { return }
            let absolute = NSRange(location: highlightRange.location + matchRange.location, length: matchRange.length)
            textStorage.addAttribute(.foregroundColor, value: UIColor.systemGray, range: absolute)
            protectedRanges.append(matchRange)
        }

        singleLineCommentPattern.enumerateMatches(in: text as String, range: NSRange(location: 0, length: text.length)) { match, _, _ in
            guard let matchRange = match?.range else { return }
            if protectedRanges.contains(where: { NSIntersectionRange($0, matchRange).length > 0 }) { return }
            let absolute = NSRange(location: highlightRange.location + matchRange.location, length: matchRange.length)
            textStorage.addAttribute(.foregroundColor, value: UIColor.systemGray, range: absolute)
            protectedRanges.append(matchRange)
        }

        stringPattern.enumerateMatches(in: text as String, range: NSRange(location: 0, length: text.length)) { match, _, _ in
            guard let matchRange = match?.range else { return }
            if protectedRanges.contains(where: { NSIntersectionRange($0, matchRange).length > 0 }) { return }
            let absolute = NSRange(location: highlightRange.location + matchRange.location, length: matchRange.length)
            textStorage.addAttribute(.foregroundColor, value: UIColor.systemRed, range: absolute)
            protectedRanges.append(matchRange)
        }

        func isProtected(_ range: NSRange) -> Bool {
            protectedRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }

        keywordPattern.enumerateMatches(in: text as String, range: NSRange(location: 0, length: text.length)) { match, _, _ in
            guard let matchRange = match?.range, !isProtected(matchRange) else { return }
            let absolute = NSRange(location: highlightRange.location + matchRange.location, length: matchRange.length)
            textStorage.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: absolute)
        }

        functionPattern.enumerateMatches(in: text as String, range: NSRange(location: 0, length: text.length)) { match, _, _ in
            guard let matchRange = match?.range, !isProtected(matchRange) else { return }
            let absolute = NSRange(location: highlightRange.location + matchRange.location, length: matchRange.length)
            textStorage.addAttribute(.foregroundColor, value: UIColor.systemPurple, range: absolute)
        }

        numberPattern.enumerateMatches(in: text as String, range: NSRange(location: 0, length: text.length)) { match, _, _ in
            guard let matchRange = match?.range, !isProtected(matchRange) else { return }
            let absolute = NSRange(location: highlightRange.location + matchRange.location, length: matchRange.length)
            textStorage.addAttribute(.foregroundColor, value: UIColor.systemOrange, range: absolute)
        }

        textStorage.endEditing()
    }
}
