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

    @Test("On SurrealDB only a stored body is unlisted: its built-ins are namespaced")
    func surrealStoredBodies() {
        #expect(Self.callsUnlisted("SELECT fn::mk() FROM ONLY person:one", "SurrealDB"))
        #expect(Self.callsUnlisted("RETURN api::invoke('/x')", "SurrealDB"))
        #expect(!Self.callsUnlisted("SELECT time::now(), string::lowercase(name), count() FROM person", "SurrealDB"))
    }
}
