import Foundation
import TableProSQLGrammar

public final class SQLCompletionProvider {
    private let contextAnalyzer = SQLContextAnalyzer()
    private let catalog: (any SQLCompletionCatalog)?
    private var grammar: SQLLexicalGrammar
    private var vocabulary: SQLCompletionVocabulary
    private var cachedFunctionItems: [SQLCompletionItem]?
    private var favoriteKeywords: [String: (name: String, query: String)] = [:]

    private let defaultMaxSuggestions = 20

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

    public init(catalog: (any SQLCompletionCatalog)?, grammar: SQLLexicalGrammar, vocabulary: SQLCompletionVocabulary) {
        self.catalog = catalog
        self.grammar = grammar
        self.vocabulary = vocabulary
    }

    public func update(grammar: SQLLexicalGrammar, vocabulary: SQLCompletionVocabulary) {
        self.grammar = grammar
        self.vocabulary = vocabulary
        self.cachedFunctionItems = nil
    }

    public func updateFavoriteKeywords(_ keywords: [String: (name: String, query: String)]) {
        self.favoriteKeywords = keywords
    }

    // `forcedTableReferences` stands in for the FROM clause when the caller already knows the table, as a
    // single-table filter expression does.
    public func getCompletions(
        text: String,
        cursorPosition: Int,
        forcedTableReferences: [TableReference]? = nil
    ) async -> (items: [SQLCompletionItem], context: SQLContext) {
        let session = await completionSession(
            text: text,
            cursorPosition: cursorPosition,
            forcedTableReferences: forcedTableReferences
        )
        return (session.items, session.context)
    }

    // `items` is what the popup shows; `candidates` is the wider pool it re-ranks while it stays open.
    public func completionSession(
        text: String,
        cursorPosition: Int,
        forcedTableReferences: [TableReference]? = nil
    ) async -> (items: [SQLCompletionItem], candidates: [SQLCompletionItem], context: SQLContext) {
        var context = contextAnalyzer.analyze(query: text, cursorPosition: cursorPosition, grammar: grammar)
        if let forcedTableReferences {
            context = context.replacingTableReferences(forcedTableReferences)
        }

        if context.isInsideString || context.isInsideComment {
            return ([], [], context)
        }

        var candidates = await getCandidates(for: context)

        if !context.prefix.isEmpty {
            candidates = filterByPrefix(candidates, prefix: context.prefix)
        }

        candidates = rankResults(candidates, prefix: context.prefix, context: context)

        let limit = maxSuggestions(for: context.clauseType)

        return (Array(candidates.prefix(limit)), Array(candidates.prefix(sessionPool(for: limit))), context)
    }

    // A candidate cut at the opening prefix can never lead for a longer one, and PostgreSQL declares more `T`
    // functions than the popup shows rows, every one outranking `TRUE` for the letter `t`.
    public func filterRankAndLimit(
        _ items: [SQLCompletionItem],
        prefix: String,
        context: SQLContext
    ) -> [SQLCompletionItem] {
        Array(filterAndRank(items, prefix: prefix, context: context).prefix(maxSuggestions(for: context.clauseType)))
    }

    // Ranking is linear in the pool: measured 36us for 40 candidates, 340us for 400 and 4ms for 5,000.
    private func sessionPool(for limit: Int) -> Int { limit * 10 }

    private func functionItems() -> [SQLCompletionItem] {
        if let cachedFunctionItems { return cachedFunctionItems }
        var items = SQLKeywords.functionItems()
        if !vocabulary.functions.isEmpty {
            let folding: SQLCompletionCaseFolding =
                vocabulary.functionNamesAreCaseInsensitive ? .caseInsensitive : .fixed
            var seen = Set(items.map { $0.label.uppercased() })
            for name in vocabulary.functions.sorted() where seen.insert(name.uppercased()).inserted {
                items.append(SQLCompletionItem.function(name, signature: "\(name)(…)", caseFolding: folding))
            }
        }
        cachedFunctionItems = items
        return items
    }

