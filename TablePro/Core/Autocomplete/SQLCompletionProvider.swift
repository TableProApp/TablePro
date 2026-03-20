//
//  SQLCompletionProvider.swift
//  TablePro
//
//  Main orchestrator for SQL autocomplete
//

import Foundation
import TableProPluginKit

/// Main provider for SQL autocomplete suggestions
final class SQLCompletionProvider {
    // MARK: - Properties

    private let contextAnalyzer = SQLContextAnalyzer()
    private let schemaProvider: SQLSchemaProvider
    private var databaseType: DatabaseType?
    private var cachedDialect: SQLDialectDescriptor?
    private var cachedStatementCompletions: [CompletionEntry] = []
    private var favoriteKeywords: [String: (name: String, query: String)] = [:]

    /// Minimum prefix length to trigger suggestions
    private let minPrefixLength = 1

    /// Default maximum number of suggestions to return
    private let defaultMaxSuggestions = 20

    /// Context-aware suggestion limit: schema-heavy clauses get more results
    private func maxSuggestions(for clauseType: SQLClauseType) -> Int {
        switch clauseType {
        case .from, .join, .into, .dropObject, .createIndex,
             .select, .where_, .and, .on, .having, .groupBy, .orderBy,
             .set, .insertColumns, .returning, .using:
            return 40
        default:
            return defaultMaxSuggestions
        }
    }

    // MARK: - Init

    init(schemaProvider: SQLSchemaProvider, databaseType: DatabaseType? = nil,
         dialect: SQLDialectDescriptor? = nil, statementCompletions: [CompletionEntry] = []) {
        self.schemaProvider = schemaProvider
        self.databaseType = databaseType
        self.cachedDialect = dialect
        self.cachedStatementCompletions = statementCompletions
    }

    /// Update the database type for context-aware completions
    func setDatabaseType(_ type: DatabaseType, dialect: SQLDialectDescriptor? = nil, statementCompletions: [CompletionEntry] = []) {
        self.databaseType = type
        self.cachedDialect = dialect
        self.cachedStatementCompletions = statementCompletions
    }

    /// Update cached favorite keywords for autocomplete expansion
    func updateFavoriteKeywords(_ keywords: [String: (name: String, query: String)]) {
        self.favoriteKeywords = keywords
    }

    func retrySchemaIfNeeded() async {
        await schemaProvider.retryLoadSchemaIfNeeded()
    }

    // MARK: - Public API

    /// Get completion suggestions for the current cursor position
    func getCompletions(
        text: String,
        cursorPosition: Int
    ) async -> (items: [SQLCompletionItem], context: SQLContext) {
        // Analyze context
        let context = contextAnalyzer.analyze(query: text, cursorPosition: cursorPosition)

        // Don't complete inside strings or comments
        if context.isInsideString || context.isInsideComment {
            return ([], context)
        }

        // Get candidates based on context
        var candidates = await getCandidates(for: context)

        // Filter by prefix and compute match highlight ranges
        if !context.prefix.isEmpty {
            candidates = filterByPrefix(candidates, prefix: context.prefix)
            populateMatchRanges(&candidates, prefix: context.prefix)
        }

        // Rank results
        candidates = rankResults(candidates, prefix: context.prefix, context: context)

        // Limit results
        let limited = Array(candidates.prefix(maxSuggestions(for: context.clauseType)))

        return (limited, context)
    }

    // MARK: - Candidate Generation

