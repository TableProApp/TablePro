//
//  SQLContextAnalyzer.swift
//  TablePro
//
//  Analyzes SQL query text to determine cursor context for autocomplete
//

import Foundation

/// Type of SQL clause the cursor is in
enum SQLClauseType {
    case select         // In SELECT list
    case from           // After FROM
    case join           // After JOIN
    case on             // After ON (join condition)
    case where_         // After WHERE
    case and            // After AND/OR
    case groupBy        // After GROUP BY
    case orderBy        // After ORDER BY
    case having         // After HAVING
    case set            // After SET (UPDATE)
    case into           // After INTO (INSERT)
    case values         // After VALUES
    case insertColumns  // Column list in INSERT
    case functionArg    // Inside function parentheses
    case caseExpression // Inside CASE WHEN expression
    case inList         // Inside IN (...) list
    case limit          // After LIMIT/OFFSET
    case alterTable       // After ALTER TABLE tablename
    case alterTableColumn // After DROP/MODIFY/CHANGE/RENAME COLUMN
    case createTable      // Inside CREATE TABLE definition
    case columnDef        // Typing column data type
    case returning        // After RETURNING (PostgreSQL)
    case union            // After UNION/INTERSECT/EXCEPT
    case using            // After USING (JOIN ... USING)
    case window           // After OVER/PARTITION BY/window clause
    case dropObject       // After DROP TABLE/INDEX/VIEW
    case createIndex      // After CREATE INDEX
    case createView       // After CREATE VIEW
    case unknown          // Unknown or start of query
}

/// Represents a table reference with optional alias
struct TableReference: Equatable, Sendable {
    let tableName: String
    let alias: String?

    /// Returns the identifier that should be used to reference this table
    var identifier: String {
        alias ?? tableName
    }
}

/// Result of context analysis
struct SQLContext {
    let clauseType: SQLClauseType
    let prefix: String              // Current word being typed
    let prefixRange: Range<Int>     // Range of prefix in original text
    let dotPrefix: String?          // Table/alias before dot (e.g., "u" in "u.name")
    let tableReferences: [TableReference]  // All tables in scope
    let isInsideString: Bool        // Inside a string literal
    let isInsideComment: Bool       // Inside a comment

    // Enhanced context for smarter completions
    let cteNames: [String]          // Common Table Expression names in scope
    let nestingLevel: Int           // Subquery nesting level (0 = main query)
    let currentFunction: String?    // If inside function args, the function name
    let isAfterComma: Bool          // True if immediately after a comma

    init(
        clauseType: SQLClauseType,
        prefix: String,
        prefixRange: Range<Int>,
        dotPrefix: String?,
        tableReferences: [TableReference],
        isInsideString: Bool,
        isInsideComment: Bool,
        cteNames: [String] = [],
        nestingLevel: Int = 0,
        currentFunction: String? = nil,
        isAfterComma: Bool = false
    ) {
        self.clauseType = clauseType
        self.prefix = prefix
        self.prefixRange = prefixRange
        self.dotPrefix = dotPrefix
        self.tableReferences = tableReferences
        self.isInsideString = isInsideString
        self.isInsideComment = isInsideComment
        self.cteNames = cteNames
        self.nestingLevel = nestingLevel
        self.currentFunction = currentFunction
        self.isAfterComma = isAfterComma
    }
}

/// Analyzes SQL query to determine completion context
final class SQLContextAnalyzer {
    // MARK: - UTF-16 Character Constants

    private static let singleQuote = UInt16(UnicodeScalar("'").value)
    private static let doubleQuote = UInt16(UnicodeScalar("\"").value)
    private static let backslash = UInt16(UnicodeScalar("\\").value)
    private static let semicolon = UInt16(UnicodeScalar(";").value)
    private static let dash = UInt16(UnicodeScalar("-").value)
    private static let newline = UInt16(UnicodeScalar("\n").value)
    private static let openParen = UInt16(UnicodeScalar("(").value)
    private static let closeParen = UInt16(UnicodeScalar(")").value)
    private static let dot = UInt16(UnicodeScalar(".").value)
    private static let backtick = UInt16(UnicodeScalar("`").value)
    private static let underscore = UInt16(UnicodeScalar("_").value)
    private static let comma = UInt16(UnicodeScalar(",").value)
    private static let space = UInt16(UnicodeScalar(" ").value)
    private static let tab = UInt16(UnicodeScalar("\t").value)
    private static let cr = UInt16(UnicodeScalar("\r").value)
    private static let slash = UInt16(UnicodeScalar("/").value)
    private static let star = UInt16(UnicodeScalar("*").value)

