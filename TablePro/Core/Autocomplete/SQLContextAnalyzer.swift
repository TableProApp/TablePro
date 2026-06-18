//
//  SQLContextAnalyzer.swift
//  TablePro
//
//  Analyzes SQL query text to determine cursor context for autocomplete
//

import Foundation
import os

private let regexLogger = Logger(subsystem: "com.TablePro", category: "SQLContextAnalyzer.Regex")

private func compileRegex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
    if let regex = try? NSRegularExpression(pattern: pattern, options: options) {
        return regex
    }
    regexLogger.fault("Failed to compile static regex pattern: \(pattern, privacy: .public)")
    return NSRegularExpression()
}

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
internal struct TableReference: Hashable, Sendable {
    let tableName: String
    let alias: String?
    let schema: String?
    let derivedColumns: [String]?

    init(tableName: String, alias: String?, schema: String? = nil, derivedColumns: [String]? = nil) {
        self.tableName = tableName
        self.alias = alias
        self.schema = schema
        self.derivedColumns = derivedColumns
    }

    /// Returns the identifier that should be used to reference this table
    var identifier: String {
        alias ?? tableName
    }

    /// A derived table (subquery or CTE) carries its own column list parsed from
    /// the subquery's SELECT list, rather than resolving columns from the schema.
    var isDerived: Bool {
        derivedColumns != nil
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
    let expectsObjectName: Bool     // Cursor is in the table-operand slot of FROM/JOIN/INTO

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
        isAfterComma: Bool = false,
        expectsObjectName: Bool = false
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
        self.expectsObjectName = expectsObjectName
    }

    func replacingTableReferences(_ references: [TableReference]) -> SQLContext {
        SQLContext(
            clauseType: clauseType,
            prefix: prefix,
            prefixRange: prefixRange,
            dotPrefix: dotPrefix,
            tableReferences: references,
            isInsideString: isInsideString,
            isInsideComment: isInsideComment,
            cteNames: cteNames,
            nestingLevel: nestingLevel,
            currentFunction: currentFunction,
            isAfterComma: isAfterComma,
            expectsObjectName: expectsObjectName
        )
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
    private static let comma = UInt16(UnicodeScalar(",").value)
    private static let space = UInt16(UnicodeScalar(" ").value)
    private static let tab = UInt16(UnicodeScalar("\t").value)
    private static let cr = UInt16(UnicodeScalar("\r").value)
    private static let slash = UInt16(UnicodeScalar("/").value)
    private static let star = UInt16(UnicodeScalar("*").value)

    // MARK: - Cached Regex Patterns (Compiled Once at Class Load)

    /// Structural clause patterns that are bounded by parentheses or anchored to a
    /// leading DDL keyword, so they identify the cursor's clause unambiguously
    /// regardless of what other clauses precede it. The linear DML clauses
    /// (SELECT/FROM/JOIN/ON/WHERE/...) are resolved separately by a nearest-keyword
    /// scan (`scanLinearClause`), because a fixed-priority regex sweep cannot tell
    /// the clause nearest the cursor from one earlier in the statement.
    /// ORDER MATTERS: more specific patterns must come before general ones.
    private static let structuralClauseRegexes: [(regex: NSRegularExpression, clause: SQLClauseType)] = {
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
            // USING clause in JOIN
            ("\\bUSING\\s*\\([^)]*$", .using),
            // Window function OVER clause
            ("\\bOVER\\s*\\([^)]*$", .window),
            ("\\bPARTITION\\s+BY\\s+[^)]*$", .window),
            // Parenthesis-bounded value/list contexts
            ("\\bIN\\s*\\([^)]*$", .inList),
            ("\\b(LIMIT|OFFSET)\\s+\\d*$", .limit),
            ("\\bVALUES\\s*(?:\\([^)]*\\)\\s*,?\\s*)+\\w*$", .values),
            ("\\bVALUES\\s*\\([^)]*$", .values),
            ("\\bINSERT\\s+INTO\\s+\\w+\\s*\\([^)]*$", .insertColumns),
        ]
        return patterns.map { pattern, clause in
            (compileRegex(pattern, options: .caseInsensitive), clause)
        }
    }()

    private static let singleQuoteStringRegex = compileRegex("'[^']*'")

    private static let doubleQuoteStringRegex = compileRegex("\"[^\"]*\"")

    private static let blockCommentRegex = compileRegex("/\\*[\\s\\S]*?\\*/")

    private static let lineCommentRegex = compileRegex("--[^\n]*")

    private static let stringsAndCommentsRegex = compileRegex(
        #"'[^']*'|"[^"]*"|/\*[\s\S]*?\*/|--[^\n]*"#
    )