    /// Get candidate completions based on context
    private func getCandidates( // swiftlint:disable:this function_body_length
        for context: SQLContext
    ) async -> [SQLCompletionItem] {
        var items: [SQLCompletionItem] = []

        // Check for favorite keyword matches first (highest priority)
        if !favoriteKeywords.isEmpty && !context.prefix.isEmpty {
            let lowerPrefix = context.prefix.lowercased()
            for (keyword, value) in favoriteKeywords where keyword.lowercased().hasPrefix(lowerPrefix) {
                items.append(.favorite(keyword: keyword, name: value.name, query: value.query))
            }
        }

        // If we have a dot prefix, we're looking for columns of a specific table
        if let dotPrefix = context.dotPrefix {
            // Resolve the table name from alias or direct reference
            if let tableName = await schemaProvider.resolveAlias(dotPrefix, in: context.tableReferences) {
                items = await schemaProvider.columnCompletionItems(for: tableName)
            }
            return items
        }

        // Add items based on clause type
        switch context.clauseType {
        case .from, .join:
            // Tables + JOIN/clause transition keywords
            items = await schemaProvider.tableCompletionItems()
            items += filterKeywords([
                "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN",
                "LEFT OUTER JOIN", "RIGHT OUTER JOIN", "FULL OUTER JOIN",
                "CROSS JOIN", "NATURAL JOIN", "JOIN",
                "ON", "USING", "WHERE", "ORDER BY", "GROUP BY", "HAVING", "LIMIT",
                "UNION", "INTERSECT", "EXCEPT"
            ])

        case .into:
            // Tables + INSERT continuation keywords
            items = await schemaProvider.tableCompletionItems()
            items += filterKeywords([
                "VALUES", "SELECT", "SET",
                "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN",
                "LEFT OUTER JOIN", "RIGHT OUTER JOIN", "FULL OUTER JOIN",
                "CROSS JOIN", "NATURAL JOIN", "JOIN",
                "ON", "USING", "WHERE", "ORDER BY", "GROUP BY", "HAVING", "LIMIT",
                "UNION", "INTERSECT", "EXCEPT"
            ])

        case .select:
            if let funcName = context.currentFunction {
                // Inside function arguments within SELECT context
                let upperFunc = funcName.uppercased()
                if upperFunc == "COUNT" {
                    // COUNT() special: suggest * and DISTINCT as top items
                    var starItem = SQLCompletionItem(
                        label: "*",
                        kind: .keyword,
                        insertText: "*",
                        detail: String(localized: "All columns"),
                        documentation: String(localized: "Count all rows")
                    )
                    starItem.sortPriority = 10
                    items.append(starItem)
                    var distinctItem = SQLCompletionItem.keyword("DISTINCT")
                    distinctItem.sortPriority = 20
                    items.append(distinctItem)
                }
                // Function-arg items: columns, functions, value keywords
                items += await schemaProvider.allColumnsInScope(for: context.tableReferences)
                items += SQLKeywords.functionItems()
                items += filterKeywords(["NULL", "TRUE", "FALSE"])
                if funcName.uppercased() != "COUNT" {
                    items += filterKeywords(["DISTINCT"])
                }
            } else {
                // Normal SELECT list: star wildcard + columns + functions + keywords
                items.append(SQLCompletionItem(
                    label: "*",
                    kind: .keyword,
                    insertText: "*",
                    detail: "All columns",
                    sortPriority: 50
                ))
                // table.* suggestions when multiple tables in scope (HP-5)
                for ref in context.tableReferences {
                    let qualifier = ref.alias ?? ref.tableName
                    items.append(SQLCompletionItem(
                        label: "\(qualifier).*",
                        kind: .keyword,
                        insertText: "\(qualifier).*",
                        detail: "All columns from \(ref.tableName)",
                        sortPriority: 60
                    ))
                }
                items += await schemaProvider.allColumnsInScope(for: context.tableReferences)
                items += SQLKeywords.functionItems()
                items += filterKeywords([
                    "DISTINCT", "ALL", "AS", "FROM", "CASE", "WHEN",
                    "INTO", "UNION", "INTERSECT", "EXCEPT"
                ])
            }

        case .on:
            // HP-3: ON clause — prioritize columns from joined tables
            items += await schemaProvider.allColumnsInScope(for: context.tableReferences)
            // Add qualified column suggestions (table.column) for join conditions
            for ref in context.tableReferences {
                let qualifier = ref.alias ?? ref.tableName
                let cols = await schemaProvider.columnCompletionItems(for: ref.tableName)
                for col in cols {
                    items.append(SQLCompletionItem(
                        label: "\(qualifier).\(col.label)",
                        kind: .column,
                        insertText: "\(qualifier).\(col.label)",
                        detail: col.detail,
                        documentation: "Column from \(ref.tableName)",
                        sortPriority: 80
                    ))
                }
            }
            items += SQLKeywords.operatorItems()
            items += filterKeywords([
                "AND", "OR", "NOT", "IS", "NULL", "TRUE", "FALSE"
            ])

        case .where_, .and, .having:
            // HP-8: Columns, operators, logical keywords + clause transitions
            items += await schemaProvider.allColumnsInScope(for: context.tableReferences)
            items += SQLKeywords.operatorItems()
            items += filterKeywords([
                "AND", "OR", "NOT", "IN", "LIKE", "ILIKE", "BETWEEN", "IS",
                "NULL", "NOT NULL", "TRUE", "FALSE", "EXISTS", "NOT EXISTS",
                "ANY", "ALL", "SOME", "REGEXP", "RLIKE", "SIMILAR TO",
                "IS NULL", "IS NOT NULL"
            ])
            items += SQLKeywords.functionItems()
            // Clause transitions after WHERE conditions
            items += filterKeywords([
                "ORDER BY", "GROUP BY", "HAVING", "LIMIT",
                "UNION", "INTERSECT", "EXCEPT"
            ])

        case .groupBy:
            // Columns + clause transitions
            items += await schemaProvider.allColumnsInScope(for: context.tableReferences)
            items += filterKeywords([
                "HAVING", "ORDER BY", "LIMIT",
                "UNION", "INTERSECT", "EXCEPT"
            ])

        case .orderBy:
            // Columns + sort direction + clause transitions
            items += await schemaProvider.allColumnsInScope(for: context.tableReferences)
            items += filterKeywords([
                "ASC", "DESC", "NULLS FIRST", "NULLS LAST",
                "LIMIT", "OFFSET",
                "UNION", "INTERSECT", "EXCEPT"
            ])

        case .set:
            // Columns for UPDATE SET clause + transition keywords
            if let firstTable = context.tableReferences.first {
                items = await schemaProvider.columnCompletionItems(for: firstTable.tableName)
            }
            items += filterKeywords(["WHERE", "RETURNING"])

        case .insertColumns:
            // Columns for INSERT column list
            if let firstTable = context.tableReferences.first {
                items = await schemaProvider.columnCompletionItems(for: firstTable.tableName)
            }

        case .values:
            // Functions and keywords for VALUES + post-values transitions
            items = SQLKeywords.functionItems()
            items += filterKeywords([
                "NULL", "DEFAULT", "TRUE", "FALSE",
                "ON CONFLICT", "ON DUPLICATE KEY UPDATE", "RETURNING"
            ])

        case .functionArg:
            // Inside function arguments - suggest columns and other functions
            let isCountFunction = context.currentFunction?.uppercased() == "COUNT"
            if isCountFunction {
                // COUNT() special: suggest * as top item
                var starItem = SQLCompletionItem(
                    label: "*",
                    kind: .keyword,
                    insertText: "*",
                    detail: String(localized: "All columns"),
                    documentation: String(localized: "Count all rows")
                )
                starItem.sortPriority = 10  // Highest priority
                items.append(starItem)
                // Boost DISTINCT for COUNT(DISTINCT ...)
                var distinctItem = SQLCompletionItem.keyword("DISTINCT")
                distinctItem.sortPriority = 20
                items.append(distinctItem)
            }
            items += await schemaProvider.allColumnsInScope(for: context.tableReferences)
            items += SQLKeywords.functionItems()
            if isCountFunction {
                // DISTINCT already added above with boosted priority
                items += filterKeywords(["NULL", "TRUE", "FALSE"])
            } else {
                items += filterKeywords(["NULL", "TRUE", "FALSE", "DISTINCT"])
            }

        case .caseExpression:
            // Inside CASE expression
            items += await schemaProvider.allColumnsInScope(for: context.tableReferences)
            items += filterKeywords(["WHEN", "THEN", "ELSE", "END", "AND", "OR", "IS", "NULL", "TRUE", "FALSE"])
            items += SQLKeywords.operatorItems()
            items += SQLKeywords.functionItems()

        case .inList:
            // Inside IN (...) list - suggest values, subqueries, columns
            items += await schemaProvider.allColumnsInScope(for: context.tableReferences)
            items += filterKeywords(["SELECT", "NULL", "TRUE", "FALSE"])
            items += SQLKeywords.functionItems()

        case .limit:
            // After LIMIT/OFFSET - typically just numbers, but could include variables
            items += filterKeywords(["OFFSET", "FETCH", "NEXT", "ROWS", "ONLY"])

        case .alterTable:
            // After ALTER TABLE tablename - suggest DDL operations and constraint types
            items = filterKeywords([
                "ADD", "DROP", "MODIFY", "CHANGE", "RENAME",
                "COLUMN", "INDEX", "PRIMARY", "FOREIGN", "KEY",
                "CONSTRAINT", "ENGINE", "CHARSET", "COLLATE", "AUTO_INCREMENT",
                "COMMENT", "DEFAULT", "CHARACTER SET",
                "PRIMARY KEY", "FOREIGN KEY", "UNIQUE", "CHECK",
            ])

        case .alterTableColumn:
            // After ALTER TABLE tablename DROP/MODIFY/CHANGE/RENAME or AFTER/BEFORE - suggest column names
            if let firstTable = context.tableReferences.first {
                items = await schemaProvider.columnCompletionItems(for: firstTable.tableName)
            }

        case .createTable:
            if context.nestingLevel >= 1 {
                // Inside CREATE TABLE (...) — column definitions
                // Boost FK-related keywords so they appear within the 20-item limit
                items = boostedKeywords([
                    "REFERENCES", "ON DELETE", "ON UPDATE",
                    "CASCADE", "RESTRICT", "SET NULL", "NO ACTION",
                ], priority: 300)
                items += filterKeywords([
                    "PRIMARY", "KEY", "FOREIGN", "UNIQUE",
                    "NOT", "NULL", "DEFAULT",
                    "AUTO_INCREMENT", "SERIAL",
                    "CHECK", "CONSTRAINT", "INDEX",
                ])
                items += dataTypeKeywords()
            } else {
                items = filterKeywords(["IF NOT EXISTS"])
                if let options = cachedDialect?.tableOptions {
                    items += filterKeywords(options)
                } else {
                    items += filterKeywords([
                        "ENGINE", "CHARSET", "COLLATE", "COMMENT", "TABLESPACE"
                    ])
                }
            }

        case .columnDef:
            // Typing column data type (after ADD COLUMN name)
            items = dataTypeKeywords()
            items += filterKeywords([
                "NOT", "NULL", "DEFAULT", "AUTO_INCREMENT", "SERIAL",
                "PRIMARY", "KEY", "UNIQUE", "REFERENCES", "CHECK",
                "UNSIGNED", "SIGNED", "FIRST", "AFTER", "COMMENT",
                "COLLATE", "CHARACTER SET", "ON UPDATE", "ON DELETE",
                "CASCADE", "RESTRICT", "SET NULL", "NO ACTION"
            ])

        case .returning:
            // After RETURNING (PostgreSQL) - suggest columns
            items += await schemaProvider.allColumnsInScope(for: context.tableReferences)
            items += filterKeywords(["*"])

        case .union:
            // After UNION/INTERSECT/EXCEPT - suggest SELECT
            items = filterKeywords(["SELECT", "ALL"])

        case .using:
            // After USING in JOIN - suggest columns
            items += await schemaProvider.allColumnsInScope(for: context.tableReferences)

        case .window:
            // After OVER/PARTITION BY - suggest columns and window keywords
            items += await schemaProvider.allColumnsInScope(for: context.tableReferences)
            items += filterKeywords([
                "PARTITION BY", "ORDER BY", "ASC", "DESC",
                "ROWS", "RANGE", "GROUPS", "BETWEEN", "UNBOUNDED",
                "PRECEDING", "FOLLOWING", "CURRENT ROW"
            ])

        case .dropObject:
            // After DROP TABLE/INDEX/VIEW - suggest tables
            items = await schemaProvider.tableCompletionItems()
            items += filterKeywords(["IF EXISTS", "CASCADE", "RESTRICT"])

        case .createIndex:
            if context.tableReferences.isEmpty {
                // Before ON tablename — suggest tables and ON keyword
                items = await schemaProvider.tableCompletionItems()
                items += filterKeywords(["ON"])
            } else {
                // After ON tablename (inside parens) — suggest columns
                items = await schemaProvider.allColumnsInScope(for: context.tableReferences)
                items += filterKeywords(["USING", "BTREE", "HASH", "GIN", "GIST"])
            }

        case .createView:
            // After CREATE VIEW - suggest SELECT
            items = filterKeywords(["SELECT", "AS"])
            items += await schemaProvider.tableCompletionItems()

        case .unknown:
            if !cachedStatementCompletions.isEmpty {
                items = cachedStatementCompletions.map { entry in
                    SQLCompletionItem(
                        label: entry.label,
                        kind: .keyword,
                        insertText: entry.insertText
                    )
                }
            } else {
                items = filterKeywords([
                    // DML
                    "SELECT", "INSERT", "UPDATE", "DELETE", "REPLACE", "MERGE", "UPSERT",
                    // DDL
                    "CREATE", "ALTER", "DROP", "TRUNCATE", "RENAME",
                    // Database operations
                    "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "ANALYZE",
                    // Transaction control
                    "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT", "START TRANSACTION",
                    // CTEs and advanced
                    "WITH", "RECURSIVE",
                    // Database/schema
                    "USE", "SET", "GRANT", "REVOKE",
                    // Utility
                    "CALL", "EXECUTE", "PREPARE"
                ])
            }
            items += await schemaProvider.tableCompletionItems()
        }

        return items
    }

