import Foundation
import TableProSQLGrammar
import Testing

struct SQLUnfilteredWriteTests {
    private static func grammar(_ typeId: String) -> SQLLexicalGrammar {
        SQLLexicalReadings.resolve(databaseTypeId: typeId, declared: nil, session: nil).execution
    }

    private static let postgreSQL = grammar("PostgreSQL")
    private static let sqlServer = grammar("SQL Server")
    private static let clickHouse = grammar("ClickHouse")
    private static let mySQL = grammar("MySQL")

    private func first(_ sql: String, _ grammar: SQLLexicalGrammar = postgreSQL) -> SQLUnfilteredWrite? {
        SQLUnfilteredWrite.writes(in: sql, grammar: grammar).first
    }

    @Test("An UPDATE or DELETE with no WHERE is found", arguments: [
        ("UPDATE t SET a = 1", SQLUnfilteredWrite.update),
        ("update \"t\" set \"a\" = $1", .update),
        ("DELETE FROM t", .delete),
        ("delete from \"s\".\"t\";", .delete),
        ("UPDATE t SET a = (SELECT b FROM u WHERE u.id = 1)", .update),
        ("DELETE FROM t WHERE_x = 1", .delete),
        ("WITH c AS (SELECT id FROM u WHERE id > 1) DELETE FROM t", .delete),
        ("UPDATE t SET a = t.where", .update),
    ])
    func unfiltered(sql: String, expected: SQLUnfilteredWrite) {
        #expect(first(sql) == expected)
    }

    @Test("A WHERE the engine never reads as code does not count", arguments: [
        "UPDATE t SET a = 1 -- WHERE id = 1",
        "UPDATE t SET a = 1 /* WHERE id = 1 */",
        "UPDATE t SET a = ' WHERE id = 1 '",
        "UPDATE t SET \" WHERE \" = 1",
        "DELETE FROM t -- WHERE id = 1",
        "DELETE FROM \"t WHERE id = 1\"",
    ])
    func whereOutsideCode(sql: String) {
        #expect(first(sql) != nil)
    }

    @Test("A statement with a WHERE of its own passes", arguments: [
        "UPDATE t SET a = 1 WHERE id = 1",
        "update t set a = 1\nwhere id = 1",
        "DELETE FROM t WHERE(id = 1)",
        "DELETE FROM \"t\" WHERE \"id\" = $1 OR \"id\" = $2",
        "UPDATE t SET a = (SELECT 1) WHERE id = 1 RETURNING *",
        "WITH c AS (SELECT 1) UPDATE t SET a = 1 WHERE id = 1",
        "INSERT INTO t (a) VALUES (1)",
        "SELECT * FROM t",
    ])
    func filtered(sql: String) {
        #expect(first(sql) == nil)
    }

