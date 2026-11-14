import Foundation

public extension SQLStatementClassifier {
    // Whether a request-form statement only reads or changes rows, or nil for SQL.
    typealias RequestDataStatement = (_ statement: String, _ grammar: SQLLexicalGrammar) -> Bool?

    // Whether every statement `sql` runs, under every way the engine could lex it, only reads or changes rows. A
    // request form `requestIsData` cannot read, but `request` tiers, is refused.
    // `rowChanges` replaces the SQL words that change rows on an engine whose language reads as SQL but differs there:
    // SurrealQL's CREATE and RELATE make records.
    static func isDataStatement(
        _ sql: String,
        databaseTypeId: String,
        readings: SQLLexicalReadings,
        request: RequestClassification? = nil,
        requestIsData: RequestDataStatement? = nil,
        rowChanges: Set<String>? = nil
    ) -> Bool {
        guard let lexings = readings.lexings(of: sql) else { return false }
        var tiering = SQLStatementTiering(databaseTypeId: databaseTypeId, readings: readings, request: request)
        tiering.rowChanges = rowChanges
        var seen: Set<SQLLexing> = []
        return lexings.allSatisfy { lexing in
            runnableStatements(of: lexing.text, grammar: lexing.grammar).allSatisfy { statement in
                guard seen.insert(SQLLexing(grammar: lexing.grammar, text: statement)).inserted else { return true }
                if let answer = requestIsData?(statement, lexing.grammar) { return answer }
                if let request, request(statement, lexing.grammar) != nil { return false }
                return tiering.isDataStatement(statement, grammar: lexing.grammar)
            }
        }
    }

    // Whether an unqualified table lands in a schema whose tables the server acts on. Oracle and Dameng name the
    // session's schema after the user, so SYSTEM there is a login with tables of its own; SYS is the dictionary.
    static func isSystemScope(database: String?, schema: String?, databaseTypeId: String) -> Bool {
        let schemas = SQLStatementTiering.systemSchemas(for: databaseTypeId)
        let namesUser = databaseTypeId == "Oracle" || databaseTypeId == "Dameng"
        let readSchema = namesUser ? schema.flatMap { $0.uppercased() == "SYS" ? $0 : nil } : schema
        return [database, readSchema].contains { $0.map { schemas.contains($0.uppercased()) } == true }
    }
}

extension SQLStatementTiering {
    static let rowChangeKeywords: Set<String> = ["INSERT", "UPDATE", "DELETE", "MERGE", "UPSERT"]

    // `REPLACE [LOW_PRIORITY | DELAYED] INTO t`. ClickHouse's `REPLACE TABLE` and Teradata's `REPLACE VIEW` define.
    static let replaceRowWords: Set<String> = ["INTO", "LOW_PRIORITY", "DELAYED"]

    // MySQL makes INTO optional in `REPLACE t VALUES (...)`.
    static let mySQLFamily: Set<String> = ["MySQL", "MariaDB", "TiDB", "OceanBase"]

    static let postgreSQLFamily: Set<String> = ["PostgreSQL", "CockroachDB", "PGlite", "KingbaseES", "Redshift"]

    // An UPDATE of `pg_settings` runs SET; KingbaseES names its catalog `sys_` as well.
    static func systemRelationPrefixes(for databaseTypeId: String) -> [String] {
        guard postgreSQLFamily.contains(databaseTypeId) else { return [] }
        return databaseTypeId == "KingbaseES" ? ["PG_", "SYS_"] : ["PG_"]
    }

