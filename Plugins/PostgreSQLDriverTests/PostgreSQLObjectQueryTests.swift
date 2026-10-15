import Foundation
import TableProPluginKit
import TableProPostgreSQLCore
import Testing

struct PostgreSQLObjectQueryTests {
    /// information_schema.routines shows only what the caller has a privilege on and repeats a
    /// name once per overload, which is what produced duplicate rows and an arbitrary definition.
    @Test("Routine listing reads pg_proc, never information_schema")
    func routineListReadsPgProc() {
        let sql = PostgreSQLObjectQueries.routineList(schema: "public", capabilities: .assumingModernWhenUnknown(160_000))
        #expect(sql.contains("pg_catalog.pg_proc"))
        #expect(!sql.contains("information_schema"))
        #expect(sql.contains("p.oid::text"))
        #expect(sql.contains("pg_get_function_identity_arguments"))
    }

    /// `PQserverVersion` is 0 for a handle that has not connected. Reading that as pre-11 emitted
    /// `proisagg`, which PostgreSQL 11 dropped, and failed the listing on every current server.
    @Test("An unknown server version reads as modern, not ancient")
    func unknownVersionIsModern() {
        #expect(PostgreSQLCapabilities.assumingModernWhenUnknown(0).hasProcedureKind)
        #expect(PostgreSQLCapabilities(serverVersion: 170_000).hasProcedureKind)
        #expect(!PostgreSQLCapabilities(serverVersion: 100_000).hasProcedureKind)
        #expect(!PostgreSQLObjectQueries.routineList(schema: "public", capabilities: .assumingModernWhenUnknown(0))
            .contains("proisagg"))
    }

    @Test("The extension test names pg_proc, so a member of another catalog sharing the oid hides nothing")
    func routineExtensionTestNamesItsCatalog() {
        let sql = PostgreSQLObjectQueries.routineList(schema: "public", capabilities: .assumingModernWhenUnknown(160_000))
        #expect(sql.contains(
            "WHERE d.classid = 'pg_catalog.pg_proc'::pg_catalog.regclass AND d.objid = p.oid AND d.deptype = 'e'"
        ))
    }

    @Test("Aggregates and window functions are excluded because pg_get_functiondef raises on them")
    func aggregatesExcluded() {
        let modern = PostgreSQLObjectQueries.routineList(schema: "public", capabilities: .assumingModernWhenUnknown(160_000))
        #expect(modern.contains("p.prokind IN ('f', 'p')"))

        let legacy = PostgreSQLObjectQueries.routineList(schema: "public", capabilities: .assumingModernWhenUnknown(100_000))
        #expect(legacy.contains("NOT p.proisagg AND NOT p.proiswindow"))
        #expect(!legacy.contains("prokind IN"))
    }

    @Test("The DDL fetch addresses one oid, so an overload cannot resolve to a sibling")
    func routineDefinitionIsByOid() {
        let sql = PostgreSQLObjectQueries.routineDefinition(identity: "16401")
        #expect(sql.contains("'16401'::oid"))
        #expect(!sql.contains("LIMIT 1"))
    }

    @Test("A name-addressed fallback still predicates on the argument list")
    func routineDefinitionByNameUsesArguments() {
        let sql = PostgreSQLObjectQueries.routineDefinitionByName(
            name: "transform", schema: "public", arguments: "(geometry, integer)"
        )
        #expect(sql.contains("p.proname = 'transform'"))
        #expect(sql.contains("= '(geometry, integer)'"))
    }

    @Test("Both trigger scopes come from one builder")
    func triggerScopesShareOneQuery() {
        let all = PostgreSQLObjectQueries.triggerList(schema: "public", table: nil)
        let one = PostgreSQLObjectQueries.triggerList(schema: "public", table: "orders")
        #expect(all.contains("pg_catalog.pg_trigger"))
        #expect(!all.contains("c.relname ="))
        #expect(one.contains("c.relname = 'orders'"))
        #expect(one.contains("pg_catalog.pg_get_triggerdef"))
    }

    @Test("Trigger events are joined with concat_ws, which 9.1 has and array_remove does not")
    func triggerEventsUseConcatWs() {
        let sql = PostgreSQLObjectQueries.triggerList(schema: "public", table: nil)
        #expect(sql.contains("concat_ws(' OR ',"))
        #expect(!sql.contains("array_remove"))
        #expect(!sql.contains("array_to_string"))
    }

    @Test("A quote in a name or schema is escaped in every query")
    func literalsAreEscaped() {
        let list = PostgreSQLObjectQueries.routineList(schema: "it's", capabilities: .assumingModernWhenUnknown(160_000))
        #expect(list.contains("'it''s'"))

        let byName = PostgreSQLObjectQueries.routineDefinitionByName(
            name: "x'; DROP TABLE t; --", schema: "public", arguments: nil
        )
        #expect(byName.contains("'x''; DROP TABLE t; --'"))

        let triggers = PostgreSQLObjectQueries.triggerList(schema: "public", table: "o'brien")
        #expect(triggers.contains("'o''brien'"))
    }

    @Test("A backslash before a quote in a name becomes an E'' literal in every query")
    func backslashNamesUseEscapeStringLiterals() {
        let hostile = "a\\'; DROP TABLE victim; --"
        let expected = "E'a\\\\''; DROP TABLE victim; --'"

        let list = PostgreSQLObjectQueries.routineList(
            schema: hostile, capabilities: .assumingModernWhenUnknown(160_000)
        )
        #expect(list.contains("n.nspname = \(expected)"))

        let byName = PostgreSQLObjectQueries.routineDefinitionByName(
            name: hostile, schema: hostile, arguments: hostile
        )
        #expect(byName.contains("p.proname = \(expected)"))
        #expect(byName.contains("n.nspname = \(expected)"))
        #expect(byName.contains("')' = \(expected)"))

        let triggers = PostgreSQLObjectQueries.triggerList(schema: hostile, table: hostile)
        #expect(triggers.contains("c.relname = \(expected)"))
        #expect(triggers.contains("n.nspname = \(expected)"))
    }
}
