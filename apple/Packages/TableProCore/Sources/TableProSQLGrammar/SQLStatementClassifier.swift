import Foundation

/// Tiers SQL text by what the engine will run, not by how the text starts. Safe Mode on both apps and the Mac's
/// external gates ask it.
///
/// A gate question is asked of the whole text under every way the engine could lex it (``SQLLexicalReadings``), and
/// each reading splits the text into the statements that engine would see before any of them is tiered. The answer
/// is the worst over all of them. A text that hides a `DROP` behind a quote only one reading closes is therefore tiered
/// by that `DROP`. Every word is read as the grammar's tokens read it, never by a pattern over the text.
public enum SQLStatementClassifier {
    /// The tier of a statement an engine's driver runs in a request form of its own, or nil for SQL.
    public typealias RequestClassification = (_ statement: String, _ grammar: SQLLexicalGrammar) -> StatementClassification?

    /// Whether a request-form statement deletes every row, or nil for SQL.
    public typealias RequestDeletion = (_ statement: String, _ grammar: SQLLexicalGrammar) -> Bool?

    /// `isSettled` stops the read once nothing can change the answer, since a dump read under every server version is
    /// long.
    public static func classify(
        _ sql: String,
        databaseTypeId: String,
        readings: SQLLexicalReadings,
        request: RequestClassification? = nil,
        until isSettled: (StatementClassification) -> Bool = { $0 == .mostSevere }
    ) -> StatementClassification {
        SQLStatementTiering(databaseTypeId: databaseTypeId, readings: readings, request: request)
            .classify(sql, until: isSettled)
    }

    public static func isWrite(_ sql: String, databaseTypeId: String, readings: SQLLexicalReadings) -> Bool {
        classify(sql, databaseTypeId: databaseTypeId, readings: readings, until: { $0.tier != .safe }).tier != .safe
    }

    /// Whether some statement the text runs deletes every row of a table: a `DELETE` with no `WHERE` of its own.
    public static func deletesEveryRow(
        _ sql: String,
        databaseTypeId: String,
        readings: SQLLexicalReadings,
        request: RequestDeletion? = nil
    ) -> Bool {
        guard let lexings = readings.lexings(of: sql) else { return true }
        let tiering = SQLStatementTiering(databaseTypeId: databaseTypeId, readings: readings, request: nil)
        var seen: Set<SQLLexing> = []
        return lexings.contains { lexing in
            runnableStatements(of: lexing.text, grammar: lexing.grammar).contains { statement in
                guard seen.insert(SQLLexing(grammar: lexing.grammar, text: statement)).inserted else { return false }
                if let request, let answer = request(statement, lexing.grammar) { return answer }
                return tiering.statementDeletesEveryRow(statement, grammar: lexing.grammar)
            }
        }
    }

    /// The statements `grammar` splits `sql` into, as the driver would receive them.
    public static func statements(of sql: String, grammar: SQLLexicalGrammar) -> [String] {
        SQLStatementScanner.executableStatements(in: sql, grammar: grammar).map(\.sql)
    }

    /// Every text a gate tiers for `sql` under `grammar`: each statement, and each one an engine runs from inside it.
    public static func runnableStatements(of sql: String, grammar: SQLLexicalGrammar) -> [String] {
        statements(of: sql, grammar: grammar).flatMap { statement in
            SQLUnterminatedStatements.runnable(in: statement, grammar: grammar)
        }
    }
}

/// A statement beside its code projection and the grammar's tokens of that code, read once and handed to every rule.
struct StatementCode {
    let statement: String
    let text: NSString
    let code: String
    let tokens: [TSQLTokens.Token]
    let words: Set<String>

    init(_ statement: String, grammar: SQLLexicalGrammar) {
        self.statement = statement
        text = statement as NSString
        code = SQLCodeProjection.code(of: statement, grammar: grammar)
        tokens = TSQLTokens.read(text, code: code as NSString, grammar: grammar)
        words = Set(tokens.compactMap(\.word))
    }

    /// The word the statement opens with, past any parentheses, or empty when it opens with anything else.
    var keyword: String {
        tokens.first { $0.kind != .open }?.word ?? ""
    }

    func contains(_ word: String) -> Bool {
        words.contains(word)
    }

    func containsAny(_ candidates: Set<String>) -> Bool {
        !words.isDisjoint(with: candidates)
    }

    /// Whether `run` is spelled by consecutive tokens starting at `index`. A comment between two of them is nothing.
    func spells(_ run: [String], at index: Int) -> Bool {
        StatementCode.spells(run, at: index, in: tokens)
    }