    // SQL Server's msdb holds the SQL Agent jobs it runs.
    static func systemSchemas(for databaseTypeId: String) -> Set<String> {
        if mySQLFamily.contains(databaseTypeId) { return ["MYSQL", "PERFORMANCE_SCHEMA", "SYS"] }
        switch databaseTypeId {
        case "KingbaseES": return ["PG_CATALOG", "SYS_CATALOG"]
        case "CockroachDB": return ["PG_CATALOG", "SYSTEM", "CRDB_INTERNAL"]
        case "PostgreSQL", "PGlite", "Redshift": return ["PG_CATALOG"]
        case "SQL Server": return ["MSDB"]
        case "Oracle": return ["SYS", "SYSTEM"]
        case "Dameng": return ["SYS"]
        case "ClickHouse": return ["SYSTEM"]
        // A row change there passes the server's MODIFY check: `UPDATE system_auth.roles SET is_superuser = true`,
        // ScyllaDB's `system.roles` and its live `system.config`, Cassandra's writable `system_views` cache tables.
        case "Cassandra": return cassandraSystemKeyspaces
        // ScyllaDB 2026.1 writes its table audit backend to `audit.audit_log`, which the server does not mark internal.
        case "ScyllaDB": return cassandraSystemKeyspaces.union(["AUDIT"])
        default: return []
        }
    }

    static let cassandraSystemKeyspaces: Set<String> = [
        "SYSTEM", "SYSTEM_SCHEMA", "SYSTEM_AUTH", "SYSTEM_DISTRIBUTED", "SYSTEM_DISTRIBUTED_EVERYWHERE",
        "SYSTEM_TRACES", "SYSTEM_VIEWS", "SYSTEM_VIRTUAL_SCHEMA", "SYSTEM_REPLICATED_KEYS",
    ]

    // A ClickHouse ALTER action that is not a row change, after a comma at the statement's depth.
    static let clickHouseAlterActions: Set<String> = [
        "ADD", "DROP", "MODIFY", "RENAME", "CLEAR", "COMMENT", "MATERIALIZE", "FREEZE", "UNFREEZE", "ATTACH", "DETACH",
        "MOVE", "REPLACE", "FETCH", "RESET", "REMOVE", "APPLY",
    ]

    func isDataStatement(_ statement: String, grammar: SQLLexicalGrammar) -> Bool {
        // A SurrealQL stored body tiers as a read, as any unlisted call does, but what it runs is not read.
        if callsSurrealStoredCode(StatementCode(statement, grammar: grammar)) { return false }
        if statementClassification(statement, grammar: grammar).tier == .safe { return true }
        if let batch = CQLBatch.statements(in: statement, grammar: grammar) {
            return batch.allSatisfy { isDataStatement($0, grammar: grammar) }
        }
        guard !SQLProceduralBlock.runs(statement, grammar: grammar) else { return false }
        return changesOnlyRows(StatementCode(statement, grammar: grammar), grammar: grammar, depth: 0)
    }

    private func changesOnlyRows(_ code: StatementCode, grammar: SQLLexicalGrammar, depth: Int) -> Bool {
        guard depth <= Self.deepestNesting else { return false }
        let calls = SQLFunctionCallScanner.calls(in: code.text, code: code.code as NSString)
        guard !changesSessionOrServer(code, calls: calls, grammar: grammar),
              dynamicSQLClassification(code, grammar: grammar, depth: depth) == nil,
              Self.conditionalCommentClassification(code.statement, grammar: grammar) == nil
        else { return false }
        if SQLExplainStatement.keywords.contains(code.keyword) {
            return explainedStatementChangesOnlyRows(code, grammar: grammar, depth: depth)
        }
        if code.keyword == "WITH" {
            return commonTableExpressionsChangeOnlyRows(code, grammar: grammar, depth: depth)
        }
        return keywordChangesOnlyRows(code, grammar: grammar)
    }

    // A plain EXPLAIN already read as safe; what is left runs its statement, writes its plan or stores statistics.
    private func explainedStatementChangesOnlyRows(_ code: StatementCode, grammar: SQLLexicalGrammar, depth: Int) -> Bool {
        guard let explain = SQLExplainStatement.read(code.statement, grammar: grammar),
              case .explains(let start, true) = explain.reading,
              !code.tokens.contains(where: { $0.location < start && $0.word == "INTO" })
        else { return false }
        let explained = StatementCode(code.text.substring(from: start), grammar: grammar)
        if explain.keyword == "ANALYZE", explained.keyword == "TABLE" { return false }
        return changesOnlyRows(explained, grammar: grammar, depth: depth + 1)
    }