    /// SQL data type keywords (database-aware), with a slight priority boost
    /// so they sort before generic constraint keywords in CREATE TABLE context.
    /// Uses plugin-provided dialect data when available; falls back to common SQL types.
    private func dataTypeKeywords() -> [SQLCompletionItem] {
        if let descriptor = cachedDialect, !descriptor.dataTypes.isEmpty {
            return descriptor.dataTypes.sorted().map { typeName in
                var item = SQLCompletionItem(label: typeName, kind: .keyword, insertText: typeName)
                item.sortPriority = 380
                return item
            }
        }

        let commonTypes: [String] = [
            "INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT",
            "DECIMAL", "NUMERIC", "FLOAT", "DOUBLE", "REAL",
            "VARCHAR", "CHAR", "TEXT",
            "DATE", "TIME", "DATETIME", "TIMESTAMP",
            "BOOLEAN", "BOOL",
            "BLOB", "JSON", "UUID"
        ]
        return commonTypes.map { typeName in
            var item = SQLCompletionItem.keyword(typeName)
            item.sortPriority = 380
            return item
        }
    }

    /// Filter to specific keywords
    private func filterKeywords(_ keywords: [String]) -> [SQLCompletionItem] {
        keywords.map { SQLCompletionItem.keyword($0) }
    }

