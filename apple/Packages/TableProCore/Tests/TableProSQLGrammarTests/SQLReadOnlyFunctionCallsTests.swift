import Foundation
import TableProSQLGrammar
import Testing

struct SQLReadOnlyFunctionCallsTests {
    private static func callsUnlisted(_ sql: String, _ engine: String, types: Set<String> = []) -> Bool {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: engine, declared: nil, session: nil)
        return SQLReadOnlyFunctionCalls.callsUnlistedFunction(sql, databaseTypeId: engine, readings: readings, typeNames: types)
    }

    @Test("A user function, a qualified or quoted name and a call in a later statement are unlisted", arguments: [
        "SELECT purge_orders()",
        "SELECT app.count(id) FROM orders",
        "SELECT `purge_orders`() FROM orders",
        "SELECT 1;\nSELECT purge_orders()",
    ])
    func userCallsAreUnlisted(sql: String) {
        #expect(Self.callsUnlisted(sql, "MySQL"))
    }

    @Test("Built-ins, a plain EXPLAIN and the engine's own types are listed")
    func builtinsAreListed() {
        #expect(!Self.callsUnlisted("SELECT COUNT(*), LOWER(name), DATE_FORMAT(at, '%Y') FROM orders", "MySQL"))
        #expect(!Self.callsUnlisted("EXPLAIN SELECT purge_orders()", "PostgreSQL"))
        #expect(!Self.callsUnlisted("SELECT total::numeric(10, 2) FROM orders", "PostgreSQL", types: ["numeric"]))
        #expect(Self.callsUnlisted("SELECT total::numeric(10, 2) FROM orders", "PostgreSQL"))
    }

    @Test("The engines whose functions a query can call to write are the type ids the apps use")
    func writingEnginesAreTypeIds() {
        #expect(SQLReadOnlyFunctionCalls.queryFunctionsCanWrite == [
            "Oracle", "Dameng", "MySQL", "MariaDB", "OceanBase", "PostgreSQL", "CockroachDB", "PGlite", "KingbaseES",
            "SurrealDB",
        ])
        #expect(SQLReadOnlyFunctionCalls.builtins(forDatabaseTypeId: "Oracle").contains("NVL"))
        #expect(!SQLReadOnlyFunctionCalls.builtins(forDatabaseTypeId: "MySQL").contains("NVL"))
    }

    // Measured on Oracle 23ai with user functions of each name (apple/scripts/probes/check-match-recognize-calls.sh):
    // inside MEASURES and DEFINE none of them runs, outside the clause each does.
    @Test("MATCH_RECOGNIZE's navigation and row pattern are the clause's own on Oracle", arguments: [
        "SELECT * FROM orders MATCH_RECOGNIZE (ORDER BY id MEASURES PREV(x.purge) AS p ALL ROWS PER MATCH "
            + "PATTERN (x+) DEFINE x AS PREV(x.purge) IS NULL OR x.purge < PREV(x.purge, 1))",
        "SELECT * FROM orders MATCH_RECOGNIZE (ORDER BY id MEASURES NEXT(x.purge) AS n ONE ROW PER MATCH "
            + "PATTERN (x) DEFINE x AS NEXT(x.purge) IS NOT NULL)",
        "SELECT * FROM orders MATCH_RECOGNIZE (PARTITION BY id ORDER BY id MEASURES FIRST(x.purge) AS f, "
            + "FINAL LAST(x.purge) AS l, RUNNING COUNT(*) AS c ONE ROW PER MATCH PATTERN (x+) DEFINE x AS FIRST(x.purge) > 0)",
        "SELECT * FROM orders MATCH_RECOGNIZE (ORDER BY id MEASURES CLASSIFIER() AS c, MATCH_NUMBER() AS m "
            + "ALL ROWS PER MATCH PATTERN (^ PERMUTE(x, y) {- z -} $) DEFINE x AS 1 = 1, y AS 1 = 1, z AS 1 = 1)",
        "SELECT * FROM (SELECT id FROM orders) MATCH_RECOGNIZE (ORDER BY id PATTERN (x) DEFINE x AS ABS(PREV(x.id)) > 0) mr",
    ])
    func rowPatternNavigationIsListed(sql: String) {
        #expect(!Self.callsUnlisted(sql, "Oracle"))
    }

    @Test("Outside MATCH_RECOGNIZE, and in a query nested in it, those names are a user's functions", arguments: [
        "SELECT prev(1) FROM dual",
        "SELECT first(1), last(1) FROM dual",
        "SELECT classifier(), match_number() FROM dual",
        "SELECT match_recognize(1) FROM dual",
        "SELECT pattern(1) FROM dual",
        "SELECT * FROM orders MATCH_RECOGNIZE (ORDER BY id PATTERN (x) DEFINE x AS x.purge > (SELECT prev(1) FROM dual))",
        "SELECT * FROM orders MATCH_RECOGNIZE (ORDER BY id MEASURES wipe() AS w PATTERN (x) DEFINE x AS 1 = 1)",
        "SELECT * FROM orders MATCH_RECOGNIZE (ORDER BY id PATTERN (x) DEFINE x AS pk.prev(x.id) > 0)",
        "SELECT * FROM orders MATCH_RECOGNIZE (ORDER BY id PATTERN (x) DEFINE x AS \"PREV\"(x.id) > 0)",
        "SELECT * FROM orders MATCH_RECOGNIZE (PARTITION BY prev(purge) ORDER BY id PATTERN (x) DEFINE x AS 1 = 1)",
        "SELECT * FROM orders MATCH_RECOGNIZE (ORDER BY id MEASURES pattern(wipe()) AS m PATTERN (x) DEFINE x AS 1 = 1)",
        "SELECT * FROM orders MATCH_RECOGNIZE (ORDER BY id MEASURES PREV(x.id) AS p PATTERN (x))",
        "SELECT * FROM orders MATCH_RECOGNIZE (DEFINE x AS PREV(x.id) > 0 PATTERN (x))",
        "SELECT * FROM orders MATCH_RECOGNIZE (ORDER BY id PATTERN (x) DEFINE x AS x.purge > "
            + "((SELECT 1 FROM dual WHERE 1 = 0) UNION ALL SELECT prev(1) FROM dual))",
        "SELECT * FROM orders MATCH_RECOGNIZE (ORDER BY id PATTERN (x) DEFINE x AS "
            + "EXISTS ((SELECT 1 FROM dual WHERE 1 = 0) UNION ALL SELECT prev(1) FROM dual))",
    ])
    func rowPatternNamesElsewhereAreUnlisted(sql: String) {
        #expect(Self.callsUnlisted(sql, "Oracle"))
    }

    @Test("An engine without MATCH_RECOGNIZE reads PREV as a user function")
    func rowPatternIsOracleOnly() {
        #expect(Self.callsUnlisted("SELECT * FROM t MATCH_RECOGNIZE (PATTERN (x) DEFINE x AS PREV(x.a) > 0)", "PostgreSQL"))
    }

    @Test("On SurrealDB only a stored body is unlisted: its built-ins are namespaced")
    func surrealStoredBodies() {
        #expect(Self.callsUnlisted("SELECT fn::mk() FROM ONLY person:one", "SurrealDB"))
        #expect(Self.callsUnlisted("RETURN api::invoke('/x')", "SurrealDB"))
        #expect(!Self.callsUnlisted("SELECT time::now(), string::lowercase(name), count() FROM person", "SurrealDB"))
    }
}