    // MARK: - Cached Regex Patterns (Compiled Once at Class Load)

    /// Pre-compiled clause detection patterns for performance
    /// ORDER MATTERS: More specific patterns must come before general ones
    private static let clauseRegexes: [(regex: NSRegularExpression, clause: SQLClauseType)] = {
        let patterns: [(String, SQLClauseType)] = [
            // DDL patterns (most specific first)
            ("\\bADD\\s+(?:COLUMN\\s+)?[`\"']?\\w+[`\"']?\\s+\\w+.*?\\b(?:AFTER|BEFORE)(?:\\s+\\w*)?$",
             .alterTableColumn),
            ("\\b(?:AFTER|BEFORE)(?:\\s+\\w*)?$", .alterTableColumn),
            ("\\bFIRST\\s*$", .alterTable),
            ("\\bALTER\\s+TABLE\\s+[`\"']?\\w+[`\"']?\\s+ADD\\s+CONSTRAINT\\s+\\w*$", .alterTable),
            ("\\bALTER\\s+TABLE\\s+[`\"']?\\w+[`\"']?\\s+ADD\\s+\\w*$", .alterTable),
            (
                "\\b(?:ADD|MODIFY|CHANGE)\\s+(?:COLUMN\\s+)?[`\"']?\\w+[`\"']?\\s+\\w+(?:\\([^)]*\\))?" +
                "(?:\\s+(?:NOT\\s+)?NULL|\\s+DEFAULT(?:\\s+[^\\s]+)?|\\s+AUTO_INCREMENT" +
                "|\\s+UNSIGNED|\\s+COMMENT(?:\\s+'[^']*')?)*\\s*$",
                .columnDef
            ),
            ("\\b(?:ADD|MODIFY|CHANGE)\\s+COLUMN\\s+\\w+\\s*$", .columnDef),
            ("\\bALTER\\s+TABLE\\s+[`\"']?\\w+[`\"']?\\s+(?:DROP|MODIFY|CHANGE|RENAME)" +
             "\\s+(?:COLUMN\\s+)?[`\"']?\\w*[`\"']?\\s*$", .alterTableColumn),
            ("\\bALTER\\s+TABLE\\s+[`\"']?\\w+[`\"']?\\s+\\w*$", .alterTable),
            ("\\bCREATE\\s+TABLE\\s+[^(]*\\([^)]*$", .createTable),
            ("\\bCREATE\\s+(?:TEMPORARY\\s+)?TABLE\\s+[^;]*\\([^)]*\\)\\s*\\w*$", .createTable),
            ("\\bCREATE\\s+(?:TEMPORARY\\s+)?TABLE\\s+(?:IF\\s+NOT\\s+EXISTS\\s+)?\\w*$", .createTable),
            // DROP object patterns
            ("\\bDROP\\s+(?:TABLE|VIEW|INDEX)\\s+(?:IF\\s+EXISTS\\s+)?\\w*$", .dropObject),
            // CREATE INDEX pattern
            ("\\bCREATE\\s+(?:UNIQUE\\s+)?INDEX\\s+\\w+\\s+ON\\s+\\w+\\s*\\([^)]*$", .createIndex),
            ("\\bCREATE\\s+(?:UNIQUE\\s+)?INDEX\\s+\\w*$", .createIndex),
            // CREATE VIEW pattern
            ("\\bCREATE\\s+(?:OR\\s+REPLACE\\s+)?(?:MATERIALIZED\\s+)?VIEW\\s+\\w+\\s+AS\\s+[^;]*$",
             .createView),
            ("\\bCREATE\\s+(?:OR\\s+REPLACE\\s+)?(?:MATERIALIZED\\s+)?VIEW\\s+\\w*$", .createView),
            // RETURNING clause (PostgreSQL)
            ("\\bRETURNING\\s+[^;]*$", .returning),
            // UNION/INTERSECT/EXCEPT
            ("\\b(?:UNION|INTERSECT|EXCEPT)\\s+(?:ALL\\s+)?\\w*$", .union),
            // USING clause in JOIN
            ("\\bUSING\\s*\\([^)]*$", .using),
            // Window function OVER clause
            ("\\bOVER\\s*\\([^)]*$", .window),
            ("\\bPARTITION\\s+BY\\s+[^)]*$", .window),
            // Enhanced context patterns
            ("\\bIN\\s*\\([^)]*$", .inList),
            ("\\bCASE\\s+(?:WHEN\\s+[^;]*)?$", .caseExpression),
            ("\\b(LIMIT|OFFSET)\\s+\\d*$", .limit),
            // Standard clause patterns
            ("\\bVALUES\\s*(?:\\([^)]*\\)\\s*,?\\s*)+\\w*$", .values),
            ("\\bVALUES\\s*\\([^)]*$", .values),
            ("\\bINSERT\\s+INTO\\s+\\w+\\s*\\([^)]*$", .insertColumns),
            ("\\bINSERT\\s+INTO\\s+[`\"']?\\w+[`\"']?\\s*$", .into),
            ("\\bINTO\\s+\\w*$", .into),
            ("\\bSET\\s+[^;]*$", .set),
            ("\\bHAVING\\s+[^;]*$", .having),
            ("\\bORDER\\s+BY\\s+[^;]*$", .orderBy),
            ("\\bGROUP\\s+BY\\s+[^;]*$", .groupBy),
            ("\\b(AND|OR)\\s+\\w*$", .and),
            ("\\bWHERE\\s+[^;]*$", .where_),
            ("\\bON\\s+[^;]*$", .on),
            // JOIN patterns
            ("(?:LEFT|RIGHT|INNER|OUTER|FULL|CROSS)?\\s*(?:OUTER)?\\s*JOIN\\s+[`\"']?\\w+[`\"']?" +
             "(?:\\s+(?:AS\\s+)?\\w+)?\\s*$", .join),
            ("\\bJOIN\\s+[`\"']?\\w*[`\"']?\\s*$", .join),
            // FROM patterns
            ("\\bFROM\\s+[`\"']?\\w+[`\"']?(?:\\s+(?:AS\\s+)?\\w+)?\\s*$", .from),
            ("\\bFROM\\s+\\w*$", .from),
            ("\\bFROM\\s*$", .from),
            // SELECT is most general
            ("\\bSELECT\\s+[^;]*$", .select),
        ]
        return patterns.compactMap { pattern, clause in
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: .caseInsensitive
            ) else {
                assertionFailure("Invalid SQL clause regex pattern: \(pattern)")
                return nil
            }
            return (regex, clause)
        }
    }()

    /// Pre-compiled regex for removing strings and comments
    private static let singleQuoteStringRegex: NSRegularExpression = {
        if let regex = try? NSRegularExpression(pattern: "'[^']*'") {
            return regex
        }
        assertionFailure("Failed to compile singleQuoteStringRegex - invalid pattern")
        return try! NSRegularExpression(pattern: "(?!)")
    }()

    private static let doubleQuoteStringRegex: NSRegularExpression = {
        if let regex = try? NSRegularExpression(pattern: "\"[^\"]*\"") {
            return regex
        }
        assertionFailure("Failed to compile doubleQuoteStringRegex - invalid pattern")
        return try! NSRegularExpression(pattern: "(?!)")
    }()

    private static let blockCommentRegex: NSRegularExpression = {
        if let regex = try? NSRegularExpression(pattern: "/\\*[\\s\\S]*?\\*/") {
            return regex
        }
        assertionFailure("Failed to compile blockCommentRegex - invalid pattern")
        return try! NSRegularExpression(pattern: "(?!)")
    }()

    private static let lineCommentRegex: NSRegularExpression = {
        if let regex = try? NSRegularExpression(pattern: "--[^\n]*") {
            return regex
        }
        assertionFailure("Failed to compile lineCommentRegex - invalid pattern")
        return try! NSRegularExpression(pattern: "(?!)")
    }()

    /// Combined regex for removing strings and comments in a single pass (SVC-13)
    private static let stringsAndCommentsRegex: NSRegularExpression = {
        // Alternation: single-quoted strings | double-quoted strings | block comments | line comments
        let pattern = #"'[^']*'|"[^"]*"|/\*[\s\S]*?\*/|--[^\n]*"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            return regex
        }
        assertionFailure("Failed to compile stringsAndCommentsRegex - invalid pattern")
        return try! NSRegularExpression(pattern: "(?!)")
    }()

    private static let cteFirstRegex: NSRegularExpression = {
        if let regex = try? NSRegularExpression(
            pattern: "(?i)\\bWITH\\s+(?:RECURSIVE\\s+)?([\\w]+)\\s+AS\\s*\\("
        ) {
            return regex
        }
        assertionFailure("Failed to compile cteFirstRegex")
        return try! NSRegularExpression(pattern: "(?!)")
    }()

    private static let cteCommaRegex: NSRegularExpression = {
        if let regex = try? NSRegularExpression(
            pattern: "(?i),\\s*([\\w]+)\\s+AS\\s*\\("
        ) {
            return regex
        }
        assertionFailure("Failed to compile cteCommaRegex")
        return try! NSRegularExpression(pattern: "(?!)")
    }()

    private static let tableRefRegexes: [NSRegularExpression] = {
        let patterns = [
            "(?i)\\bFROM\\s+[`\"']?([\\w]+)[`\"']?" +
            "(?:\\s+(?:AS\\s+)?[`\"']?([\\w]+)[`\"']?)?",
            "(?i)(?:LEFT|RIGHT|INNER|OUTER|CROSS|FULL)?\\s*(?:OUTER)?\\s*JOIN\\s+" +
            "[`\"']?([\\w]+)[`\"']?(?:\\s+(?:AS\\s+)?[`\"']?([\\w]+)[`\"']?)?",
            "(?i)\\bUPDATE\\s+[`\"']?([\\w]+)[`\"']?" +
            "(?:\\s+(?:AS\\s+)?[`\"']?([\\w]+)[`\"']?)?",
            "(?i)\\bINSERT\\s+INTO\\s+[`\"']?([\\w]+)[`\"']?",
            "(?i)\\bCREATE\\s+(?:UNIQUE\\s+)?INDEX\\s+\\w+\\s+ON\\s+[`\"']?([\\w]+)[`\"']?"
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    // MARK: - UTF-16 Helpers

    /// Check if a UTF-16 code unit is a letter or digit (ASCII fast path + fallback)
    private static func isIdentifierChar(_ ch: UInt16) -> Bool {
        // ASCII letters
        if (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) { return true }
        // ASCII digits
        if ch >= 0x30 && ch <= 0x39 { return true }
        // underscore
        if ch == underscore { return true }
        return false
    }

    /// Check if a UTF-16 code unit is whitespace (space, tab, newline, CR)
    private static func isWhitespace(_ ch: UInt16) -> Bool {
        ch == space || ch == tab || ch == newline || ch == cr
    }

    // MARK: - Main Analysis

    /// Analyze the query at the given cursor position
    func analyze(query: String, cursorPosition: Int) -> SQLContext {
        let nsQuery = query as NSString
        let safePosition = min(cursorPosition, nsQuery.length)

        // Extract the current statement for multi-statement queries
        let located = SQLStatementScanner.locatedStatementAtCursor(
            in: nsQuery as String, cursorPosition: safePosition
        )
        let currentStatement = located.sql
        let statementOffset = located.offset
        let adjustedPosition = safePosition - statementOffset

        let nsStatement = currentStatement as NSString
        let clampedPosition = max(0, min(adjustedPosition, nsStatement.length))
        let textBeforeCursor = nsStatement.substring(to: clampedPosition)

        // Check if inside string or comment
        if isInsideString(textBeforeCursor) {
            return SQLContext(
                clauseType: .unknown,
                prefix: "",
                prefixRange: safePosition..<safePosition,
                dotPrefix: nil,
                tableReferences: [],
                isInsideString: true,
                isInsideComment: false
            )
        }

        if isInsideComment(textBeforeCursor) {
            return SQLContext(
                clauseType: .unknown,
                prefix: "",
                prefixRange: safePosition..<safePosition,
                dotPrefix: nil,
                tableReferences: [],
                isInsideString: false,
                isInsideComment: true
            )
        }

        // Extract prefix and dot prefix
        let (prefix, prefixStart, dotPrefix) = extractPrefix(from: textBeforeCursor)

        // Find all table references in the current statement
        var tableReferences = extractTableReferences(from: currentStatement)

        // Extract CTEs from the current statement
        let cteNames = extractCTENames(from: currentStatement)

        // Add CTE names as table references
        for cteName in cteNames {
            let cteRef = TableReference(tableName: cteName, alias: nil)
            if !tableReferences.contains(cteRef) {
                tableReferences.append(cteRef)
            }
        }

        // Extract ALTER TABLE table name and add to references
        if let alterTableName = extractAlterTableName(from: currentStatement) {
            let alterRef = TableReference(tableName: alterTableName, alias: nil)
            if !tableReferences.contains(alterRef) {
                tableReferences.append(alterRef)
            }
        }

        // Calculate nesting level (subquery depth)
        let nestingLevel = calculateNestingLevel(in: textBeforeCursor)

        // Detect function context
        let currentFunction = detectFunctionContext(in: textBeforeCursor)

        // Check if immediately after comma
        let isAfterComma = checkIfAfterComma(textBeforeCursor)

        // For subquery context, extract text from the innermost subquery
        // so clause detection works on the subquery's SQL, not the outer query
        let clauseText: String
        if nestingLevel > 0 {
            clauseText = extractInnermostSubqueryText(from: textBeforeCursor)
        } else {
            clauseText = textBeforeCursor
        }

        // Determine clause type
        let clauseType = determineClauseType(
            textBeforeCursor: clauseText,
            dotPrefix: dotPrefix,
            currentFunction: currentFunction
        )

        return SQLContext(
            clauseType: clauseType,
            prefix: prefix,
            prefixRange: (statementOffset + prefixStart)..<safePosition,
            dotPrefix: dotPrefix,
            tableReferences: tableReferences,
            isInsideString: false,
            isInsideComment: false,
            cteNames: cteNames,
            nestingLevel: nestingLevel,
            currentFunction: currentFunction,
            isAfterComma: isAfterComma
        )
    }

    // MARK: - CTE Support

    /// Extract CTE (Common Table Expression) names from the query
    private func extractCTENames(from query: String) -> [String] {
        var cteNames: [String] = []
        let nsRange = NSRange(location: 0, length: (query as NSString).length)

        // Find first CTE (uses pre-compiled static regex)
        if let match = Self.cteFirstRegex.firstMatch(in: query, range: nsRange) {
            let nameNSRange = match.range(at: 1)
            if nameNSRange.location != NSNotFound {
                cteNames.append((query as NSString).substring(with: nameNSRange))
            }
        }

        // Find additional CTEs (comma-separated, uses pre-compiled static regex)
        Self.cteCommaRegex.enumerateMatches(in: query, range: nsRange) { match, _, _ in
            if let match = match {
                let nameNSRange = match.range(at: 1)
                if nameNSRange.location != NSNotFound {
                    cteNames.append((query as NSString).substring(with: nameNSRange))
                }
            }
        }

        return cteNames
    }

    // MARK: - Subquery Support

    /// Calculate the nesting level (subquery depth) at cursor position.
    /// Uses NSString character-at-index for O(1) access per character.
    private func calculateNestingLevel(in textBeforeCursor: String) -> Int {
        let ns = textBeforeCursor as NSString
        let length = ns.length
        var level = 0
        var inString = false
        var prevChar: UInt16 = 0

        for i in 0..<length {
            let ch = ns.character(at: i)
            if ch == Self.singleQuote && prevChar != Self.backslash {
                inString.toggle()
            }

            if !inString {
                if ch == Self.openParen {
                    level += 1
                } else if ch == Self.closeParen {
                    level = max(0, level - 1)
                }
            }

            prevChar = ch
        }

        return level
    }

    /// SQL DML keywords that indicate the start of a subquery
    private static let subqueryStartKeywords: Set<String> = [
        "SELECT", "INSERT", "UPDATE", "DELETE"
    ]

    /// Pre-compiled regex to detect a SQL statement keyword after opening paren
    private static let subqueryDetectRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "^\\s*(?:SELECT|INSERT|UPDATE|DELETE)\\b",
            options: .caseInsensitive
        )
    }()

    /// Extract text from the innermost subquery's opening parenthesis.
    /// Only extracts if the text after the paren starts with a SQL statement keyword
    /// (SELECT, INSERT, UPDATE, DELETE), distinguishing subqueries from plain
    /// parenthesized expressions like INSERT INTO t (col1, col2) or USING (col).
    /// Uses NSString character-at-index for O(1) access per character.
    private func extractInnermostSubqueryText(from textBeforeCursor: String) -> String {
        let ns = textBeforeCursor as NSString
        let length = ns.length
        var parenStack: [Int] = []
        var inString = false
        var prevChar: UInt16 = 0

        for i in 0..<length {
            let ch = ns.character(at: i)
            if ch == Self.singleQuote && prevChar != Self.backslash {
                inString.toggle()
            }

            if !inString {
                if ch == Self.openParen {
                    parenStack.append(i)
                } else if ch == Self.closeParen {
                    if !parenStack.isEmpty {
                        parenStack.removeLast()
                    }
                }
            }

            prevChar = ch
        }

        // Walk the paren stack from innermost to outermost, looking for a subquery
        guard let regex = Self.subqueryDetectRegex else { return textBeforeCursor }

        for idx in parenStack.indices.reversed() {
            let openPos = parenStack[idx]
            let start = openPos + 1
            if start < length {
                let subText = ns.substring(from: start)
                let subNS = subText as NSString
                let matchRange = NSRange(location: 0, length: subNS.length)
                if regex.firstMatch(in: subText, range: matchRange) != nil {
                    return subText
                }
            }
        }

        return textBeforeCursor
    }

    // MARK: - Function Context

    /// Detect if cursor is inside a function call and return the function name.
    /// Uses NSString character-at-index for O(1) access per character.
    /// Tracks word start/end indices and extracts once via `substring(with:)` instead
    /// of appending characters one at a time.
    private func detectFunctionContext(in textBeforeCursor: String) -> String? {
        let ns = textBeforeCursor as NSString
        let length = ns.length
        var parenStack: [(position: Int, precedingWord: String?)] = []
        var inString = false
        var prevChar: UInt16 = 0
        var wordStart = -1        // -1 means "not in a word"
        var lastWord: String?

        for i in 0..<length {
            let ch = ns.character(at: i)
            if ch == Self.singleQuote && prevChar != Self.backslash {
                inString.toggle()
            }

            if !inString {
                if Self.isIdentifierChar(ch) {
                    if wordStart < 0 {
                        wordStart = i
                    }
                } else {
                    if wordStart >= 0 {
                        lastWord = ns.substring(with: NSRange(location: wordStart, length: i - wordStart))
                        wordStart = -1
                    }

                    if ch == Self.openParen {
                        parenStack.append((position: i, precedingWord: lastWord))
                        lastWord = nil
                    } else if ch == Self.closeParen {
                        if !parenStack.isEmpty {
                            parenStack.removeLast()
                        }
                    }
                }
            }

            prevChar = ch
        }

        // Flush trailing word (cursor is immediately after an identifier)
        if wordStart >= 0 {
            lastWord = ns.substring(with: NSRange(location: wordStart, length: length - wordStart))
        }

        // If we're inside parentheses, check if it's a function call
        if let lastParen = parenStack.last,
           let funcName = lastParen.precedingWord {
            let upperFunc = funcName.uppercased()
            let sqlFunctions: Set<String> = [
                "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "IFNULL",
                "CONCAT", "SUBSTRING", "UPPER", "LOWER", "NOW", "DATE",
                "CAST", "CONVERT", "ROUND", "ABS", "LENGTH", "TRIM",
                "GROUP_CONCAT", "DATE_FORMAT", "YEAR", "MONTH", "DAY"
            ]

            let subqueryKeywords: Set<String> = [
                "SELECT", "FROM", "WHERE", "IN", "EXISTS", "NOT"
            ]

            if sqlFunctions.contains(upperFunc) ||
                !subqueryKeywords.contains(upperFunc) {
                return funcName
            }
        }

        return nil
    }

    // MARK: - Comma Detection

    /// Check if the cursor is immediately after a comma (for multi-column contexts).
    /// Scans backwards using NSString for O(1) character access.
    private func checkIfAfterComma(_ text: String) -> Bool {
        let ns = text as NSString
        let length = ns.length
        // Scan backwards past whitespace
        var i = length - 1
        while i >= 0 {
            let ch = ns.character(at: i)
            if Self.isWhitespace(ch) {
                i -= 1
                continue
            }
            return ch == Self.comma
        }
        return false
    }

    // MARK: - Helper Methods

    /// Check if cursor is inside a string literal.
    /// Uses NSString character-at-index for O(1) access per character.
    private func isInsideString(_ text: String) -> Bool {
        let ns = text as NSString
        let length = ns.length
        var inSingleQuote = false
        var inDoubleQuote = false
        var prevChar: UInt16 = 0

        for i in 0..<length {
            let ch = ns.character(at: i)
            if ch == Self.singleQuote && prevChar != Self.backslash && !inDoubleQuote {
                inSingleQuote.toggle()
            } else if ch == Self.doubleQuote && prevChar != Self.backslash && !inSingleQuote {
                inDoubleQuote.toggle()
            }
            prevChar = ch
        }

        return inSingleQuote || inDoubleQuote
    }

    /// Check if cursor is inside a comment.
    /// Uses NSString operations for O(1) character access.
    private func isInsideComment(_ text: String) -> Bool {
        let ns = text as NSString
        let length = ns.length
        guard length > 0 else { return false }

        // Single-pass state machine scanning for block/line comments (SVC-14)
        var blockDepth = 0
        var lastBlockEnd = -1  // position after the last */ that closed depth to 0
        var idx = 0

        while idx < length {
            let ch = ns.character(at: idx)

            if blockDepth > 0 {
                // Inside a block comment — look for */
                if ch == 0x2A /* * */ && idx + 1 < length && ns.character(at: idx + 1) == 0x2F /* / */ {
                    blockDepth -= 1
                    if blockDepth == 0 {
                        lastBlockEnd = idx + 2
                    }
                    idx += 2
                    continue
                }
            } else {
                // Outside block comment
                if ch == 0x2F /* / */ && idx + 1 < length && ns.character(at: idx + 1) == 0x2A /* * */ {
                    blockDepth += 1
                    idx += 2
                    continue
                }
            }
            idx += 1
        }

        // If we're still inside an unclosed block comment, cursor is in a comment
        if blockDepth > 0 {
            return true
        }

        // Check for line comment on the last line, ignoring text inside block comments.
        // The scan for "--" must start from whichever is later: the position after
        // the last newline or the position after the last block comment close ("*/").
        // This prevents "--" inside a closed block comment from being misdetected.
        let fullRange = NSRange(location: 0, length: length)
        let lastNewlineRange = ns.range(of: "\n", options: .backwards, range: fullRange)

        let lastNewlineLocation: Int
        if lastNewlineRange.location != NSNotFound {
            lastNewlineLocation = lastNewlineRange.location + 1
        } else {
            lastNewlineLocation = 0
        }

        let lineStart = max(lastNewlineLocation, max(lastBlockEnd, 0))

        guard lineStart < length else { return false }

        let lineRange = NSRange(location: lineStart, length: length - lineStart)
        let currentLine = ns.substring(with: lineRange)
        let nsLine = currentLine as NSString
        let dashRange = nsLine.range(of: "--")
        if dashRange.location != NSNotFound {
            let before = nsLine.substring(to: dashRange.location)
            if !isInsideString(before) {
                return true
            }
        }

        return false
    }

    /// Extract the current word prefix and any dot prefix (table.column).
    /// Uses NSString character-at-index for O(1) access instead of Array(text).
    private func extractPrefix(
        from text: String
    ) -> (prefix: String, start: Int, dotPrefix: String?) {
        let ns = text as NSString
        let length = ns.length
        guard length > 0 else {
            return ("", 0, nil)
        }

        // Scan backwards to find start of identifier
        var prefixStart = length
        var foundDot = false
        var dotPosition = -1

        var i = length - 1
        while i >= 0 {
            let ch = ns.character(at: i)

            if ch == Self.dot && !foundDot {
                foundDot = true
                dotPosition = i
                i -= 1
                continue
            }

            if Self.isIdentifierChar(ch) || ch == Self.backtick || ch == Self.doubleQuote {
                prefixStart = i
            } else {
                break
            }

            i -= 1
        }

        if foundDot && dotPosition > prefixStart {
            // Has dot prefix like "users.na" or "u.na"
            let beforeDotRange = NSRange(
                location: prefixStart, length: dotPosition - prefixStart
            )
            let beforeDot = ns.substring(with: beforeDotRange)
            let afterDotRange = NSRange(
                location: dotPosition + 1, length: length - dotPosition - 1
            )
            let afterDot = ns.substring(with: afterDotRange)

            let cleanDotPrefix = beforeDot.trimmingCharacters(
                in: CharacterSet(charactersIn: "`\"")
            )
            return (afterDot, dotPosition + 1, cleanDotPrefix)
        } else {
            // No dot, just a regular prefix
            let prefixRange = NSRange(
                location: prefixStart, length: length - prefixStart
            )
            let prefix = ns.substring(with: prefixRange)
            return (prefix, prefixStart, nil)
        }
    }

    /// Extract all table references (table names and aliases) from the query
    private func extractTableReferences(from query: String) -> [TableReference] {
        var references: [TableReference] = []

        // SQL keywords that should NOT be treated as table names
        let sqlKeywords: Set<String> = [
            "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS", "NATURAL",
            "JOIN", "ON", "AND", "OR", "WHERE", "SELECT", "FROM", "AS"
        ]

        let nsRange = NSRange(location: 0, length: (query as NSString).length)

        // Uses pre-compiled static regexes for performance
        for regex in Self.tableRefRegexes {
            regex.enumerateMatches(in: query, range: nsRange) { match, _, _ in
                guard let match = match else { return }

                let tableNSRange = match.range(at: 1)
                guard tableNSRange.location != NSNotFound else { return }

                let tableName = (query as NSString).substring(with: tableNSRange)
                guard !sqlKeywords.contains(tableName.uppercased()) else { return }

                var alias: String?
                if match.numberOfRanges > 2 {
                    let aliasNSRange = match.range(at: 2)
                    if aliasNSRange.location != NSNotFound {
                        let aliasCandidate = (query as NSString).substring(
                            with: aliasNSRange
                        )
                        if !sqlKeywords.contains(aliasCandidate.uppercased()) {
                            alias = aliasCandidate
                        }
                    }
                }

                let ref = TableReference(tableName: tableName, alias: alias)
                if !references.contains(ref) {
                    references.append(ref)
                }
            }
        }

        return references
    }

    /// Pre-compiled regex for extracting table name from ALTER TABLE statements
    private static let alterTableRegex: NSRegularExpression? = {
        let pattern = "(?i)\\bALTER\\s+TABLE\\s+[`\"']?(\\w+)[`\"']?"
        return try? NSRegularExpression(pattern: pattern)
    }()

    /// Extract table name from ALTER TABLE statement
    private func extractAlterTableName(from query: String) -> String? {
        guard let regex = Self.alterTableRegex else { return nil }

        let nsRange = NSRange(location: 0, length: (query as NSString).length)
        if let match = regex.firstMatch(in: query, range: nsRange) {
            let tableNSRange = match.range(at: 1)
            if tableNSRange.location != NSNotFound {
                return (query as NSString).substring(with: tableNSRange)
            }
        }

        return nil
    }

    /// Determine the clause type based on text before cursor
    private func determineClauseType(
        textBeforeCursor: String,
        dotPrefix: String?,
        currentFunction: String? = nil
    ) -> SQLClauseType {
        // If we have a dot prefix, we're looking for columns
        if dotPrefix != nil {
            return .select // Column context
        }

        // Window to last N chars to avoid O(n) regex on large queries
        let windowSize = 5_000 // Also referenced by SQLContextAnalyzerWindowingTests
        let nsText = textBeforeCursor as NSString
        let windowedText: String
        if nsText.length > windowSize {
            windowedText = nsText.substring(from: nsText.length - windowSize)
        } else {
            windowedText = textBeforeCursor
        }

        // Remove string literals and comments for analysis
        let cleaned = removeStringsAndComments(from: windowedText)

        // Run regex-based clause detection FIRST — DDL contexts (CREATE TABLE,
        // ALTER TABLE, etc.) must take priority over function-arg detection,
        // because `CREATE TABLE test (id ` looks like a function call `test(`
        // to detectFunctionContext but is actually a column definition.
        let range = NSRange(location: 0, length: (cleaned as NSString).length)
        for (regex, clause) in Self.clauseRegexes {
            if regex.firstMatch(in: cleaned, range: range) != nil {
                return clause
            }
        }

        // If inside a function call and no stronger clause matched, return
        // function arg context
        if currentFunction != nil {
            return .functionArg
        }

        return .unknown
    }

    /// Remove string literals and comments for cleaner analysis
    private func removeStringsAndComments(from text: String) -> String {
        // Single-pass replacement using combined alternation regex (SVC-13)
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let matches = Self.stringsAndCommentsRegex.matches(in: text, range: fullRange)

        guard !matches.isEmpty else { return text }

        let mutable = NSMutableString(string: text)

        // Process in reverse to maintain valid indices
        for match in matches.reversed() {
            let matchRange = match.range
            let matched = ns.substring(with: matchRange)
            // Single-quoted strings -> empty quotes; double-quoted strings -> empty quotes
            // Block comments and line comments -> removed entirely
            if matched.hasPrefix("'") {
                mutable.replaceCharacters(in: matchRange, with: "''")
            } else if matched.hasPrefix("\"") {
                mutable.replaceCharacters(in: matchRange, with: "\"\"")
            } else {
                mutable.replaceCharacters(in: matchRange, with: "")
            }
        }

        return mutable as String
    }
}
