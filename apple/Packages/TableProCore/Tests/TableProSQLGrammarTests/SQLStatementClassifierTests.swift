import Foundation
import TableProSQLGrammar
import Testing

struct SQLStatementClassifierTests {
    private static func classify(_ sql: String, _ engine: String) -> StatementClassification {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: engine, declared: nil, session: nil)
        return SQLStatementClassifier.classify(sql, databaseTypeId: engine, readings: readings)
    }

    private static func tier(_ sql: String, _ engine: String) -> StatementTier {
        classify(sql, engine).tier
    }

    @Test("SurrealQL's REMOVE drops what it names, wherever the statement stands", arguments: [
        "REMOVE TABLE person",
        "remove table if exists person;",
        "REMOVE DATABASE shop",
        "REMOVE NAMESPACE acme",
        "REMOVE FIELD email ON TABLE person",
        "-- tidy up\nREMOVE TABLE person",
        "IF true { REMOVE TABLE person }",
        "RETURN (REMOVE TABLE person)",
        "LET $gone = REMOVE TABLE orders",
    ])
    func surrealRemoveIsDestructive(sql: String) {
        #expect(Self.tier(sql, "SurrealDB") == .destructive)
    }

    @Test("A SurrealQL field named remove is a field")
    func surrealFieldNamedRemoveIsNotARemove() {
        #expect(Self.tier("UPDATE person SET remove = true", "SurrealDB") == .write)
    }

    @Test("Snowflake's REMOVE deletes staged files, and PURGE takes what a restore needs", arguments: [
        ("Snowflake", "REMOVE @my_stage/orders/"),
        ("Snowflake", "REMOVE@my_stage"),
        ("Snowflake", "RM @my_stage/orders/"),
        ("MySQL", "PURGE BINARY LOGS BEFORE NOW()"),
        ("MySQL", "RESET MASTER"),
        ("MySQL", "RESET BINARY LOGS AND GTIDS"),
        ("MySQL", "RESET REPLICA, MASTER"),
        ("MariaDB", "RESET QUERY CACHE, MASTER"),
        ("Oracle", "PURGE RECYCLEBIN"),
    ])
    func removeAndPurgeAreDestructive(engine: String, sql: String) {
        #expect(Self.tier(sql, engine) == .destructive)
    }

    @Test("An ALTER that drops is destructive however the DROP is spaced", arguments: [
        ("SQLite", "ALTER TABLE t\nDROP COLUMN c"),
        ("SQLite", "ALTER TABLE t\r\nDROP COLUMN c"),
        ("PostgreSQL", "ALTER TABLE t\tDROP COLUMN c"),
        ("PostgreSQL", "ALTER TABLE t/**/DROP COLUMN c"),
        ("MySQL", "ALTER TABLE t ADD c INT,DROP COLUMN d"),
        ("MySQL", "ALTER TABLE t\nTRUNCATE PARTITION ALL"),
        ("Oracle", "ALTER TABLE t DROP(c)"),
        ("ClickHouse", "ALTER TABLE t DROP\nPARTITION '2024'"),
        ("ClickHouse", "ALTER TABLE t CLEAR COLUMN c IN PARTITION '2024'"),
        ("SQL Server", "ALTER TABLE t DROP\u{0001}COLUMN c"),
    ])
    func alterDropIsDestructiveHoweverSpaced(engine: String, sql: String) {
        #expect(Self.tier(sql, engine) == .destructive)
    }

    @Test("An ALTER that only names something like a drop stays a write", arguments: [
        "ALTER TABLE t ADD dropped INT",
        "ALTER TABLE t ADD drop_count INT",
        "ALTER TABLE t ADD COLUMN \"drop\" INT",
        "ALTER TABLE t ADD COLUMN note TEXT DEFAULT 'drop'",
    ])
    func alterNamingADropStaysAWrite(sql: String) {
        #expect(Self.tier(sql, "PostgreSQL") == .write)
    }

    @Test("An INTO glued to a number is an INTO, and a name ending in INTO is a name")
    func intoIsReadByTheGrammarsWordRule() {
        for sql in ["SELECT name, 1INTO users_copy FROM users", "SELECT 1e1INTO t2", "SELECT 1.e1INTO t2",
                    "SELECT .5INTO t2", "SELECT 0x1INTO t2", "SELECT $1INTO t2"] {
            #expect(Self.tier(sql, "SQL Server") == .write, "\(sql)")
            #expect(Self.tier(sql, "PostgreSQL") == .write, "\(sql)")
        }
        #expect(Self.tier("SELECT a1into, x_into, _1into, a$into, t1.e1into FROM t1", "SQL Server") == .safe)
    }

    @Test("A file word pair counts only as two words of its own")
    func fileWordPairsAreWords() {
        #expect(!Self.classify("INSERT INTO program VALUES (1)", "PostgreSQL").reachesFilesystemOrExecutesCode)
        #expect(Self.classify("SELECT * FROM t INTO/**/OUTFILE '/tmp/t'", "MySQL").reachesFilesystemOrExecutesCode)
        #expect(Self.classify("EXEC master..xp_cmdshell 'dir'", "SQL Server").reachesFilesystemOrExecutesCode)
        #expect(!Self.classify("SELECT * FROM my_xp_cmdshell_log", "SQL Server").reachesFilesystemOrExecutesCode)
    }

    @Test("A sequence advance is read across a comment or a control character", arguments: [
        ("SQL Server", "SELECT NEXT/**/VALUE FOR orders_seq"),
        ("SQL Server", "SELECT NEXT\u{0001}VALUE FOR orders_seq"),
        ("Oracle", "SELECT orders_seq . NEXTVAL FROM dual"),
    ])
    func sequenceAdvanceIsAWrite(engine: String, sql: String) {
        #expect(Self.tier(sql, engine) == .write)
    }

    @Test("An @ glued to a keyword ends the word outside T-SQL", arguments: [
        ("Oracle", "SELECT orders_seq.NEXTVAL@remote_db FROM dual", StatementTier.write),
        ("MySQL", "SELECT id INTO@v FROM users LIMIT 1", StatementTier.write),
        ("SQL Server", "SELECT c@into FROM t", StatementTier.safe),
    ])
    func atSignEndsAWordOutsideTSQL(engine: String, sql: String, tier: StatementTier) {
        #expect(Self.tier(sql, engine) == tier)
    }

    @Test("A file or network reach behind an @ is still flagged", arguments: [
        ("SurrealDB", "SELECT * FROM article WHERE body @@http::get('http://10.0.0.5/admin')"),
        ("SQLite", "VACUUM INTO@path"),
    ])
    func atSignDoesNotHideASurface(engine: String, sql: String) {
        #expect(Self.classify(sql, engine).reachesFilesystemOrExecutesCode)
    }

    @Test("A file or code procedure spelled with a letter outside ASCII is still flagged", arguments: [
        ("Oracle", "SELECT utl_\u{0131}naddr.get_host_address('x.example') FROM dual"),
        ("SQL Server", "EXEC master..xp_cmd\u{017F}hell 'whoami'"),
        ("SQL Server", "EXEC xp_cmd\u{017F}hell\u{200C} 'dir'"),
    ])
    func foldedProcedureNamesAreFlagged(engine: String, sql: String) {
        #expect(Self.classify(sql, engine).reachesFilesystemOrExecutesCode)
    }

    @Test("An EXPLAIN that writes its plan somewhere is a write", arguments: [
        ("Oracle", "EXPLAIN PLAN INTO plan_tbl FOR SELECT 1 FROM dual"),
        ("MySQL", "EXPLAIN FORMAT=JSON INTO @plan SELECT 1"),
    ])
    func explainIntoIsAWrite(engine: String, sql: String) {
        #expect(Self.tier(sql, engine) == .write)
    }

    @Test("A dynamic statement is read through a national prefix or parentheses", arguments: [
        ("Oracle", "BEGIN EXECUTE IMMEDIATE N'DROP TABLE t'; END;"),
        ("Oracle", "BEGIN EXECUTE IMMEDIATE ('DROP TABLE t'); END;"),
        ("Snowflake", "EXECUTE IMMEDIATE ('DROP TABLE t')"),
    ])
    func dynamicLiteralIsRead(engine: String, sql: String) {
        #expect(Self.tier(sql, engine) == .destructive)
    }

    @Test("A variable or parameter named where filters nothing", arguments: [
        ("MySQL", "DELETE FROM t ORDER BY @where"),
        ("SQLite", "DELETE FROM t RETURNING @where"),
        ("SQLite", "DELETE FROM t RETURNING #where"),
    ])
    func whereAsAVariableIsNotAFilter(engine: String, sql: String) {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: engine, declared: nil, session: nil)
        #expect(SQLStatementClassifier.deletesEveryRow(sql, databaseTypeId: engine, readings: readings))
    }

    @Test("A plugin grammar that needs no ; reads @ as part of a name, as T-SQL does")
    func undeclaredTSQLNamesStayNames() {
        let readings = SQLLexicalReadings.single([.unterminatedStatements])
        let classification = SQLStatementClassifier.classify(
            "SELECT @then DELETE FROM t", databaseTypeId: "Sybase", readings: readings
        )
        #expect(classification.tier == .write)
    }

    @Test("EXECUTE IMMEDIATE runs its literal however a comment spaces it")
    func executeImmediateReadsItsLiteral() {
        let classification = Self.classify("EXECUTE /* go */ IMMEDIATE /* now */ 'DROP TABLE orders'", "Snowflake")
        #expect(classification.tier == .destructive)
        #expect(classification.reachesFilesystemOrExecutesCode)
    }

    @Test("A PL/SQL DELETE whose WHERE touches a parenthesis is filtered")
    func plsqlWhereNextToAParenthesisFilters() {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "Oracle", declared: nil, session: nil)
        let filtered = "BEGIN DELETE FROM orders WHERE(id = 1); END;"
        let unfiltered = "BEGIN DELETE FROM orders; END;"
        #expect(!SQLStatementClassifier.deletesEveryRow(filtered, databaseTypeId: "Oracle", readings: readings))
        #expect(SQLStatementClassifier.deletesEveryRow(unfiltered, databaseTypeId: "Oracle", readings: readings))
    }
}