    private func commonTableExpressionsChangeOnlyRows(
        _ code: StatementCode,
        grammar: SQLLexicalGrammar,
        depth: Int
    ) -> Bool {
        guard depth <= Self.deepestNesting,
              let list = SQLCommonTableExpressions.read(code.statement, grammar: grammar)
        else { return false }
        let main = StatementCode(code.text.substring(from: list.mainStatement), grammar: grammar)
        let bodies = list.bodies.map { StatementCode(code.text.substring(with: $0), grammar: grammar) }
        return ([main] + bodies).allSatisfy { part in
            part.keyword == "WITH"
                ? commonTableExpressionsChangeOnlyRows(part, grammar: grammar, depth: depth + 1)
                : keywordChangesOnlyRows(part, grammar: grammar)
        }
    }

    private func keywordChangesOnlyRows(_ code: StatementCode, grammar: SQLLexicalGrammar) -> Bool {
        let keyword = code.keyword
        // `SELECT ... INTO` makes a table on PostgreSQL and SQL Server, and sets a variable on MySQL.
        if isQuery(keyword) { return !code.contains("INTO") }
        let changesRows: Bool
        if keyword == "REPLACE" {
            changesRows = Self.mySQLFamily.contains(databaseTypeId)
                || Self.word(after: keyword, in: code).map(Self.replaceRowWords.contains) == true
        } else if keyword == "ALTER" {
            changesRows = databaseTypeId == Self.clickHouse && Self.changesClickHouseRows(code)
        } else {
            changesRows = (rowChanges ?? Self.rowChangeKeywords).contains(keyword)
                && !Self.updatesStatistics(code) && !Self.insertsProcedureResults(code)
        }
        return changesRows && !namesSystemRelation(code, grammar: grammar)
    }

    // A call that sets the session, signals the server or runs work elsewhere, which a SELECT or an INSERT can carry. A
    // sequence's next value is a row's key, so it passes.
    private func changesSessionOrServer(
        _ code: StatementCode,
        calls: [SQLFunctionCallScanner.Call],
        grammar: SQLLexicalGrammar
    ) -> Bool {
        let callsOne = calls.contains { call in
            guard case .named(let name, _) = call.callee else { return true }
            if SQLStateChangingFunctions.sequences.contains(name.uppercased().lowercased()) { return false }
            return SQLStateChangingFunctions.contains(name)
                || (databaseTypeId == Self.duckDB && SQLStateChangingFunctions.isDuckDBCall(name))
        }
        return callsOne
            || SQLStateChangingFunctions.namesStateChangingTable(in: code.text, tokens: code.tokens, grammar: grammar)
    }

    // Any qualifier naming a system schema, or on the PostgreSQL family any `pg_` relation, since an unqualified one
    // resolves to pg_catalog first. A row change that only reads one in a subquery is refused too.
    private func namesSystemRelation(_ code: StatementCode, grammar: SQLLexicalGrammar) -> Bool {
        let schemas = Self.systemSchemas(for: databaseTypeId)
        let prefixes = Self.systemRelationPrefixes(for: databaseTypeId)
        guard !schemas.isEmpty || !prefixes.isEmpty else { return false }
        return code.tokens.indices.contains { index in
            if !prefixes.isEmpty, Self.spellsEscapedName(at: index, in: code) { return true }
            guard let name = Self.identifier(at: index, in: code, grammar: grammar) else { return false }
            if schemas.contains(name), code.isSymbol(Self.period, at: index + 1) { return true }
            let isCall = code.tokens.indices.contains(index + 1) && code.tokens[index + 1].kind == .open
            return !isCall && prefixes.contains(where: name.hasPrefix)
        }
    }