    /// Create keyword items with boosted (lower) sort priority
    private func boostedKeywords(_ keywords: [String], priority: Int) -> [SQLCompletionItem] {
        keywords.map { kw in
            var item = SQLCompletionItem.keyword(kw)
            item.sortPriority = priority
            return item
        }
    }

    // MARK: - Filtering

    /// Filter and rank items by prefix, returning sorted results with match ranges
    func filterAndRank(_ items: [SQLCompletionItem], prefix: String, context: SQLContext) -> [SQLCompletionItem] {
        var filtered = filterByPrefix(items, prefix: prefix)
        // Clear stale match ranges before recomputing
        for i in filtered.indices { filtered[i].matchedRanges = [] }
        populateMatchRanges(&filtered, prefix: prefix)
        return rankResults(filtered, prefix: prefix, context: context)
    }

    /// Filter candidates by prefix (case-insensitive) with fuzzy matching support
    func filterByPrefix(_ items: [SQLCompletionItem], prefix: String) -> [SQLCompletionItem] {
        guard !prefix.isEmpty else { return items }

        let lowerPrefix = prefix.lowercased()

        return items.filter { item in
            // Exact prefix match
            if item.filterText.hasPrefix(lowerPrefix) {
                return true
            }

            // Contains match
            if item.filterText.contains(lowerPrefix) {
                return true
            }

            // Fuzzy match: check if all characters appear in order
            return fuzzyMatch(pattern: lowerPrefix, target: item.filterText)
        }
    }