    @Test("Every statement in the text is read")
    func everyStatementIsRead() {
        #expect(first("UPDATE t SET a = 1 WHERE id = 1; DELETE FROM t") == .delete)
        #expect(first("DELETE FROM t WHERE id = 1; UPDATE t SET a = 1 WHERE id = 2") == nil)
        #expect(SQLUnfilteredWrite.writes(in: "UPDATE t SET a = 1; DELETE FROM t", grammar: Self.postgreSQL)
            == [.update, .delete])
    }

    @Test("A common table expression named like a verb is not the statement")
    func commonTableExpressionNames() {
        #expect(first("WITH delete AS (SELECT 1) SELECT * FROM delete") == nil)
        #expect(first("WITH merge AS (SELECT 1) DELETE FROM items") == .delete)
        #expect(first("WITH RECURSIVE update (n) AS (SELECT 1), b AS MATERIALIZED (SELECT 2) UPDATE t SET a = 1")
            == .update)
        #expect(first("WITH a AS NOT MATERIALIZED (SELECT 1) DELETE FROM t WHERE id IN (SELECT * FROM a)") == nil)
    }

    @Test("A common table expression that writes is read as the write it is")
    func dataModifyingCommonTableExpression() {
        #expect(first("WITH gone AS (DELETE FROM items RETURNING *) SELECT * FROM gone") == .delete)
        #expect(first("WITH gone AS (DELETE FROM items WHERE id = 1 RETURNING *) SELECT * FROM gone") == nil)
        #expect(first("WITH a AS (SELECT 1), b AS (UPDATE t SET c = 1 RETURNING c) SELECT * FROM b") == .update)
    }

    private static let walk = "WITH RECURSIVE a(id) AS (SELECT 1 UNION ALL SELECT id + 1 FROM a WHERE id < 2)"

    @Test("A writing common table expression is read wherever it stands in the list", arguments: [
        "WITH U&\"gone\" AS (DELETE FROM items RETURNING *) SELECT 1",
        "WITH gone\u{20AC} AS (DELETE FROM items RETURNING *) SELECT 1",
        "WITH \u{20AC}as (id) AS (DELETE FROM items RETURNING id) SELECT 1",
        "\(walk) SEARCH DEPTH FIRST BY id SET ord, gone AS (DELETE FROM items RETURNING *) SELECT 1",
        "\(walk) CYCLE id SET looped USING path, gone AS MATERIALIZED (DELETE FROM items RETURNING *) SELECT 1",
    ])
    func writingExpressionAnywhereInTheList(sql: String) {
        #expect(first(sql) == .delete)
    }

    @Test("A name the engine reads as one word and T-SQL as several is not the statement", arguments: [
        "WITH merge\u{20AC} AS (SELECT 1) DELETE FROM t",
        "WITH update\u{20AC} AS (SELECT 1) DELETE FROM t",
        "WITH c\u{A0}select AS (SELECT 1) DELETE FROM t",
        "WITH \u{20AC}as AS (SELECT 1), merge AS (SELECT 1) DELETE FROM t",
        "WITH 1merge AS (SELECT 1) DELETE FROM t",
    ])
    func nameOfSeveralTokens(sql: String) {
        #expect(SQLUnfilteredWrite.writes(in: sql, grammar: Self.grammar("SQLite")).contains(.delete))
        #expect(SQLUnfilteredWrite.writes(in: sql, grammar: Self.mySQL).contains(.delete))
        #expect(first(sql + " WHERE id = 1", Self.grammar("SQLite")) == nil)
    }

    @Test("A SEARCH or CYCLE clause is not the statement")
    func searchAndCycleClauses() {
        #expect(first("\(Self.walk) SEARCH BREADTH FIRST BY id SET merge DELETE FROM items") == .delete)
        #expect(first("\(Self.walk) CYCLE id SET c USING merge DELETE FROM items") == .delete)
        #expect(first("\(Self.walk) CYCLE id SET c USING p DELETE FROM items WHERE id IN (SELECT id FROM a)") == nil)
        #expect(first("\(Self.walk) SEARCH DEPTH FIRST BY id SET ord SELECT * FROM a") == nil)
    }

    @Test("A WHERE the engine reads as a name, or as part of one, is not the statement's", arguments: [
        ("DELETE FROM orders AS o\u{A0}WHERE\u{A0}id\u{A0}IS\u{A0}NULL", "SQLite"),
        ("DELETE FROM t AS \u{20AC}where", "SQLite"),
        ("DELETE FROM t AS where\u{20AC}", "SQLite"),
        ("DELETE FROM t x\u{200B}where", "PostgreSQL"),
        ("DELETE FROM t RETURNING id AS where", "PostgreSQL"),
        ("DELETE FROM t RETURNING id AS /* label */ where", "PostgreSQL"),
        ("DELETE FROM t AS 1where", "MySQL"),
        ("DELETE x\u{660}where FROM t AS x\u{660}where", "SQL Server"),
    ])
    func whereInsideAName(sql: String, typeId: String) {
        #expect(first(sql, Self.grammar(typeId)) == .delete)
    }

    @Test("A name outside ASCII that ends before the WHERE leaves it the statement's own")
    func whereAfterANameOutsideASCII() {
        #expect(first("DELETE FROM t AS \u{20AC} WHERE id = 1", Self.grammar("SQLite")) == nil)
        #expect(first("DELETE FROM \"\u{20AC}\"WHERE id = 1 RETURNING id AS where") == nil)
        #expect(first("UPDATE t SET a = 1, b = 2 WHERE \u{E9}t\u{E9} = 1") == nil)
    }

    @Test("Only T-SQL's maintenance command is spelled UPDATE STATISTICS without a SET")
    func tableNamedStatistics() {
        #expect(first("UPDATE statistics SET value = 1") == .update)
        #expect(first("UPDATE statistics SET value = 1 WHERE id = 1") == nil)
    }

    @Test("A bind parameter named where is not a WHERE")
    func parameterNamedWhere() {
        let sqlite = Self.grammar("SQLite")
        #expect(first("DELETE FROM t RETURNING :where", sqlite) == .delete)
        #expect(first("DELETE FROM t RETURNING $where", sqlite) == .delete)
        #expect(first("DELETE FROM t WHERE id = :where", sqlite) == nil)
    }

    @Test("A statement in parentheses is read at its own depth")
    func parenthesizedStatement() {
        #expect(first("(DELETE FROM t)") == .delete)
        #expect(first("(DELETE FROM t WHERE id = 1)") == nil)
    }

    @Test("On SQL Server a statement written without a terminator is read on its own")
    func sqlServerUnterminatedStatement() {
        #expect(first("UPDATE [t] SET [a] = 1 WHERE [id] = 1 DELETE FROM [t]", Self.sqlServer) == .delete)
        #expect(first("DELETE FROM [t] UPDATE [t] SET [a] = 1 WHERE [id] = 1", Self.sqlServer) == .delete)
        #expect(first("SET NOCOUNT OFF; UPDATE TOP (1) [t] SET [a] = ? WHERE [a] = ?", Self.sqlServer) == nil)
        #expect(first("DELETE TOP (1) FROM [t] WHERE [a] IS NULL", Self.sqlServer) == nil)
        #expect(first("UPDATE [t] SET [a] = 1 -- WHERE [id] = 1", Self.sqlServer) == .update)
        #expect(first("UPDATE STATISTICS [t]", Self.sqlServer) == nil)
    }

    @Test("A statement an engine runs from inside another is read on its own")
    func embeddedStatement() {
        let cockroachDB = Self.grammar("CockroachDB")
        #expect(first("SELECT * FROM [DELETE FROM t RETURNING id] WHERE id = 1", cockroachDB) == .delete)
        #expect(first("SELECT * FROM [UPDATE t SET a = 1 RETURNING id] WHERE id = 1", cockroachDB) == .update)
        #expect(first("SELECT * FROM [DELETE FROM t WHERE id = 1 RETURNING id]", cockroachDB) == nil)
        #expect(first("SELECT * FROM [DELETE FROM t RETURNING id]") == nil)
        let surrealQL = Self.grammar("SurrealDB")
        #expect(first("SELECT * FROM t WHERE (DELETE t)", surrealQL) == .delete)
        #expect(first("SELECT DELETE t FROM u WHERE true", surrealQL) == .delete)
        #expect(first("SELECT * FROM (DELETE t WHERE id = 1)", surrealQL) == nil)
    }

    @Test("ClickHouse's ALTER TABLE mutations are read as the write they are")
    func clickHouseMutations() {
        #expect(first("ALTER TABLE `t` UPDATE `a` = ? WHERE `id` = ?", Self.clickHouse) == nil)
        #expect(first("ALTER TABLE `t` DELETE WHERE `id` = ?", Self.clickHouse) == nil)
        #expect(first("ALTER TABLE `t` UPDATE `a` = ?", Self.clickHouse) == .update)
        #expect(first("ALTER TABLE `t` ON CLUSTER c DELETE", Self.clickHouse) == .delete)
        #expect(first("ALTER TABLE `t` UPDATE `a` = '# WHERE'", Self.clickHouse) == .update)
    }

    @Test("A table change that names UPDATE or DELETE as a referential action is not a write")
    func referentialActionsAreNotWrites() {
        #expect(first("ALTER TABLE t ADD FOREIGN KEY (a) REFERENCES u (id) ON DELETE CASCADE", Self.mySQL) == nil)
        #expect(first("ALTER TABLE t MODIFY c TIMESTAMP ON UPDATE CURRENT_TIMESTAMP", Self.mySQL) == nil)
    }

    @Test("A MySQL comment is closed where MySQL closes it")
    func mySQLHashComment() {
        #expect(first("UPDATE `t` SET `a` = 1 # WHERE `id` = 1", Self.mySQL) == .update)
        #expect(first("UPDATE `t` SET `a` = 1 WHERE `id` = 1", Self.mySQL) == nil)
    }
}
