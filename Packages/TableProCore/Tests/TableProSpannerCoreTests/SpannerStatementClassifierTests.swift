import Foundation
import TableProSpannerCore
import Testing

@Suite("SpannerStatementClassifier")
struct SpannerStatementClassifierTests {
    private func kind(_ sql: String) -> SpannerStatementKind {
        SpannerStatementClassifier.classify(sql)
    }

    @Test("Queries", arguments: [
        "SELECT 1", "select * from t", "WITH x AS (SELECT 1) SELECT * FROM x", "(SELECT 1)",
        "GRAPH FinGraph MATCH (n) RETURN n", "CALL cancel_query('1')", "SHOW VARIABLE READ_ONLY_STALENESS",
        "", "   ", "VALUES (1)"
    ])
    func queries(sql: String) {
        #expect(kind(sql) == .query)
    }

    @Test("DML", arguments: ["INSERT INTO t (a) VALUES (1)", "update t set a = 1 where true", "DELETE FROM t WHERE TRUE",
                             "INSERT OR UPDATE INTO t (a) VALUES (1)"])
    func dml(sql: String) {
        #expect(kind(sql) == .dml)
    }

    @Test("DDL keywords", arguments: [
        "CREATE TABLE t (a INT64) PRIMARY KEY (a)", "ALTER TABLE t ADD COLUMN b STRING(MAX)", "DROP TABLE t",
        "RENAME TABLE a TO b", "GRANT SELECT ON TABLE t TO ROLE r", "REVOKE SELECT ON TABLE t FROM ROLE r", "ANALYZE",
        "create index i on t(a)"
    ])
    func ddl(sql: String) {
        #expect(kind(sql) == .ddl)
    }

    @Test("Leading comments are skipped")
    func leadingComments() {
        #expect(kind("-- note\nDELETE FROM t WHERE TRUE") == .dml)
        #expect(kind("# note\n  UPDATE t SET a = 1 WHERE TRUE") == .dml)
        #expect(kind("/* SELECT */ DROP TABLE t") == .ddl)
        #expect(kind("/* a /* b */ DELETE FROM t WHERE TRUE") == .dml)
        #expect(
            SpannerStatementClassifier.classify(
                "/* outer /* inner */ still comment */ INSERT INTO t (a) VALUES (1)", dialect: .postgreSQL
            ) == .dml
        )
        #expect(SpannerStatementClassifier.classify("/* a /* b */ DELETE FROM t", dialect: .postgreSQL) == .query)
        #expect(kind("\n\t /* a */ -- b\n /* c */ SELECT 1") == .query)
    }

    @Test("Statement hints are skipped")
    func hints() {
        #expect(kind("@{PDML_MAX_PARALLELISM=4} DELETE FROM t WHERE TRUE") == .dml)
        #expect(kind("@{USE_ADDITIONAL_PARALLELISM=TRUE} SELECT 1") == .query)
        #expect(kind("/* c */ @{a=b} @{c=d} UPDATE t SET a = 1 WHERE TRUE") == .dml)
    }

    @Test("Stripping leading noise keeps the statement text")
    func stripping() {
        #expect(SpannerStatementClassifier.strippingLeadingNoise("  -- x\n/* y */ @{h=1} SELECT 1 ") == "SELECT 1 ")
        #expect(SpannerStatementClassifier.strippingLeadingNoise("SELECT 1") == "SELECT 1")
        #expect(SpannerStatementClassifier.strippingLeadingNoise("-- only a comment") == "")
    }

    @Test("EXPLAIN carries the inner statement")
    func explain() {
        #expect(kind("EXPLAIN SELECT 1") == .explain(statement: "SELECT 1", analyze: false))
        #expect(kind("explain  DELETE FROM t WHERE TRUE ") == .explain(statement: "DELETE FROM t WHERE TRUE", analyze: false))
        #expect(kind("-- c\nEXPLAIN DROP TABLE t") == .explain(statement: "DROP TABLE t", analyze: false))
        #expect(kind("EXPLAIN (SELECT 1)") == .explain(statement: "(SELECT 1)", analyze: false))
    }

    @Test("EXPLAIN ANALYZE is flagged")
    func explainAnalyze() {
        #expect(kind("EXPLAIN ANALYZE SELECT 1") == .explain(statement: "SELECT 1", analyze: true))
        #expect(kind("explain /* x */ analyze DELETE FROM t") == .explain(statement: "DELETE FROM t", analyze: true))
    }

    @Test("A PostgreSQL option list is read for ANALYZE")
    func explainOptionList() {
        #expect(kind("EXPLAIN (ANALYZE) DELETE FROM t") == .explain(statement: "DELETE FROM t", analyze: true))
        #expect(kind("EXPLAIN (VERBOSE, ANALYZE true) SELECT 1") == .explain(statement: "SELECT 1", analyze: true))
        #expect(kind("EXPLAIN (FORMAT JSON) SELECT 1") == .explain(statement: "SELECT 1", analyze: false))
    }

    @Test("Transaction control", arguments: [
        ("BEGIN", SpannerStatementKind.begin), ("begin transaction", .begin), ("BEGIN WORK;", .begin),
        ("START TRANSACTION", .begin), ("start transaction ;", .begin), ("COMMIT", .commit), ("COMMIT TRANSACTION", .commit),
        ("commit work", .commit), ("ROLLBACK", .rollback), ("rollback transaction;", .rollback),
        ("-- c\nBEGIN /* x */", .begin)
    ])
    func transactionControl(sql: String, expected: SpannerStatementKind) {
        #expect(kind(sql) == expected)
    }

    @Test("Transaction options are not silently dropped", arguments: [
        "BEGIN READ ONLY", "BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE", "START TRANSACTION READ WRITE",
        "BEGIN READ WRITE", "SET TRANSACTION READ ONLY", "SAVEPOINT a", "ROLLBACK TO SAVEPOINT a", "RELEASE SAVEPOINT a",
        "COMMIT AND CHAIN"
    ])
    func unsupportedTransactionControl(sql: String) {
        #expect(kind(sql) == .unsupportedTransactionControl(sql))
    }

    @Test("SET without TRANSACTION and START without TRANSACTION are left to the server")
    func otherSetAndStart() {
        #expect(kind("SET STATEMENT_TIMEOUT = '10s'") == .query)
        #expect(kind("START BATCH DDL") == .query)
    }
}