    /// Fuzzy matching with scoring: returns penalty score (higher = worse),
    /// nil = no match. Uses NSString character-at-index for O(1) random
    /// access instead of Swift String indexing (LP-9).
    func fuzzyMatchScore(pattern: String, target: String) -> Int? {
        let nsPattern = pattern as NSString
        let nsTarget = target as NSString
        let patternLen = nsPattern.length
        let targetLen = nsTarget.length

        guard patternLen > 0, targetLen > 0 else { return nil }

        var patternIdx = 0
        var targetIdx = 0
        var gaps = 0
        var consecutiveMatches = 0
        var maxConsecutive = 0
        var lastMatchIdx = -1

        while patternIdx < patternLen && targetIdx < targetLen {
            let pChar = nsPattern.character(at: patternIdx)
            let tChar = nsTarget.character(at: targetIdx)

            if pChar == tChar {
                if lastMatchIdx == targetIdx - 1 {
                    consecutiveMatches += 1
                    maxConsecutive = max(maxConsecutive, consecutiveMatches)
                } else {
                    if lastMatchIdx >= 0 {
                        gaps += targetIdx - lastMatchIdx - 1
                    }
                    consecutiveMatches = 1
                }
                lastMatchIdx = targetIdx
                patternIdx += 1
            }
            targetIdx += 1
        }

        guard patternIdx == patternLen else { return nil }

        // Score: base penalty + gap penalty - consecutive bonus
        let basePenalty = 50
        let gapPenalty = gaps * 10
        let consecutiveBonus = maxConsecutive * 15
        return max(0, basePenalty + gapPenalty - consecutiveBonus)
    }

