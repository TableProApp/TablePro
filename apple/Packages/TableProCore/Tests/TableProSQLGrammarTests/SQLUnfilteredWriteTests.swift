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
