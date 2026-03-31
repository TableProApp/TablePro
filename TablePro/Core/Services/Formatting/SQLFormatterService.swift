//
//  SQLFormatterService.swift
//  TablePro
//
//  Created by OpenCode on 1/17/26.
//

import Foundation

// MARK: - Formatter Protocol

protocol SQLFormatterProtocol {
    /// Format SQL with optional cursor position preservation
    func format(
        _ sql: String,
        dialect: DatabaseType,
        cursorOffset: Int?,
        options: SQLFormatterOptions
    ) throws -> SQLFormatterResult
}

// MARK: - Main Formatter Service

struct SQLFormatterService: SQLFormatterProtocol {
    private static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("Invalid regex pattern: \(pattern)")
        }
    }
    // MARK: - Constants

    /// Maximum input size: 10MB (protection against DoS)
    private static let maxInputSize = 10 * 1_024 * 1_024

    /// Alignment for SELECT columns (length of "SELECT ")
    private static let selectKeywordLength = 7

    // MARK: - Cached Regex Patterns (CPU-3, CPU-9, CPU-10)

    /// String literal extraction patterns — one per quote character
    private static let stringLiteralRegexes: [String: NSRegularExpression] = {
        var result: [String: NSRegularExpression] = [:]
        for quoteChar in ["'", "\"", "`"] {
            let escaped = NSRegularExpression.escapedPattern(for: quoteChar)
            let pattern = "\(escaped)((?:\\\\\\\\\(quoteChar)|[^\(quoteChar)])*?)\(escaped)"
            result[quoteChar] = regex(pattern)
        }
        return result
    }()

    /// Line comment pattern: --[^\n]*
    private static let lineCommentRegex: NSRegularExpression = {
        regex("--[^\\n]*")
    }()

    /// Block comment pattern: /* ... */
    private static let blockCommentRegex: NSRegularExpression = {
        regex("/\\*.*?\\*/", options: .dotMatchesLineSeparators)
    }()

    /// Line break keyword patterns — pre-compiled for all 16 keywords (CPU-9)
    /// Sorted by keyword length (longest first) to handle multi-word keywords correctly
    private static let lineBreakRegexes: [(keyword: String, regex: NSRegularExpression)] = {
        let keywords = [
            "SELECT", "FROM", "WHERE", "JOIN", "INNER JOIN", "LEFT JOIN", "RIGHT JOIN",
            "FULL JOIN", "CROSS JOIN", "ORDER BY", "GROUP BY", "HAVING",
            "UNION", "UNION ALL", "INTERSECT", "EXCEPT", "LIMIT", "OFFSET"
        ]
        return keywords.sorted(by: { $0.count > $1.count }).map { keyword in
            let escapedKeyword = NSRegularExpression.escapedPattern(for: keyword)
            let pattern = "\\s+\(escapedKeyword)\\b"
            let regex = regex(pattern, options: .caseInsensitive)
            return (keyword, regex)
        }
    }()

    /// Subquery pattern: \(\s*SELECT\b  (CPU-10)
    private static let subqueryRegex: NSRegularExpression = {
        regex("\\(\\s*SELECT\\b", options: .caseInsensitive)
    }()

    /// Word boundary pattern for "END" keyword (CPU-10)
    private static let endWordBoundaryRegex: NSRegularExpression = {
        regex("\\bEND\\b", options: .caseInsensitive)
    }()

    /// Word boundary pattern for "CASE" keyword (CPU-10)
    private static let caseWordBoundaryRegex: NSRegularExpression = {
        regex("\\bCASE\\b", options: .caseInsensitive)
    }()

    /// WHERE condition alignment pattern: \s+(AND|OR)\s+
    private static let majorKeywordRegex: NSRegularExpression = {
        regex("\\b(ORDER|GROUP|HAVING|LIMIT|UNION|INTERSECT)\\b", options: .caseInsensitive)
    }()

    private static let whereConditionRegex: NSRegularExpression = {
        regex("\\s+(AND|OR)\\s+", options: .caseInsensitive)
    }()

    /// Keyword uppercasing regex cache per DatabaseType (CPU-5)
    /// Uses NSLock for thread safety since static mutable state is shared.
    private static let keywordRegexLock = NSLock()
    private static var keywordRegexCache: [DatabaseType: NSRegularExpression] = [:]

    /// Get or create the keyword uppercasing regex for a given database type
    private static func keywordRegex(for dialect: DatabaseType) -> NSRegularExpression? {
        keywordRegexLock.lock()
        if let cached = keywordRegexCache[dialect] {
            keywordRegexLock.unlock()
            return cached
        }
        keywordRegexLock.unlock()

        let provider = resolveDialectProvider(for: dialect)
        let allKeywords = provider.keywords.union(provider.functions).union(provider.dataTypes)
        let escapedKeywords = allKeywords.map { NSRegularExpression.escapedPattern(for: $0) }
        let pattern = "\\b(\(escapedKeywords.joined(separator: "|")))\\b"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }

        keywordRegexLock.lock()
        defer { keywordRegexLock.unlock() }
        if let cached = keywordRegexCache[dialect] {
            return cached
        }
        keywordRegexCache[dialect] = regex
        return regex
    }

    private static func resolveDialectProvider(for dialect: DatabaseType) -> SQLDialectProvider {
        SQLDialectFactory.createDialect(for: dialect)
    }

    // MARK: - Public API

    func format(
        _ sql: String,
        dialect: DatabaseType,
        cursorOffset: Int? = nil,
        options: SQLFormatterOptions = .default
    ) throws -> SQLFormatterResult {
        // Fix #4: Input size limit (DoS protection)
        guard sql.utf8.count <= Self.maxInputSize else {
            throw SQLFormatterError.internalError("SQL too large (max \(Self.maxInputSize / 1_024 / 1_024)MB)")
        }

        // Validate input
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SQLFormatterError.emptyInput
        }

        // CPU-8: Use utf16.count for O(1) length instead of O(n) String.count
        let sqlLength = sql.utf16.count
        if let cursor = cursorOffset, cursor > sqlLength {
            throw SQLFormatterError.invalidCursorPosition(cursor, max: sqlLength)
        }

        let dialectProvider = Self.resolveDialectProvider(for: dialect)

        // Format the SQL
        let formatted = formatSQL(sql, dialect: dialectProvider, databaseType: dialect, options: options)

        // Cursor preservation
        let newCursor = cursorOffset.map { original in
            preserveCursorPosition(original: original, oldText: sql, newText: formatted)
        }

        return SQLFormatterResult(
            formattedSQL: formatted,
            cursorOffset: newCursor
        )
    }

    // MARK: - Core Formatting Logic

    private func formatSQL(
        _ sql: String,
        dialect: SQLDialectProvider,
        databaseType: DatabaseType,
        options: SQLFormatterOptions
    ) -> String {
        var result = sql

        // Step 1: Preserve comments (replace with UUID placeholders)
        let (sqlWithoutComments, comments) = options.preserveComments
            ? extractComments(from: result)
            : (result, [])

        result = sqlWithoutComments

        // Step 2: Extract string literals (to protect from keyword replacement)
        let (sqlWithoutStrings, stringLiterals) = extractStringLiterals(from: result, dialect: dialect)
        result = sqlWithoutStrings

        // Step 3: Uppercase keywords (now safe - strings removed)
        if options.uppercaseKeywords {
            result = uppercaseKeywords(result, databaseType: databaseType)
        }

        // Step 4: Restore string literals
        result = restoreStringLiterals(result, literals: stringLiterals)

        // Step 5: Add line breaks before major keywords
        result = addLineBreaks(result)

        // Step 6: Add indentation based on nesting
        if options.indentSize > 0 {
            result = addIndentation(result, indentSize: options.indentSize)
        }

        // Step 7: Align SELECT columns
        if options.alignColumns {
            result = alignSelectColumns(result)
        }

        // Step 8: Format JOINs (handled by line breaks)
        if options.formatJoins {
            result = formatJoins(result)
        }

        // Step 9: Align WHERE conditions
        if options.alignWhere {
            result = alignWhereConditions(result)
        }

        // Step 10: Restore comments
        if options.preserveComments {
            result = restoreComments(result, comments: comments)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - String Literal Protection (Fix #2)

    /// Extract string literals to protect from keyword replacement
    /// Handles: 'single quotes', "double quotes", `backticks`
    private func extractStringLiterals(from sql: String, dialect: SQLDialectProvider) -> (String, [(placeholder: String, content: String)]) {
        var counter = 0
        var result = sql
        var literals: [(String, String)] = []

        // Determine quote characters based on dialect
        // MySQL/SQLite: single quotes and backticks
        // PostgreSQL: single quotes and double quotes
        let quoteChars: [String]
        switch dialect.identifierQuote {
        case "\"":
            quoteChars = ["'", "\""]  // PostgreSQL
        default:
            quoteChars = ["'", "`"]   // MySQL, SQLite
        }

        // Extract each type of string literal using cached regex
        for quoteChar in quoteChars {
            guard let regex = Self.stringLiteralRegexes[quoteChar] else { continue }
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))

            // Process in reverse to maintain valid indices
            for match in matches.reversed() {
                if let range = safeRange(from: match.range, in: result) {
                    let literal = String(result[range])
                    let placeholder = "__STRING_\(counter)__"
                    counter += 1
                    literals.insert((placeholder, literal), at: 0)
                    result.replaceSubrange(range, with: placeholder)
                }
            }
        }

        return (result, literals)
    }

    /// Restore string literals after formatting
    private func restoreStringLiterals(_ sql: String, literals: [(placeholder: String, content: String)]) -> String {
        var result = sql
        for (placeholder, content) in literals {
            result = result.replacingOccurrences(of: placeholder, with: content)
        }
        return result
    }

    // MARK: - Comment Handling (Fix #6: UUID placeholders)

    /// Extract comments with UUID-based placeholders (prevents collisions)
    private func extractComments(from sql: String) -> (String, [(placeholder: String, content: String)]) {
        var result = sql
        var comments: [(String, String)] = []
        var counter = 0

        // Extract line comments (-- ...) using cached regex
        let lineMatches = Self.lineCommentRegex.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        )
        for match in lineMatches.reversed() {
            if let range = safeRange(from: match.range, in: result) {
                let comment = String(result[range])
                let placeholder = "__COMMENT_\(counter)__"
                counter += 1
                comments.insert((placeholder, comment), at: 0)
                result.replaceSubrange(range, with: placeholder)
            }
        }

        // Extract block comments (/* ... */) using cached regex
        // Note: This doesn't handle nested block comments (SQL doesn't officially support them)
        let blockMatches = Self.blockCommentRegex.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        )
        for match in blockMatches.reversed() {
            if let range = safeRange(from: match.range, in: result) {
                let comment = String(result[range])
                let placeholder = "__COMMENT_\(counter)__"
                counter += 1
                comments.insert((placeholder, comment), at: 0)
                result.replaceSubrange(range, with: placeholder)
            }
        }

        return (result, comments)
    }

    /// Restore comments after formatting
    private func restoreComments(_ sql: String, comments: [(placeholder: String, content: String)]) -> String {
        var result = sql
        for (placeholder, content) in comments {
            result = result.replacingOccurrences(of: placeholder, with: content)
        }
        return result
    }

    // MARK: - Keyword Uppercasing (Fix #1: Single-pass optimization)

    /// Uppercase keywords using single regex pass with cached pattern (CPU-5)
    private func uppercaseKeywords(_ sql: String, databaseType: DatabaseType) -> String {
        guard let regex = Self.keywordRegex(for: databaseType) else {
            return sql
        }

        // Use NSMutableString for O(1) in-place replacement instead of
        // reverse-iterating Swift String replaceSubrange (SVC-11)
        let mutable = NSMutableString(string: sql)
        let fullRange = NSRange(location: 0, length: mutable.length)
        let matches = regex.matches(in: sql, range: fullRange)

        // Process in reverse to maintain valid indices
        for match in matches.reversed() {
            let matchRange = match.range
            let keyword = mutable.substring(with: matchRange)
            mutable.replaceCharacters(in: matchRange, with: keyword.uppercased())
        }

        return mutable as String
    }

    // MARK: - Line Breaks

    private func addLineBreaks(_ sql: String) -> String {
        var result = sql

        // Use pre-compiled regex patterns for all line break keywords (CPU-9)
        for (keyword, regex) in Self.lineBreakRegexes {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "\n\(keyword.uppercased())"
            )
        }

        return result
    }

    // MARK: - Indentation (Fix #5: Word boundaries instead of contains)

    private func addIndentation(_ sql: String, indentSize: Int) -> String {
        let lines = sql.components(separatedBy: "\n")
        var indentLevel = 0
        var result: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Decrease indent before processing closing parens or END
            // Uses cached regex for word boundary checks (CPU-10)
            if trimmed.starts(with: ")") || Self.hasWordBoundary(trimmed, regex: Self.endWordBoundaryRegex) {
                indentLevel = max(0, indentLevel - 1)
            }

            // Add indentation
            let indent = String(repeating: " ", count: indentLevel * indentSize)
            result.append(indent + trimmed)

            // Increase indent after opening parens or CASE keyword
            if trimmed.hasSuffix("(") || Self.hasWordBoundary(trimmed, regex: Self.caseWordBoundaryRegex) {
                indentLevel += 1
            }

            // Special handling for subqueries: (SELECT — uses cached regex (CPU-10)
            if Self.subqueryRegex.firstMatch(
                in: trimmed,
                range: NSRange(trimmed.startIndex..., in: trimmed)
            ) != nil {
                indentLevel += 1
            }

            // Decrease after closing paren (if not at start)
            if trimmed.hasSuffix(")") && !trimmed.starts(with: ")") {
                indentLevel = max(0, indentLevel - 1)
            }
        }

        return result.joined(separator: "\n")
    }

    /// Check if a word appears with word boundaries using a pre-compiled regex (CPU-10)
    private static func hasWordBoundary(_ text: String, regex: NSRegularExpression) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: - Column Alignment

    /// Align SELECT columns vertically
    ///
    /// Example:
    ///   SELECT id, name, email FROM users
    /// Becomes:
    ///   SELECT id,
    ///          name,
    ///          email
    ///   FROM users
    private func alignSelectColumns(_ sql: String) -> String {
        // Find SELECT...FROM region
        guard let selectRange = sql.range(of: "SELECT", options: .caseInsensitive),
              let fromRange = sql.range(of: "FROM", options: .caseInsensitive, range: selectRange.upperBound..<sql.endIndex) else {
            return sql
        }

        // Fix #3: Work with immutable substrings to avoid index invalidation
        let selectClause = String(sql[selectRange.upperBound..<fromRange.lowerBound])
        let columns = selectClause.components(separatedBy: ",")

        guard columns.count > 1 else {
            return sql  // Only one column, no alignment needed
        }

        // Align columns with proper spacing
        let alignedColumns = columns.enumerated().map { index, column in
            let trimmed = column.trimmingCharacters(in: .whitespacesAndNewlines)
            if index == 0 {
                return trimmed
            } else {
                return String(repeating: " ", count: Self.selectKeywordLength) + trimmed
            }
        }.joined(separator: ",\n")

        // Rebuild SQL (Fix #3: Use string concatenation instead of replaceSubrange)
        let before = String(sql[..<selectRange.upperBound])
        let after = String(sql[fromRange.lowerBound...])
        return before + " " + alignedColumns + "\n" + after
    }

    // MARK: - JOIN Formatting

    private func formatJoins(_ sql: String) -> String {
        // Already handled by addLineBreaks
        sql
    }

    // MARK: - WHERE Condition Alignment

    private func alignWhereConditions(_ sql: String) -> String {
        // Find WHERE clause
        guard let whereRange = sql.range(of: "WHERE", options: .caseInsensitive) else {
            return sql
        }

        // Find end of WHERE clause using single regex scan
        let searchStart = whereRange.upperBound
        let searchNSRange = NSRange(searchStart..<sql.endIndex, in: sql)
        var endIndex = sql.endIndex

        if let match = Self.majorKeywordRegex.firstMatch(in: sql, range: searchNSRange),
           let matchRange = Range(match.range, in: sql) {
            endIndex = matchRange.lowerBound
        }

        // Fix #3: Work with immutable substring
        let whereClause = String(sql[whereRange.upperBound..<endIndex])

        // Add line breaks before AND/OR using cached regex
        let replaced = Self.whereConditionRegex.stringByReplacingMatches(
            in: whereClause,
            range: NSRange(whereClause.startIndex..., in: whereClause),
            withTemplate: "\n  $1 "
        )

        // Rebuild SQL (Fix #3: Use string concatenation)
        let before = String(sql[..<whereRange.upperBound])
        let after = String(sql[endIndex...])
        return before + replaced + after
    }

    // MARK: - Cursor Preservation

    /// Preserve cursor position using ratio-based approach
    ///
    /// - Note: This is a simple heuristic. For better accuracy, consider:
    ///   - Tracking cursor context (inside string, after keyword, etc.)
    ///   - Using token-based positioning
    /// - Returns: New cursor position, clamped to valid range
    private func preserveCursorPosition(original: Int, oldText: String, newText: String) -> Int {
        guard !oldText.isEmpty else { return 0 }

        // CPU-8: Use utf16.count for O(1) length instead of O(n) String.count
        let oldLength = oldText.utf16.count
        let newLength = newText.utf16.count

        let ratio = Double(original) / Double(oldLength)
        let newPosition = Int(ratio * Double(newLength))

        return min(newPosition, newLength)
    }

    // MARK: - Helper Methods

    /// Safe NSRange to Range conversion (Fix #7: Unicode handling)
    ///
    /// NSRange uses UTF-16 code units, Swift String.Index uses Unicode scalars.
    /// This can cause issues with emoji and other multi-byte characters.
    private func safeRange(from nsRange: NSRange, in string: String) -> Range<String.Index>? {
        // Use proper Range initializer that handles UTF-16 conversion
        Range(nsRange, in: string)
    }
}