    // MARK: - Candidate Generation

    private func getCandidates( // swiftlint:disable:this function_body_length
        for context: SQLContext
    ) async -> [SQLCompletionItem] {
        var items: [SQLCompletionItem] = []

        // A dot prefix is a table or alias first, then a schema (its tables) or a database (its schemas). The
        // namespace fallback also covers an alias that resolves to a schema name parsed out of the FROM clause.
        if let dotPrefix = context.dotPrefix {
            guard let catalog else { return [] }
            if let derived = context.tableReferences.first(where: {
                $0.isDerived && $0.identifier.caseInsensitiveCompare(dotPrefix) == .orderedSame
            }), let columns = derived.derivedColumns, !columns.isEmpty {
                return columns.map { SQLCompletionItem.column($0, dataType: nil, tableName: derived.identifier) }
            }
            if let tableName = await catalog.resolveAlias(dotPrefix, in: context.tableReferences) {
                let schema = context.tableReferences.first {
                    $0.tableName.caseInsensitiveCompare(tableName) == .orderedSame
                }?.schema
                items = await catalog.columnCompletionItems(for: tableName, schema: schema)
            }
            if items.isEmpty {
                if await catalog.isKnownSchema(dotPrefix) {
                    items = await catalog.tableCompletionItems(inSchema: dotPrefix)
                } else if await catalog.isKnownDatabase(dotPrefix) {
                    items = await catalog.schemaCompletionItems()
                }
            }
            return items
        }

        switch context.clauseType {
        case .from, .join:
            items = await catalog?.tableCompletionItems() ?? []
            items += await catalog?.namespaceCompletionItems() ?? []
            items += filterKeywords([
                "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN",
                "LEFT OUTER JOIN", "RIGHT OUTER JOIN", "FULL OUTER JOIN",
                "CROSS JOIN", "NATURAL JOIN", "JOIN",
                "ON", "USING", "WHERE", "ORDER BY", "GROUP BY", "HAVING", "LIMIT",
                "UNION", "INTERSECT", "EXCEPT"
            ])

        case .into:
            items = await catalog?.tableCompletionItems() ?? []
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
                let upperFunc = funcName.uppercased()
                if upperFunc == "COUNT" {
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
                items += await columnItems(for: context.tableReferences)
                items += functionItems()
                items += filterKeywords(["NULL", "TRUE", "FALSE"])
                if funcName.uppercased() != "COUNT" {
                    items += filterKeywords(["DISTINCT"])
                }
            } else {
                items.append(SQLCompletionItem(
                    label: "*",
                    kind: .keyword,
                    insertText: "*",
                    detail: "All columns",
                    sortPriority: 50
                ))
                for ref in context.tableReferences {
                    let qualifier = ref.alias ?? ref.tableName
                    items.append(SQLCompletionItem(
                        label: "\(qualifier).*",
                        kind: .keyword,
                        insertText: "\(qualifier).*",
                        detail: "All columns from \(ref.tableName)",
                        sortPriority: 60,
                        identifier: SQLCompletionIdentifier([Self.qualifierPart(for: ref), .statement("*", quoted: false)])
                    ))
                }
                items += await columnItems(for: context.tableReferences)
                items += functionItems()
                items += filterKeywords([
                    "DISTINCT", "ALL", "AS", "FROM", "CASE", "WHEN",
                    "INTO", "UNION", "INTERSECT", "EXCEPT"
                ])
            }

        case .on:
            items += await allowedValueItems(for: context)
            items += await columnItems(for: context.tableReferences)
            for ref in context.tableReferences {
                let qualifier = ref.alias ?? ref.tableName
                let cols = await catalog?.columnCompletionItems(for: ref.tableName, schema: ref.schema) ?? []
                for col in cols {
                    items.append(SQLCompletionItem(
                        label: "\(qualifier).\(col.label)",
                        kind: .column,
                        insertText: "\(qualifier).\(col.label)",
                        detail: col.detail,
                        documentation: "Column from \(ref.tableName)",
                        sortPriority: 80,
                        identifier: col.identifier.map {
                            SQLCompletionIdentifier([Self.qualifierPart(for: ref)] + $0.parts)
                        }
                    ))
                }
            }
            items += SQLKeywords.operatorItems()
            items += dialectOperatorItems()
            items += filterKeywords([
                "AND", "OR", "NOT", "IS", "NULL", "TRUE", "FALSE"
            ])
            // Once the join condition is written, the next keyword would otherwise only fuzzy-match columns.
            items += filterKeywords([
                "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN",
                "LEFT OUTER JOIN", "RIGHT OUTER JOIN", "FULL OUTER JOIN",
                "CROSS JOIN", "NATURAL JOIN", "JOIN",
                "WHERE", "ORDER BY", "GROUP BY", "HAVING", "LIMIT",
                "UNION", "INTERSECT", "EXCEPT"
            ])

        case .where_, .and, .having:
            items += await allowedValueItems(for: context)
            items += await columnItems(for: context.tableReferences)
            items += SQLKeywords.operatorItems()
            items += dialectOperatorItems()
            items += filterKeywords([
                "AND", "OR", "NOT", "IN", "LIKE", "ILIKE", "BETWEEN", "IS",
                "NULL", "NOT NULL", "TRUE", "FALSE", "EXISTS", "NOT EXISTS",
                "ANY", "ALL", "SOME", "REGEXP", "RLIKE", "SIMILAR TO",
                "IS NULL", "IS NOT NULL"
            ])
            items += functionItems()
            items += filterKeywords([
                "ORDER BY", "GROUP BY", "HAVING", "LIMIT",
                "UNION", "INTERSECT", "EXCEPT"
            ])

        case .groupBy:
            items += await columnItems(for: context.tableReferences)
            items += filterKeywords([
                "HAVING", "ORDER BY", "LIMIT",
                "UNION", "INTERSECT", "EXCEPT"
            ])

        case .orderBy:
            items += await columnItems(for: context.tableReferences)
            items += filterKeywords([
                "ASC", "DESC", "NULLS FIRST", "NULLS LAST",
                "LIMIT", "OFFSET",
                "UNION", "INTERSECT", "EXCEPT"
            ])

        case .set:
            if let firstTable = context.tableReferences.first {
                items = await catalog?.columnCompletionItems(for: firstTable.tableName, schema: firstTable.schema) ?? []
            }
            items += filterKeywords(["WHERE", "RETURNING"])

        case .insertColumns:
            if let firstTable = context.tableReferences.first {
                items = await catalog?.columnCompletionItems(for: firstTable.tableName, schema: firstTable.schema) ?? []
            }

        case .values:
            items = functionItems()
            items += filterKeywords([
                "NULL", "DEFAULT", "TRUE", "FALSE",
                "ON CONFLICT", "ON DUPLICATE KEY UPDATE", "RETURNING"
            ])

        case .functionArg:
            let isCountFunction = context.currentFunction?.uppercased() == "COUNT"
            if isCountFunction {
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
            items += await columnItems(for: context.tableReferences)
            items += functionItems()
            if isCountFunction {
                items += filterKeywords(["NULL", "TRUE", "FALSE"])
            } else {
                items += filterKeywords(["NULL", "TRUE", "FALSE", "DISTINCT"])
            }

        case .caseExpression:
            items += await columnItems(for: context.tableReferences)
            items += filterKeywords(["WHEN", "THEN", "ELSE", "END", "AND", "OR", "IS", "NULL", "TRUE", "FALSE"])
            items += SQLKeywords.operatorItems()
            items += dialectOperatorItems()
            items += functionItems()

        case .inList:
            items += await columnItems(for: context.tableReferences)
            items += filterKeywords(["SELECT", "NULL", "TRUE", "FALSE"])
            items += functionItems()

        case .limit:
            items += filterKeywords(["OFFSET", "FETCH", "NEXT", "ROWS", "ONLY"])

        case .alterTable:
            items = filterKeywords([
                "ADD", "DROP", "MODIFY", "CHANGE", "RENAME",
                "COLUMN", "INDEX", "PRIMARY", "FOREIGN", "KEY",
                "CONSTRAINT", "ENGINE", "CHARSET", "COLLATE", "AUTO_INCREMENT",
                "COMMENT", "DEFAULT", "CHARACTER SET",
                "PRIMARY KEY", "FOREIGN KEY", "UNIQUE", "CHECK",
            ])

        case .alterTableColumn:
            if let firstTable = context.tableReferences.first {
                items = await catalog?.columnCompletionItems(for: firstTable.tableName, schema: firstTable.schema) ?? []
            }

        case .createTable:
            if context.nestingLevel >= 1 {
                // Boosted so the foreign key keywords fit inside the 20-item limit.
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
                if let options = vocabulary.tableOptions {
                    items += filterKeywords(options)
                } else {
                    items += filterKeywords([
                        "ENGINE", "CHARSET", "COLLATE", "COMMENT", "TABLESPACE"
                    ])
                }
            }

        case .columnDef:
            items = dataTypeKeywords()
            items += filterKeywords([
                "NOT", "NULL", "DEFAULT", "AUTO_INCREMENT", "SERIAL",
                "PRIMARY", "KEY", "UNIQUE", "REFERENCES", "CHECK",
                "UNSIGNED", "SIGNED", "FIRST", "AFTER", "COMMENT",
                "COLLATE", "CHARACTER SET", "ON UPDATE", "ON DELETE",
                "CASCADE", "RESTRICT", "SET NULL", "NO ACTION"
            ])

        case .returning:
            items += await columnItems(for: context.tableReferences)
            items += filterKeywords(["*"])

        case .union:
            items = filterKeywords(["SELECT", "ALL"])

        case .using:
            items += await columnItems(for: context.tableReferences)

        case .window:
            items += await columnItems(for: context.tableReferences)
            items += filterKeywords([
                "PARTITION BY", "ORDER BY", "ASC", "DESC",
                "ROWS", "RANGE", "GROUPS", "BETWEEN", "UNBOUNDED",
                "PRECEDING", "FOLLOWING", "CURRENT ROW"
            ])

        case .dropObject:
            items = await catalog?.tableCompletionItems() ?? []
            items += filterKeywords(["IF EXISTS", "CASCADE", "RESTRICT"])

        case .createIndex:
            if context.tableReferences.isEmpty {
                items = await catalog?.tableCompletionItems() ?? []
                items += filterKeywords(["ON"])
            } else {
                items = await columnItems(for: context.tableReferences)
                items += filterKeywords(["USING", "BTREE", "HASH", "GIN", "GIST"])
            }

        case .createView:
            items = filterKeywords(["SELECT", "AS"])
            items += await catalog?.tableCompletionItems() ?? []

        case .castTarget:
            items = castTargetCompletionItems()

        case .unknown:
            items = statementStartCompletionItems()
            items += await catalog?.tableCompletionItems() ?? []
        }

        items += favoriteCompletions(matching: context.prefix)

        return items
    }

    private func favoriteCompletions(matching prefix: String) -> [SQLCompletionItem] {
        guard !prefix.isEmpty, !favoriteKeywords.isEmpty else { return [] }
        let lowerPrefix = prefix.lowercased()
        return favoriteKeywords
            .filter { $0.key.lowercased().hasPrefix(lowerPrefix) }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { SQLCompletionItem.favorite(keyword: $0.key, name: $0.value.name, query: $0.value.query) }
    }

    private func allowedValueItems(for context: SQLContext) async -> [SQLCompletionItem] {
        guard let column = context.comparisonColumn, let catalog else { return [] }

        let values = await catalog.allowedValues(forColumn: column, in: context.tableReferences)
        return values.map { value in
            var item = SQLCompletionItem(
                label: "'\(value)'",
                kind: .keyword,
                insertText: "'\(value)'",
                detail: column,
                filterText: value.lowercased()
            )
            item.sortPriority = 10
            return item
        }
    }

    // Case-insensitive like any keyword: PostgreSQL declares `IS DISTINCT FROM` and `BETWEEN SYMMETRIC` here too.
    private func dialectOperatorItems() -> [SQLCompletionItem] {
        vocabulary.operators.map { operatorDescriptor in
            SQLCompletionItem(
                label: operatorDescriptor.symbol,
                kind: .operator,
                insertText: operatorDescriptor.symbol,
                detail: operatorDescriptor.appliesToTypes.isEmpty
                    ? nil
                    : operatorDescriptor.appliesToTypes.joined(separator: ", "),
                documentation: operatorDescriptor.summary,
                caseFolding: .caseInsensitive
            )
        }
    }

    // Lower case and fixed after `::`, the cast convention, unlike the spelling CREATE TABLE offers.
    private func castTargetCompletionItems() -> [SQLCompletionItem] {
        guard !vocabulary.dataTypes.isEmpty else { return [] }
        return vocabulary.dataTypes.sorted().map { typeName in
            let lowercased = typeName.lowercased()
            var item = SQLCompletionItem(label: lowercased, kind: .keyword, insertText: lowercased)
            item.sortPriority = 300
            return item
        }
    }

    // Boosted so data types sort before the generic constraint keywords in CREATE TABLE.
    private func dataTypeKeywords() -> [SQLCompletionItem] {
        if !vocabulary.dataTypes.isEmpty {
            return vocabulary.dataTypes.sorted().map { typeName in
                var item = SQLCompletionItem(
                    label: typeName,
                    kind: .keyword,
                    insertText: typeName,
                    caseFolding: .caseInsensitive
                )
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

    private func columnItems(for references: [TableReference]) async -> [SQLCompletionItem] {
        if references.isEmpty {
            return await catalog?.allColumnsFromCachedTables() ?? []
        }
        return await catalog?.allColumnsInScope(for: references) ?? []
    }

    // A reference is spelled as the statement wrote it, and stays quoted when it was, or it would fold to another name.
    public static func qualifierPart(for reference: TableReference) -> SQLCompletionIdentifier.Part {
        .statement(reference.identifier, quoted: reference.isIdentifierQuoted)
    }

    private func filterKeywords(_ keywords: [String]) -> [SQLCompletionItem] {
        keywords.map { SQLCompletionItem.keyword($0) }
    }

    private static let statementStartKeywords = [
        "SELECT", "INSERT", "UPDATE", "DELETE", "REPLACE", "MERGE", "UPSERT",
        "CREATE", "ALTER", "DROP", "TRUNCATE", "RENAME",
        "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "ANALYZE",
        "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT", "START TRANSACTION",
        "WITH", "RECURSIVE",
        "USE", "SET", "GRANT", "REVOKE",
        "CALL", "EXECUTE", "PREPARE"
    ]

    public func statementStartCompletionItems() -> [SQLCompletionItem] {
        guard vocabulary.statementCompletions.isEmpty else {
            return vocabulary.statementCompletions.map { entry in
                SQLCompletionItem(
                    label: entry.label,
                    kind: .keyword,
                    insertText: entry.insertText
                )
            }
        }
        return filterKeywords(Self.statementStartKeywords)
    }

    private func boostedKeywords(_ keywords: [String], priority: Int) -> [SQLCompletionItem] {
        keywords.map { kw in
            var item = SQLCompletionItem.keyword(kw)
            item.sortPriority = priority
            return item
        }
    }

    // MARK: - Filtering

    public func filterAndRank(_ items: [SQLCompletionItem], prefix: String, context: SQLContext) -> [SQLCompletionItem] {
        let filtered = filterByPrefix(items, prefix: prefix)
        return rankResults(filtered, prefix: prefix, context: context)
    }

    // Resolves `matchedRanges` and the fuzzy-only `fuzzyPenalty` once per candidate, so ranking never matches again.
    // Both are assigned rather than accumulated, so filtering a filtered list is idempotent.
    public func filterByPrefix(_ items: [SQLCompletionItem], prefix: String) -> [SQLCompletionItem] {
        guard !prefix.isEmpty else {
            var reset = items
            for i in reset.indices {
                reset[i].matchedRanges = []
                reset[i].fuzzyPenalty = 0
            }
            return reset
        }

        let lowerPrefix = prefix.lowercased()
        let nsPrefix = lowerPrefix as NSString

        var kept: [SQLCompletionItem] = []
        kept.reserveCapacity(items.count)

        for var item in items {
            let nsFilterText = item.filterText as NSString

            if nsFilterText.range(of: lowerPrefix, options: .anchored).location != NSNotFound {
                item.matchedRanges = [0..<nsPrefix.length]
                item.fuzzyPenalty = 0
            } else if let containsRange = optionalRange(of: lowerPrefix, in: nsFilterText) {
                item.matchedRanges = [containsRange]
                item.fuzzyPenalty = 0
            } else if let resolution = resolveFuzzyMatch(pattern: lowerPrefix, target: item.filterText) {
                item.matchedRanges = indicesToRanges(resolution.indices)
                item.fuzzyPenalty = resolution.penalty
            } else {
                continue
            }

            kept.append(item)
        }

        return kept
    }

    private func optionalRange(of substring: String, in target: NSString) -> Range<Int>? {
        let range = target.range(of: substring)
        guard range.location != NSNotFound else { return nil }
        return range.location..<(range.location + range.length)
    }

    private func resolveFuzzyMatch(pattern: String, target: String) -> (penalty: Int, indices: [Int])? {
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
        matchedIndices.reserveCapacity(min(patternLen, targetLen))

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
        let penalty = max(0, basePenalty + gapPenalty - consecutiveBonus)
        return (penalty, matchedIndices)
    }

    // Higher is worse; nil is no match.
    public func fuzzyMatchScore(pattern: String, target: String) -> Int? {
        resolveFuzzyMatch(pattern: pattern, target: target)?.penalty
    }

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

    // Scores once per candidate rather than in the comparator. Equal scores keep the order the generator emitted,
    // which carries meaning: the standard library's sort is not stable.
    public func rankResults(_ items: [SQLCompletionItem], prefix: String, context: SQLContext) -> [SQLCompletionItem] {
        let lowerPrefix = prefix.lowercased()
        let scored = items.enumerated().map { position, item in
            (position: position, item: item, score: calculateScore(for: item, prefix: lowerPrefix, context: context))
        }

        return scored.sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.position < rhs.position : lhs.score < rhs.score
        }.map(\.item)
    }

    // Lower is better.
    public func calculateScore(for item: SQLCompletionItem, prefix: String, context: SQLContext) -> Int {
        var score = item.sortPriority + item.fuzzyPenalty

        if item.filterText.hasPrefix(prefix) {
            score -= 500
        }

        if item.filterText == prefix {
            score -= 1_000
        }

        // With nothing typed and tables in scope, tables lead in an operand slot (`... JOIN |`) and keywords lead at
        // a clause transition (`FROM users |`).
        if prefix.isEmpty && !context.tableReferences.isEmpty && !context.isAfterComma {
            if context.expectsObjectName {
                if item.kind == .table || item.kind == .view || item.kind == .schema {
                    score -= 300
                }
            } else if item.kind == .keyword {
                score -= 300
            }
        } else {
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

        score += (item.label as NSString).length

        return score
    }
}