    static func spells(_ run: [String], at index: Int, in tokens: [TSQLTokens.Token]) -> Bool {
        guard index + run.count <= tokens.count else { return false }
        return run.indices.allSatisfy { tokens[index + $0].word == run[$0] }
    }

    /// The first token after `index` that is not an opening parenthesis: `EXECUTE IMMEDIATE ('DROP TABLE t')` runs the
    /// literal inside.
    func operand(after index: Int) -> Int {
        var operand = index + 1
        while tokens.indices.contains(operand), tokens[operand].kind == .open {
            operand += 1
        }
        return operand
    }

    func isSymbol(_ symbol: UInt16, at index: Int) -> Bool {
        tokens.indices.contains(index) && tokens[index].kind == .other && text.character(at: tokens[index].location) == symbol
    }
}

struct SQLStatementTiering {
    let databaseTypeId: String
    let readings: SQLLexicalReadings
    let request: SQLStatementClassifier.RequestClassification?
    var rowChanges: Set<String>?

    // Each nested statement copies and reads what is left of the text, so nesting past this is refused.
    static let deepestNesting = 32

    func classify(_ sql: String, until isSettled: (StatementClassification) -> Bool) -> StatementClassification {
        guard let lexings = readings.lexings(of: sql) else { return .mostSevere }
        var worst = StatementClassification.safe
        var seen: Set<SQLLexing> = []
        for lexing in lexings {
            for statement in SQLStatementClassifier.runnableStatements(of: lexing.text, grammar: lexing.grammar)
            where seen.insert(SQLLexing(grammar: lexing.grammar, text: statement)).inserted {
                worst = worst.escalated(with: statementClassification(statement, grammar: lexing.grammar))
                if isSettled(worst) { return worst }
            }
        }
        return worst
    }

    func classify(_ sql: String) -> StatementClassification {
        classify(sql) { $0 == .mostSevere }
    }

    func statementClassification(_ statement: String, grammar: SQLLexicalGrammar) -> StatementClassification {
        if let request, let answer = request(statement, grammar) { return answer }
        if let batch = CQLBatch.statements(in: statement, grammar: grammar) {
            // A CQL batch writes whatever it holds, so it is never below a write.
            return batch.reduce(StatementClassification.write) { worst, inner in
                worst.escalated(with: statementClassification(inner, grammar: grammar))
            }
        }
        if SQLProceduralBlock.runs(statement, grammar: grammar) {
            return proceduralBlockClassification(statement, grammar: grammar)
        }
        return sqlClassification(statement, grammar: grammar)
    }

    func statementDeletesEveryRow(_ statement: String, grammar: SQLLexicalGrammar) -> Bool {
        if let batch = CQLBatch.statements(in: statement, grammar: grammar) {
            return batch.contains { statementDeletesEveryRow($0, grammar: grammar) }
        }
        if SQLProceduralBlock.runs(statement, grammar: grammar) {
            return proceduralBlockDeletesEveryRow(statement, grammar: grammar)
        }
        // With ANALYZE the engine runs what it explains, so the explained statement is read as the tier reads it.
        if let explain = SQLExplainStatement.read(statement, grammar: grammar) {
            guard case .explains(let start, true) = explain.reading else { return false }
            return statementDeletesEveryRow((statement as NSString).substring(from: start), grammar: grammar)
        }
        return SQLUnfilteredWrite.writes(in: statement, grammar: grammar).contains(.delete)
    }

    func sqlClassification(_ statement: String, grammar: SQLLexicalGrammar, depth: Int = 0) -> StatementClassification {
        guard depth <= Self.deepestNesting else { return .mostSevere }
        let code = StatementCode(statement, grammar: grammar)
        let calls = SQLFunctionCallScanner.calls(in: code.text, code: code.code as NSString)
        let touchesUnsafeSurface = Self.namesFilesystemSurface(code.tokens, in: code.code as NSString)
            || Self.callsFilesystemFunction(calls)
            || Self.quotesFilesystemProcedure(in: statement, grammar: grammar)
        var keywordTier = keywordClassification(code, grammar: grammar, depth: depth)
        if grammar.contains(.unterminatedStatements), SQLUnterminatedStatements.callsProcedure(opening: code.keyword) {
            keywordTier = keywordTier.escalated(to: .write)
        }
        let base = keywordTier.tier == .safe
            ? keywordTier.escalated(to: stateChangingCallTier(code, calls: calls, grammar: grammar))
            : keywordTier
        var classification = touchesUnsafeSurface ? base.markingUnsafeSurface() : base
        if reachesOutsideDatabase(code, calls: calls, grammar: grammar) {
            classification = classification.escalated(with: Self.readOutsideDatabase)
        }
        if let dynamic = dynamicSQLClassification(code, grammar: grammar, depth: depth) {
            classification = classification.escalated(with: dynamic)
        }
        if removesSurrealDefinition(code) {
            classification = classification.escalated(to: .destructive)
        }
        guard let conditional = Self.conditionalCommentClassification(statement, grammar: grammar) else {
            return classification
        }
        return classification.escalated(with: conditional)
    }
}