    private static let cteFirstRegex = compileRegex(
        "(?i)\\bWITH\\s+(?:RECURSIVE\\s+)?([\\w]+)\\s+AS\\s*\\("
    )

    private static let cteCommaRegex = compileRegex("(?i),\\s*([\\w]+)\\s+AS\\s*\\(")

    private static let tableRefRegexes: [NSRegularExpression] = {
        let segment = "[`\"']?\\w+[`\"']?"
        let path = "(\(segment)(?:\\.\(segment))*)"
        let alias = "(?:\\s+(?:AS\\s+)?[`\"']?(\\w+)[`\"']?)?"
        let patterns = [
            "(?i)(?:LEFT|RIGHT|INNER|OUTER|CROSS|FULL)?\\s*(?:OUTER)?\\s*JOIN\\s+\(path)\(alias)",
            "(?i)\\bUPDATE\\s+\(path)\(alias)",
            "(?i)\\bINSERT\\s+INTO\\s+\(path)",
            "(?i)\\bCREATE\\s+(?:UNIQUE\\s+)?INDEX\\s+\\w+\\s+ON\\s+\(path)"
        ]
        return patterns.map { compileRegex($0) }
    }()

    /// Captures the comma-separated table list after a FROM keyword, up to the
    /// next clause keyword, opening parenthesis, or statement end. Handles
    /// old-style implicit joins (`FROM a, b, c`) that the single-table pattern
    /// above could not, so every listed table is in scope for column completion.
    private static let fromListRegex = compileRegex(
        "(?i)\\bFROM\\s+([\\s\\S]+?)" +
        "(?=\\b(?:WHERE|GROUP|ORDER|HAVING|LIMIT|OFFSET|JOIN|INNER|LEFT|RIGHT" +
        "|FULL|CROSS|NATURAL|ON|USING|UNION|INTERSECT|EXCEPT|RETURNING|SET" +
        "|WINDOW|FETCH|FOR)\\b|[;()]|$)"
    )

    private static let derivedTableParser = DerivedTableParser()

    // MARK: - UTF-16 Helpers

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

        // Resolve derived tables (FROM/JOIN subqueries and CTEs) to their
        // SELECT-list columns so `alias.` completes the subquery's output.
        let derivedTables = Self.derivedTableParser.parse(currentStatement)
        mergeDerivedTables(derivedTables, cteNames: cteNames, into: &tableReferences)

        var seenReferences = Set<TableReference>(tableReferences)

        // Extract ALTER TABLE table name and add to references
        if let alterTableName = extractAlterTableName(from: currentStatement) {
            let alterRef = TableReference(tableName: alterTableName, alias: nil)
            if seenReferences.insert(alterRef).inserted {
                tableReferences.append(alterRef)
            }
        }

        // Calculate nesting level (subquery depth)
        let nestingLevel = calculateNestingLevel(in: textBeforeCursor)

        // Detect function context
        let currentFunction = detectFunctionContext(in: textBeforeCursor)

        // Check if immediately after comma
        let isAfterComma = checkIfAfterComma(textBeforeCursor)

        // Clause detection runs on the text BEFORE the token being typed: the
        // prefix is what completion filters on, so it cannot also count as a
        // committed clause keyword ("SELECT|" must still suggest the SELECT
        // keyword, not switch to select-list completions).
        let nsBeforeCursor = textBeforeCursor as NSString
        let textBeforePrefix = nsBeforeCursor.substring(to: min(prefixStart, nsBeforeCursor.length))

        // For subquery context, extract text from the innermost subquery
        // so clause detection works on the subquery's SQL, not the outer query
        let clauseText: String
        if nestingLevel > 0 {
            clauseText = extractInnermostSubqueryText(from: textBeforePrefix)
        } else {
            clauseText = textBeforePrefix
        }

        // Determine clause type
        let resolution = determineClauseType(
            textBeforeCursor: clauseText,
            dotPrefix: dotPrefix,
            currentFunction: currentFunction
        )