    /// Backward-compatible fuzzy matching (Bool) for filterByPrefix
    private func fuzzyMatch(pattern: String, target: String) -> Bool {
        fuzzyMatchScore(pattern: pattern, target: target) != nil
    }

    /// Fuzzy matching that returns both score and matched character indices
    private func fuzzyMatchWithIndices(pattern: String, target: String) -> (score: Int, indices: [Int])? {
        let nsPattern = pattern as NSString
        let nsTarget = target as NSString
        let patternLen = nsPattern.length
        let targetLen = nsTarget.length

        guard patternLen > 0, targetLen > 0 else { return nil }

        var patternIdx = 0
        var targetIdx = 0
        var gaps = 0
        var consecutiveMatches = 0
        var maxConsecutive = 0
        var lastMatchIdx = -1
        var matchedIndices: [Int] = []

        while patternIdx < patternLen && targetIdx < targetLen {
            let pChar = nsPattern.character(at: patternIdx)
            let tChar = nsTarget.character(at: targetIdx)

            if pChar == tChar {
                matchedIndices.append(targetIdx)
                if lastMatchIdx == targetIdx - 1 {
                    consecutiveMatches += 1
                    maxConsecutive = max(maxConsecutive, consecutiveMatches)
                } else {
                    if lastMatchIdx >= 0 {
                        gaps += targetIdx - lastMatchIdx - 1
                    }
                    consecutiveMatches = 1
                }
                lastMatchIdx = targetIdx
                patternIdx += 1
            }
            targetIdx += 1
        }

        guard patternIdx == patternLen else { return nil }

        let basePenalty = 50
        let gapPenalty = gaps * 10
        let consecutiveBonus = maxConsecutive * 15
        let score = max(0, basePenalty + gapPenalty - consecutiveBonus)
        return (score, matchedIndices)
    }