extension SQLStatementTiering {
    static let dataDroppingWords: Set<String> = ["DROP", "TRUNCATE"]

    /// MySQL's `PURGE BINARY LOGS` takes the logs a point-in-time restore needs, and Oracle's `PURGE` empties the
    /// recycle bin a dropped table is restored from.
    static let destructiveKeywords: Set<String> = dataDroppingWords.union(["PURGE"])

    // ClickHouse's `ALTER TABLE t CLEAR COLUMN c` resets the column's data.
    static let alterDestructiveWords: Set<String> = dataDroppingWords.union(["CLEAR"])

    // T-SQL's BULK INSERT reads a file on the server.
    static let filesystemOrCodeKeywords: Set<String> = [
        "COPY", "ATTACH", "DETACH", "DO", "LOAD", "INSTALL", "IMPORT", "EXPORT",
        "BACKUP", "RESTORE", "DUMP", "SOURCE", "UNLOAD", "BULK"
    ]

    static let writeKeywords: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "REPLACE", "MERGE", "UPSERT",
        "ALTER", "CREATE", "RENAME", "GRANT", "REVOKE", "COMMENT", "DENY",
        "CALL", "EXEC", "EXECUTE", "PREPARE", "DEALLOCATE",
        "SET", "RESET", "LOCK", "UNLOCK", "USE", "PRAGMA",
        "VACUUM", "REINDEX", "CLUSTER", "REFRESH", "ANALYZE", "OPTIMIZE", "REPAIR", "CHECK",
        "BEGIN", "START", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE", "END", "ABORT",
        "DECLARE", "FETCH", "CLOSE", "MOVE", "DISCARD", "CHECKPOINT", "FLUSH",
        "KILL", "SHUTDOWN", "MSCK", "BATCH", "APPLY",
        "DEFINE", "REMOVE", "RELATE", "LET", "SECURITY", "LISTEN", "UNLISTEN", "NOTIFY"
    ]

    static let readOnlyKeywords: Set<String> = ["SHOW", "HELP", "INFO", "PRINT"]

    static let queryKeywords: Set<String> = ["SELECT", "TABLE", "VALUES"]

    static let cteWriteWords: Set<String> = ["INSERT", "UPDATE", "DELETE", "MERGE"]

    static let duckDB = "DuckDB"
    static let clickHouse = "ClickHouse"
    static let surrealDB = "SurrealDB"

    // DuckDB reads with `FROM t`, `PIVOT t ...` and `UNPIVOT t ...` too.
    func isQuery(_ keyword: String) -> Bool {
        Self.queryKeywords.contains(keyword)
            || (databaseTypeId == Self.duckDB && ["FROM", "PIVOT", "UNPIVOT"].contains(keyword))
    }

    func keywordClassification(
        _ code: StatementCode,
        grammar: SQLLexicalGrammar,
        depth: Int = 0
    ) -> StatementClassification {
        guard depth <= Self.deepestNesting else { return .mostSevere }
        let keyword = code.keyword

        if SQLExplainStatement.keywords.contains(keyword) {
            return explainClassification(code, grammar: grammar, depth: depth)
        }
        if Self.filesystemOrCodeKeywords.contains(keyword) {
            return StatementClassification(tier: .write, reachesFilesystemOrExecutesCode: true)
        }
        if Self.destructiveKeywords.contains(keyword) || removesDefinition(code) || Self.resetsBinaryLogs(code) {
            return .destructive
        }
        if keyword == "CREATE" || keyword == "REPLACE", Self.replacesStoredData(code) {
            return .destructive
        }
        if keyword == "ALTER" {
            // `ALTER TABLE t TRUNCATE PARTITION ALL` empties the table, measured on MySQL 8.4.
            return code.containsAny(Self.alterDestructiveWords) ? .destructive : .write
        }
        if keyword == "WITH" {
            return commonTableExpressionClassification(code, grammar: grammar, depth: depth)
        }
        if isQuery(keyword) {
            return code.contains("INTO") ? .write : .safe
        }
        // `INSERT OVERWRITE` empties the table first on Snowflake, Databricks and Hive; Hive's `... DIRECTORY` writes files.
        if keyword == "INSERT", let verb = code.tokens.firstIndex(where: { $0.kind != .open }),
           code.tokens.indices.contains(verb + 1), code.tokens[verb + 1].word == "OVERWRITE" {
            return StatementClassification(tier: .destructive, reachesFilesystemOrExecutesCode: code.contains("DIRECTORY"))
        }
        if keyword == "VACUUM" {
            // SQLite's `VACUUM [schema] INTO 'file'` writes a file whatever stands between the two words.
            return StatementClassification(tier: .write, reachesFilesystemOrExecutesCode: code.contains("INTO"))
        }
        if Self.writeKeywords.contains(keyword) {
            return .write
        }
        if Self.readOnlyKeywords.contains(keyword) {
            return .safe
        }
        return .write
    }

    /// SurrealQL's `REMOVE TABLE`, `REMOVE DATABASE` and `REMOVE NAMESPACE` are what its driver sends for Drop, and
    /// Snowflake's `REMOVE @stage` and its `RM` alias delete staged files. A lone `REMOVE` is a field a SurrealQL reader
    /// cut out of a longer statement, which names nothing.
    private func removesDefinition(_ code: StatementCode) -> Bool {
        guard Self.removeKeywords.contains(code.keyword),
              let verb = code.tokens.firstIndex(where: { $0.word == code.keyword })
        else { return false }
        return code.tokens.indices.contains(verb + 1)
    }

    private static let removeKeywords: Set<String> = ["REMOVE", "RM"]

    /// SurrealQL runs a statement wherever it takes a value, as in `LET $gone = REMOVE TABLE orders`, and a reader
    /// cuts such a statement down to its first word. A `REMOVE` before what it removes is that statement; a field
    /// named `remove` never stands there.
    func removesSurrealDefinition(_ code: StatementCode) -> Bool {
        guard databaseTypeId == Self.surrealDB else { return false }
        return code.tokens.indices.contains { index in
            code.tokens[index].word == "REMOVE" && code.tokens.indices.contains(index + 1)
                && code.tokens[index + 1].word.map(Self.surrealRemovedKinds.contains) == true
        }
    }

    private static let surrealRemovedKinds: Set<String> = [
        "NAMESPACE", "NS", "DATABASE", "DB", "TABLE", "FIELD", "INDEX", "EVENT", "FUNCTION", "PARAM", "ANALYZER",
        "ACCESS", "USER", "TOKEN", "SCOPE", "MODEL", "SEQUENCE", "CONFIG", "API", "BUCKET", "MODULE",
    ]

    /// MySQL's `RESET MASTER` and 8.4's `RESET BINARY LOGS AND GTIDS` delete every binary log, as `PURGE` does, in any
    /// place of RESET's option list.
    static func resetsBinaryLogs(_ code: StatementCode) -> Bool {
        guard code.keyword == "RESET" else { return false }
        return code.contains("MASTER") || code.tokens.indices.contains { code.spells(["BINARY", "LOGS"], at: $0) }
    }

    // After the CTE list only a query reads. Each body is tiered as a statement of its own, since PostgreSQL runs a
    // data-modifying one, and a list this reader does not know is a write.
    func commonTableExpressionClassification(
        _ code: StatementCode,
        grammar: SQLLexicalGrammar,
        depth: Int
    ) -> StatementClassification {
        if code.containsAny(Self.dataDroppingWords) { return .destructive }
        var worst = code.containsAny(Self.cteWriteWords) ? StatementClassification.write : .safe
        guard let list = SQLCommonTableExpressions.read(code.statement, grammar: grammar) else {
            // Snowflake's `WITH p AS PROCEDURE ... CALL p()` creates and runs a procedure whose body is a literal.
            let definesRoutine = code.contains("PROCEDURE") || code.contains("FUNCTION")
            return definesRoutine ? StatementClassification.write.markingUnsafeSurface() : .write
        }
        let main = StatementCode(code.text.substring(from: list.mainStatement), grammar: grammar)
        if !isQuery(main.keyword) {
            worst = worst.escalated(with: .write)
        }
        let parts = [main] + list.bodies.map { StatementCode(code.text.substring(with: $0), grammar: grammar) }
        return parts.reduce(worst) { worst, part in
            worst.escalated(with: keywordClassification(part, grammar: grammar, depth: depth + 1))
        }
    }

    // An EXPLAIN, a DESCRIBE of a statement or a bare ANALYZE runs nothing unless an option runs it. A bare ANALYZE
    // of a name, and MySQL's or Oracle's ANALYZE TABLE, store statistics.
    func explainClassification(
        _ code: StatementCode,
        grammar: SQLLexicalGrammar,
        depth: Int
    ) -> StatementClassification {
        guard let explain = SQLExplainStatement.read(code.statement, grammar: grammar) else { return .write }
        switch explain.reading {
        case .unreadable:
            return .write
        case .describesObject:
            return explain.keyword == "ANALYZE" ? .write : .safe
        case .explains(let start, let runsStatement):
            let statement = code.text.substring(from: start)
            let inner = sqlClassification(statement, grammar: grammar, depth: depth + 1)
            if explain.keyword == "ANALYZE", StatementCode(statement, grammar: grammar).keyword == "TABLE" {
                return inner.escalated(to: .write)
            }
            // Oracle's `EXPLAIN PLAN INTO t FOR ...` inserts the plan into `t`, and MySQL's `EXPLAIN ... INTO @v` sets
            // a variable.
            if code.tokens.contains(where: { $0.location < start && $0.word == "INTO" }) {
                return inner.escalated(to: .write)
            }
            guard runsStatement else {
                return StatementClassification(
                    tier: .safe,
                    reachesFilesystemOrExecutesCode: inner.reachesFilesystemOrExecutesCode
                )
            }
            return inner
        }
    }

    private static let replacedDataKinds: Set<String> = ["TABLE", "SCHEMA", "DATABASE"]

    private static let replacedObjectKinds: Set<String> = [
        "VIEW", "FUNCTION", "PROCEDURE", "PROC", "TRIGGER", "PACKAGE", "TYPE", "SEQUENCE", "MACRO", "INDEX", "SYNONYM",
    ]

    // Modifiers such as `GLOBAL TEMPORARY` or DuckDB's `UNLOGGED` stand before the kind, two words at most.
    private static let replacedKindLookahead = 3

    /// `CREATE OR REPLACE TABLE t` drops `t` and its rows before it makes the new one on Snowflake, BigQuery, DuckDB,
    /// MariaDB, ClickHouse and Databricks, and a replaced schema or database takes every table in it. ClickHouse's
    /// `REPLACE TABLE` is the same statement. A replaced view or routine loses no rows.
    static func replacesStoredData(_ code: StatementCode) -> Bool {
        let words = code.tokens.prefix(3 + replacedKindLookahead).map(\.word)
        let kindStart: Int
        if StatementCode.spells(["CREATE", "OR", "REPLACE"], at: 0, in: code.tokens) {
            kindStart = 3
        } else if code.tokens.first?.word == "REPLACE" {
            kindStart = 1
        } else {
            return false
        }
        for candidate in words.dropFirst(kindStart).prefix(replacedKindLookahead) {
            guard let word = candidate else { return false }
            if replacedDataKinds.contains(word) { return true }
            if replacedObjectKinds.contains(word) { return false }
        }
        return false
    }

    private static let routineDefinitionKinds: Set<String> = [
        "PROCEDURE", "PROC", "FUNCTION", "TRIGGER", "PACKAGE", "TYPE", "EVENT", "BODY"
    ]

    /// Words that stand between `CREATE` and the kind it defines without saying what that kind is.
    private static let routineDefinitionFillers: Set<String> = [
        "OR", "REPLACE", "ALTER", "DEFINER", "EDITIONABLE", "NONEDITIONABLE", "AGGREGATE", "TEMP", "TEMPORARY",
        "GLOBAL", "PUBLIC", "SECURE", "SQL", "SECURITY", "SET", "SESSION"
    ]

    private static let routineDefinitionLookahead = 3

    /// A routine's body is not run by the statement that stores it, so a definition is tiered by what storing it does,
    /// as #2988 settled for PL/SQL units: a write whose effect the text does not show.
    static func definesRoutine(_ code: StatementCode) -> Bool {
        var words = code.tokens.lazy.compactMap(\.word).makeIterator()
        guard let first = words.next(), first == "CREATE" || first == "ALTER" else { return false }
        var seen = 0
        while let word = words.next(), seen < routineDefinitionLookahead {
            if routineDefinitionKinds.contains(word) { return true }
            if routineDefinitionFillers.contains(word) { continue }
            seen += 1
        }
        return false
    }
}