        return SQLContext(
            clauseType: resolution.clause,
            prefix: prefix,
            prefixRange: (statementOffset + prefixStart)..<safePosition,
            dotPrefix: dotPrefix,
            tableReferences: tableReferences,
            isInsideString: false,
            isInsideComment: false,
            cteNames: cteNames,
            nestingLevel: nestingLevel,
            currentFunction: currentFunction,
            isAfterComma: isAfterComma,
            expectsObjectName: resolution.expectsObjectName
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
                if SQLTokenBoundary.isIdentifierChar(ch) {
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
    private func extractPrefix(
        from text: String
    ) -> (prefix: String, start: Int, dotPrefix: String?) {
        let ns = text as NSString
        let length = ns.length
        guard length > 0 else {
            return ("", 0, nil)
        }

        let start = SQLTokenBoundary.segmentStart(in: ns, endingAt: length)
        let prefix = ns.substring(from: start)

        guard start > 0, ns.character(at: start - 1) == Self.dot else {
            return (prefix, start, nil)
        }

        let qualifierEnd = start - 1
        let qualifierStart = SQLTokenBoundary.segmentStart(in: ns, endingAt: qualifierEnd)
        guard qualifierStart < qualifierEnd else {
            return (prefix, start, nil)
        }

        let qualifierRange = NSRange(location: qualifierStart, length: qualifierEnd - qualifierStart)
        let dotPrefix = ns.substring(with: qualifierRange)
            .trimmingCharacters(in: CharacterSet(charactersIn: "`\""))
        return (prefix, start, dotPrefix)
    }

    private static let tableRefKeywords: Set<String> = [
        "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS", "NATURAL",
        "JOIN", "ON", "AND", "OR", "WHERE", "SELECT", "FROM", "AS"
    ]

    private static let bareIdentifierRegex = compileRegex("^\\w+$")

    private static func isBareIdentifier(_ value: String) -> Bool {
        let range = NSRange(location: 0, length: (value as NSString).length)
        return bareIdentifierRegex.firstMatch(in: value, range: range) != nil
    }

    private static let identifierQuoteChars = CharacterSet(charactersIn: "`\"'")

    /// Extract all table references (table names and aliases) from the query
    private func extractTableReferences(from query: String) -> [TableReference] {
        var references: [TableReference] = []
        var seen = Set<TableReference>()

        appendFromListReferences(from: query, into: &references, seen: &seen)

        let nsRange = NSRange(location: 0, length: (query as NSString).length)

        for regex in Self.tableRefRegexes {
            regex.enumerateMatches(in: query, range: nsRange) { match, _, _ in
                guard let match = match else { return }

                let tableNSRange = match.range(at: 1)
                guard tableNSRange.location != NSNotFound else { return }

                let rawName = (query as NSString).substring(with: tableNSRange)
                let segments = rawName.split(separator: ".").map {
                    String($0).trimmingCharacters(in: Self.identifierQuoteChars)
                }
                guard let tableName = segments.last, !tableName.isEmpty else { return }
                guard !Self.tableRefKeywords.contains(tableName.uppercased()) else { return }

                let schema = segments.count >= 2 ? segments[segments.count - 2] : nil

                var alias: String?
                if match.numberOfRanges > 2 {
                    let aliasNSRange = match.range(at: 2)
                    if aliasNSRange.location != NSNotFound {
                        let aliasCandidate = (query as NSString).substring(
                            with: aliasNSRange
                        )
                        if !Self.tableRefKeywords.contains(aliasCandidate.uppercased()) {
                            alias = aliasCandidate
                        }
                    }
                }

                let ref = TableReference(tableName: tableName, alias: alias, schema: schema)
                if seen.insert(ref).inserted {
                    references.append(ref)
                }
            }
        }

        return references
    }

    /// Attach derived-table columns to references and add any derived table or
    /// CTE not already in scope. Columns attach to a matching reference (e.g. a
    /// CTE aliased in a FROM clause), and the derived table or CTE is still
    /// registered under its own name so it resolves by either identifier.
    private func mergeDerivedTables(
        _ derivedTables: [DerivedTable],
        cteNames: [String],
        into references: inout [TableReference]
    ) {
        let derivedColumnsByAlias = Dictionary(
            derivedTables.map { ($0.alias.lowercased(), $0.columns) },
            uniquingKeysWith: { first, _ in first }
        )

        for index in references.indices {
            let ref = references[index]
            for key in [ref.tableName.lowercased(), ref.identifier.lowercased()] {
                guard let columns = derivedColumnsByAlias[key] else { continue }
                references[index] = TableReference(
                    tableName: ref.tableName, alias: ref.alias, schema: ref.schema, derivedColumns: columns
                )
                break
            }
        }

        var present = Set(references.map { $0.identifier.lowercased() })
        for derived in derivedTables where present.insert(derived.alias.lowercased()).inserted {
            references.append(
                TableReference(tableName: derived.alias, alias: derived.alias, derivedColumns: derived.columns)
            )
        }
        for cteName in cteNames where present.insert(cteName.lowercased()).inserted {
            references.append(TableReference(tableName: cteName, alias: nil))
        }
    }

    /// Parse each comma-separated entry in a FROM list into a table reference.
    private func appendFromListReferences(
        from query: String,
        into references: inout [TableReference],
        seen: inout Set<TableReference>
    ) {
        let nsQuery = query as NSString
        let nsRange = NSRange(location: 0, length: nsQuery.length)
        Self.fromListRegex.enumerateMatches(in: query, range: nsRange) { match, _, _ in
            guard let match = match else { return }
            let listRange = match.range(at: 1)
            guard listRange.location != NSNotFound else { return }

            let listText = nsQuery.substring(with: listRange)
            for entry in listText.split(separator: ",") {
                guard let ref = self.tableReference(fromListEntry: String(entry)) else { continue }
                if seen.insert(ref).inserted {
                    references.append(ref)
                }
            }
        }
    }

    /// Parse a single `table [AS] alias` entry from a FROM list.
    private func tableReference(fromListEntry entry: String) -> TableReference? {
        let tokens = entry
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .map(String.init)
        guard let pathToken = tokens.first else { return nil }

        let segments = pathToken.split(separator: ".").map {
            String($0).trimmingCharacters(in: Self.identifierQuoteChars)
        }
        guard let tableName = segments.last, !tableName.isEmpty else { return nil }
        // Reject anything that is not a plain identifier path, so a derived-table
        // subquery (`FROM (SELECT ...) x`) never yields a phantom table name.
        guard segments.allSatisfy(Self.isBareIdentifier) else { return nil }
        guard !Self.tableRefKeywords.contains(tableName.uppercased()) else { return nil }

        let schema = segments.count >= 2 ? segments[segments.count - 2] : nil

        var alias: String?
        if tokens.count >= 2 {
            var candidate = tokens[1]
            if candidate.uppercased() == "AS", tokens.count >= 3 {
                candidate = tokens[2]
            }
            let cleaned = candidate.trimmingCharacters(in: Self.identifierQuoteChars)
            if !cleaned.isEmpty, !Self.tableRefKeywords.contains(cleaned.uppercased()) {
                alias = cleaned
            }
        }

        return TableReference(tableName: tableName, alias: alias, schema: schema)
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

    /// A resolved clause plus whether the cursor sits in a table-operand slot.
    private struct ClauseResolution {
        let clause: SQLClauseType
        let expectsObjectName: Bool
    }

    /// Determine the clause type based on text before cursor
    private func determineClauseType(
        textBeforeCursor: String,
        dotPrefix: String?,
        currentFunction: String? = nil
    ) -> ClauseResolution {
        // If we have a dot prefix, we're looking for columns
        if dotPrefix != nil {
            return ClauseResolution(clause: .select, expectsObjectName: false)
        }

        // Window to last N chars to avoid O(n) work on large queries
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

        // Structural / DDL contexts FIRST. These are anchored to a leading keyword
        // or bounded by parentheses, so they take priority over function-arg
        // detection (`CREATE TABLE test (id ` looks like a function call `test(`
        // but is a column definition) and over the linear-clause scan.
        let range = NSRange(location: 0, length: (cleaned as NSString).length)
        for (regex, clause) in Self.structuralClauseRegexes {
            if regex.firstMatch(in: cleaned, range: range) != nil {
                return ClauseResolution(clause: clause, expectsObjectName: false)
            }
        }

        // Linear DML clauses: resolve by the clause keyword nearest the cursor,
        // not by a fixed priority order. This is what lets `... ON a = b JOIN |`
        // detect JOIN (suggest tables) instead of the earlier ON.
        if let resolution = scanLinearClause(in: cleaned) {
            return resolution
        }

        // If inside a function call and no stronger clause matched, return
        // function arg context
        if currentFunction != nil {
            return ClauseResolution(clause: .functionArg, expectsObjectName: false)
        }

        return ClauseResolution(clause: .unknown, expectsObjectName: false)
    }

    // MARK: - Linear Clause Scan

    private enum ScanTokenKind {
        case word
        case openParen
        case closeParen
        case comma
        case other
    }

    private struct ScanToken {
        let kind: ScanTokenKind
        let upper: String
    }

    /// Find the clause introduced by the keyword nearest the cursor.
    /// Scans the cleaned text-before-cursor backwards, skipping content inside
    /// closed parentheses and balanced `CASE … END`, and passing transparently
    /// through an enclosing open parenthesis (a function call or grouping) so the
    /// governing clause is still found. Returns nil when no clause keyword governs
    /// the cursor (caller falls back to function-arg or unknown).
    private func scanLinearClause(in cleaned: String) -> ClauseResolution? {
        let tokens = tokenize(cleaned)
        var depth = 0
        var pendingEnd = 0
        var sawObject = false
        var slotClosed = false

        for index in stride(from: tokens.count - 1, through: 0, by: -1) {
            let token = tokens[index]
            switch token.kind {
            case .closeParen:
                depth += 1
            case .openParen:
                if depth > 0 { depth -= 1 }
            case .other:
                continue
            case .comma:
                // A comma at the cursor's depth closes the current operand slot,
                // so a later table in a `FROM a, b` list still expects a name.
                if depth == 0 { slotClosed = true }
            case .word:
                guard depth == 0 else { continue }
                let word = token.upper
                if word == "END" {
                    pendingEnd += 1
                    slotClosed = true
                    continue
                }
                if word == "CASE" {
                    if pendingEnd > 0 {
                        pendingEnd -= 1
                        slotClosed = true
                        continue
                    }
                    return ClauseResolution(clause: .caseExpression, expectsObjectName: false)
                }
                guard pendingEnd == 0 else { continue }
                let previous = index > 0 ? tokens[index - 1].upper : nil
                if let clause = clause(forKeyword: word, previous: previous, sawObject: sawObject) {
                    return clause
                }
                if !slotClosed { sawObject = true }
            }
        }

        return nil
    }

    /// Map a clause-introducing keyword to its clause. `sawObject` is true when a
    /// non-keyword identifier already appeared between this keyword and the cursor,
    /// which means a table/operand was typed and the cursor is past the operand slot.
    /// Returns nil for any word that does not introduce a linear clause.
    private func clause(forKeyword word: String, previous: String?, sawObject: Bool) -> ClauseResolution? {
        switch word {
        case "WHEN", "THEN", "ELSE":
            return ClauseResolution(clause: .caseExpression, expectsObjectName: false)
        case "SELECT":
            return ClauseResolution(clause: .select, expectsObjectName: false)
        case "FROM":
            return ClauseResolution(clause: .from, expectsObjectName: !sawObject)
        case "JOIN":
            return ClauseResolution(clause: .join, expectsObjectName: !sawObject)
        case "INTO":
            return ClauseResolution(clause: .into, expectsObjectName: !sawObject)
        case "ON":
            return ClauseResolution(clause: .on, expectsObjectName: false)
        case "WHERE":
            return ClauseResolution(clause: .where_, expectsObjectName: false)
        case "AND", "OR":
            return ClauseResolution(clause: .and, expectsObjectName: false)
        case "HAVING":
            return ClauseResolution(clause: .having, expectsObjectName: false)
        case "SET":
            return ClauseResolution(clause: .set, expectsObjectName: false)
        case "RETURNING":
            return ClauseResolution(clause: .returning, expectsObjectName: false)
        case "UNION", "INTERSECT", "EXCEPT":
            return ClauseResolution(clause: .union, expectsObjectName: false)
        case "BY":
            switch previous {
            case "GROUP":
                return ClauseResolution(clause: .groupBy, expectsObjectName: false)
            case "ORDER":
                return ClauseResolution(clause: .orderBy, expectsObjectName: false)
            case "PARTITION":
                return ClauseResolution(clause: .window, expectsObjectName: false)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// Tokenize text into words, parentheses, commas, and other separators.
    /// Words are uppercased for case-insensitive keyword matching.
    /// Uses NSString character-at-index for O(1) access per character.
    private func tokenize(_ text: String) -> [ScanToken] {
        let ns = text as NSString
        let length = ns.length
        var tokens: [ScanToken] = []
        var wordStart = -1

        func flushWord(end: Int) {
            guard wordStart >= 0 else { return }
            let word = ns.substring(with: NSRange(location: wordStart, length: end - wordStart))
            tokens.append(ScanToken(kind: .word, upper: word.uppercased()))
            wordStart = -1
        }

        for i in 0..<length {
            let ch = ns.character(at: i)
            // Token chars include quote marks, so a backtick- or double-quoted
            // identifier becomes one opaque word that never matches a keyword.
            if SQLTokenBoundary.isTokenChar(ch) {
                if wordStart < 0 { wordStart = i }
                continue
            }
            flushWord(end: i)
            switch ch {
            case Self.openParen:
                tokens.append(ScanToken(kind: .openParen, upper: ""))
            case Self.closeParen:
                tokens.append(ScanToken(kind: .closeParen, upper: ""))
            case Self.comma:
                tokens.append(ScanToken(kind: .comma, upper: ""))
            default:
                if !Self.isWhitespace(ch) {
                    tokens.append(ScanToken(kind: .other, upper: ""))
                }
            }
        }
        flushWord(end: length)

        return tokens
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