    /// Populate matchedRanges on each item based on how it matched the prefix
    private func populateMatchRanges(_ items: inout [SQLCompletionItem], prefix: String) {
        guard !prefix.isEmpty else { return }
        let lowerPrefix = prefix.lowercased()
        let nsPrefix = lowerPrefix as NSString

        for i in items.indices {
            let nsFilterText = items[i].filterText as NSString
            let prefixRange = nsFilterText.range(of: lowerPrefix, options: .anchored)
            if prefixRange.location != NSNotFound {
                items[i].matchedRanges = [0..<nsPrefix.length]
            } else {
                let containsRange = nsFilterText.range(of: lowerPrefix)
                if containsRange.location != NSNotFound {
                    items[i].matchedRanges = [containsRange.location..<(containsRange.location + containsRange.length)]
                } else if let result = fuzzyMatchWithIndices(pattern: lowerPrefix, target: items[i].filterText) {
                    items[i].matchedRanges = indicesToRanges(result.indices)
                }
            }
        }
    }

    /// Convert sorted individual character indices into contiguous ranges
    private func indicesToRanges(_ indices: [Int]) -> [Range<Int>] {
        guard !indices.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        var start = indices[0]
        var end = indices[0]
        for i in 1..<indices.count {
            if indices[i] == end + 1 {
                end = indices[i]
            } else {
                ranges.append(start..<(end + 1))
                start = indices[i]
                end = indices[i]
            }
        }
        ranges.append(start..<(end + 1))
        return ranges
    }

    // MARK: - Ranking

    /// Rank results by relevance
    func rankResults(_ items: [SQLCompletionItem], prefix: String, context: SQLContext) -> [SQLCompletionItem] {
        let lowerPrefix = prefix.lowercased()

        return items.sorted { a, b in
            let aScore = calculateScore(for: a, prefix: lowerPrefix, context: context)
            let bScore = calculateScore(for: b, prefix: lowerPrefix, context: context)
            return aScore < bScore // Lower score = higher priority
        }
    }

    /// Calculate ranking score for an item (lower = better)
    func calculateScore(for item: SQLCompletionItem, prefix: String, context: SQLContext) -> Int {
        var score = item.sortPriority

        // Exact prefix match bonus
        if item.filterText.hasPrefix(prefix) {
            score -= 500
        }

        // Exact match bonus
        if item.filterText == prefix {
            score -= 1_000
        }

        // When prefix is empty and tables are in scope, user is at a clause
        // transition point (e.g., "FROM users |" or "WHERE id > 1 |").
        // Boost keywords so they appear alongside context-specific items.
        if prefix.isEmpty && !context.tableReferences.isEmpty && !context.isAfterComma {
            if item.kind == .keyword {
                score -= 300
            }
        } else {
            // Context-appropriate bonuses when actively typing
            switch context.clauseType {
            case .from, .join, .into, .dropObject, .createIndex:
                if item.kind == .table || item.kind == .view {
                    score -= 200
                }
            case .select, .where_, .and, .on, .having, .groupBy, .orderBy,
                 .returning, .using, .window:
                if item.kind == .column {
                    score -= 200
                }
            case .set, .insertColumns:
                if item.kind == .column {
                    score -= 300
                }
            default:
                break
            }
        }

        // Shorter names slightly preferred
        score += (item.label as NSString).length

        // Fuzzy match penalty — items matched only by fuzzy get demoted
        if !prefix.isEmpty {
            let filterText = item.filterText
            if !filterText.hasPrefix(prefix) && !filterText.contains(prefix) {
                // This is a fuzzy-only match — apply penalty
                if let fuzzyPenalty = fuzzyMatchScore(pattern: prefix, target: filterText) {
                    score += fuzzyPenalty
                }
            }
        }

        return score
    }
}