    // A word, or the name inside an identifier quote, in capitals.
    private static func identifier(at index: Int, in code: StatementCode, grammar: SQLLexicalGrammar) -> String? {
        let token = code.tokens[index]
        if let word = token.word { return word }
        guard token.kind == .quoted,
              let span = SQLNonCodeSpan.span(at: token.location, in: code.text, grammar: grammar),
              identifierQuotes.contains(code.text.character(at: span.start))
        else { return nil }
        let inner = NSRange(location: span.start + 1, length: max(0, span.contentEnd - span.start - 1))
        return code.text.substring(with: inner).uppercased()
    }

    // PostgreSQL's `U&"pg\005fsettings"` spells a name in escapes this reader does not decode: the word U, then `&`,
    // then the quoted name, with nothing between them.
    private static func spellsEscapedName(at index: Int, in code: StatementCode) -> Bool {
        let tokens = code.tokens
        return index >= 2 && tokens[index].kind == .quoted && tokens[index - 2].word == "U"
            && code.isSymbol(ampersand, at: index - 1)
            && tokens[index - 1].location == tokens[index - 2].location + 1
            && tokens[index].location == tokens[index - 1].location + 1
    }

    private static let ampersand = UInt16(UnicodeScalar("&").value)

    private static func word(after keyword: String, in code: StatementCode) -> String? {
        guard let verb = code.tokens.firstIndex(where: { $0.word == keyword }),
              code.tokens.indices.contains(verb + 1)
        else { return nil }
        return code.tokens[verb + 1].word
    }

    // `ALTER TABLE t [ON CLUSTER c] UPDATE ... WHERE` and `... DELETE WHERE` are the row changes ClickHouse's grid
    // writes with. Any other action in the same ALTER defines.
    private static func changesClickHouseRows(_ code: StatementCode) -> Bool {
        let tokens = code.tokens
        guard let verb = tokens.firstIndex(where: { $0.word == "ALTER" }),
              tokens.indices.contains(verb + 2), tokens[verb + 1].word == "TABLE"
        else { return false }
        let depth = tokens[verb].depth
        var index = verb + 2
        while tokens.indices.contains(index + 2), code.isSymbol(period, at: index + 1) {
            index += 2
        }
        index += 1
        if tokens.indices.contains(index + 2), tokens[index].word == "ON", tokens[index + 1].word == "CLUSTER" {
            index += 3
        }
        guard tokens.indices.contains(index), tokens[index].word == "UPDATE" || tokens[index].word == "DELETE" else {
            return false
        }
        return !tokens.indices.dropFirst(index + 1).contains { later in
            tokens[later].kind == .comma && tokens[later].depth == depth && tokens.indices.contains(later + 1)
                && tokens[later + 1].word.map(clickHouseAlterActions.contains) == true
        }
    }

    // T-SQL's `UPDATE STATISTICS t` rebuilds statistics. A table named statistics is followed by SET, and T-SQL's own
    // reader cuts that SET off as a statement of its own.
    private static func updatesStatistics(_ code: StatementCode) -> Bool {
        guard code.keyword == "UPDATE",
              let verb = code.tokens.firstIndex(where: { $0.word == "UPDATE" }),
              code.tokens.indices.contains(verb + 1), code.tokens[verb + 1].word == "STATISTICS"
        else { return false }
        return !(code.tokens.indices.contains(verb + 2) && code.tokens[verb + 2].word == "SET")
    }

    // T-SQL's `INSERT INTO t EXEC proc` runs the procedure and stores what it returns.
    private static func insertsProcedureResults(_ code: StatementCode) -> Bool {
        guard code.keyword == "INSERT" else { return false }
        return code.tokens.contains { $0.depth == 0 && ($0.word == "EXEC" || $0.word == "EXECUTE") }
    }
}
