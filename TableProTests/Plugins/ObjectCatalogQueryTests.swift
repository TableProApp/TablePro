//
//  ObjectCatalogQueryTests.swift
//  TableProTests
//
//  The catalog SQL each engine uses to list routines and triggers and to read their source.
//

import Foundation
import Testing

@testable import TablePro

@Suite("PostgreSQL Object Catalog Queries")
struct PostgreSQLObjectQueryTests {
    /// information_schema.routines shows only what the caller has a privilege on and repeats a
    /// name once per overload, which is what produced duplicate rows and an arbitrary definition.
    @Test("Routine listing reads pg_proc, never information_schema")
    func routineListReadsPgProc() {
        let sql = PostgreSQLObjectQueries.routineList(schema: "public", serverVersionNumber: 160_000)
        #expect(sql.contains("pg_catalog.pg_proc"))
        #expect(!sql.contains("information_schema"))
        #expect(sql.contains("p.oid::text"))
        #expect(sql.contains("pg_get_function_identity_arguments"))
    }

    /// `PQserverVersion` is 0 for a handle that has not connected. Reading that as pre-11 emitted
    /// `proisagg`, which PostgreSQL 11 dropped, and failed the listing on every current server.
    @Test("An unknown server version reads as modern, not ancient")
    func unknownVersionIsModern() {
        #expect(PostgreSQLObjectQueries.usesProkind(serverVersionNumber: 0))
        #expect(PostgreSQLObjectQueries.usesProkind(serverVersionNumber: 170_000))
        #expect(!PostgreSQLObjectQueries.usesProkind(serverVersionNumber: 100_000))
        #expect(!PostgreSQLObjectQueries.routineList(schema: "public", serverVersionNumber: 0)
            .contains("proisagg"))
    }

    @Test("Aggregates and window functions are excluded because pg_get_functiondef raises on them")
    func aggregatesExcluded() {
        let modern = PostgreSQLObjectQueries.routineList(schema: "public", serverVersionNumber: 160_000)
        #expect(modern.contains("p.prokind IN ('f', 'p')"))

        let legacy = PostgreSQLObjectQueries.routineList(schema: "public", serverVersionNumber: 100_000)
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

    @Test("A quote in a name or schema is escaped in every query")
    func literalsAreEscaped() {
        let list = PostgreSQLObjectQueries.routineList(schema: "it's", serverVersionNumber: 160_000)
        #expect(list.contains("'it''s'"))

        let byName = PostgreSQLObjectQueries.routineDefinitionByName(
            name: "x'; DROP TABLE t; --", schema: "public", arguments: nil
        )
        #expect(byName.contains("'x''; DROP TABLE t; --'"))

        let triggers = PostgreSQLObjectQueries.triggerList(schema: "public", table: "o'brien")
        #expect(triggers.contains("'o''brien'"))
    }
}

@Suite("MySQL Object Catalog Queries")
struct MySQLObjectQueryTests {
    @Test("The DDL statement is schema-qualified")
    func routineDefinitionIsQualified() {
        let sql = MySQLObjectQueries.routineDefinition(kind: "PROCEDURE", schema: "analytics", name: "cleanup")
        #expect(sql == "SHOW CREATE PROCEDURE `analytics`.`cleanup`")
    }

    /// Unqualified, the server resolves the name against the session database, so browsing one
    /// database and opening another's routine returned a different routine's body.
    @Test("A nil schema is the only case that falls back to an unqualified name")
    func unqualifiedOnlyWithoutSchema() {
        let sql = MySQLObjectQueries.routineDefinition(kind: "FUNCTION", schema: nil, name: "f")
        #expect(sql == "SHOW CREATE FUNCTION `f`")
    }

    @Test("The parameter list excludes a function's return row")
    func parameterListSkipsOrdinalZero() {
        let sql = MySQLObjectQueries.routineList(schema: "app")
        #expect(sql.contains("p.ORDINAL_POSITION > 0"))
        #expect(sql.contains("information_schema.PARAMETERS"))
    }

    @Test("Both trigger scopes come from one builder")
    func triggerScopesShareOneQuery() {
        let all = MySQLObjectQueries.triggerList(schema: "app", table: nil)
        let one = MySQLObjectQueries.triggerList(schema: "app", table: "orders")
        #expect(!all.contains("EVENT_OBJECT_TABLE ="))
        #expect(one.contains("EVENT_OBJECT_TABLE = 'orders'"))
        #expect(all.contains("ACTION_CONDITION"))
        #expect(all.contains("DEFINER"))
    }

    /// Dropping DEFINER or the WHEN clause produces something that looks runnable and is not the
    /// trigger the server holds.
    @Test("The assembled statement keeps the definer and the when clause")
    func triggerStatementKeepsDefinerAndCondition() {
        let statement = MySQLObjectQueries.triggerStatement(
            name: "audit", table: "orders", schema: "app",
            timing: "BEFORE", event: "INSERT", orientation: "ROW",
            condition: "NEW.total > 0", definer: "root@localhost"
        )
        #expect(statement.contains("DEFINER = `root`@`localhost`"))
        #expect(statement.contains("WHEN (NEW.total > 0)"))
        #expect(statement.contains("`app`.`audit`"))
        #expect(statement.contains("ON `app`.`orders`"))
        #expect(statement.contains("FOR EACH ROW"))
    }

    @Test("A definer is quoted as two identifiers, not one")
    func definerIsQuotedInTwoParts() {
        #expect(MySQLObjectQueries.quotedDefiner("root@localhost") == "`root`@`localhost`")
        #expect(MySQLObjectQueries.quotedDefiner("a@b@c") == "`a@b`@`c`")
        #expect(MySQLObjectQueries.quotedDefiner("plain") == "`plain`")
    }

    @Test("A quote in a schema or table is escaped")
    func literalsAreEscaped() {
        #expect(MySQLObjectQueries.routineList(schema: "it's").contains("'it''s'"))
        #expect(MySQLObjectQueries.triggerList(schema: "app", table: "o'brien").contains("'o''brien'"))
    }

    @Test("A backtick in an identifier is doubled")
    func identifiersAreQuoted() {
        #expect(MySQLObjectQueries.quoteIdentifier("we`ird") == "`we``ird`")
    }
}

@Suite("MSSQL Object Catalog Queries")
struct MSSQLObjectQueryTests {
    /// INFORMATION_SCHEMA.ROUTINES.ROUTINE_DEFINITION is nvarchar(4000) and silently truncates,
    /// which looks like a procedure that ends mid-statement.
    @Test("Routine source comes from sys.sql_modules, never ROUTINE_DEFINITION")
    func routineSourceAvoidsInformationSchema() {
        let list = MSSQLObjectQueries.routineList(schema: "dbo")
        let definition = MSSQLObjectQueries.routineDefinition(schema: "dbo", name: "p")
        #expect(list.contains("sys.sql_modules"))
        #expect(definition.contains("sys.sql_modules"))
        #expect(!list.contains("ROUTINE_DEFINITION"))
        #expect(!definition.contains("ROUTINE_DEFINITION"))
    }

    @Test("Both trigger scopes come from one builder")
    func triggerScopesShareOneQuery() {
        let all = MSSQLObjectQueries.triggerList(schema: "dbo", table: nil)
        let one = MSSQLObjectQueries.triggerList(schema: "dbo", table: "Orders")
        #expect(!all.contains("parent.name ="))
        #expect(one.contains("parent.name = 'Orders'"))
        #expect(all.contains("sys.trigger_events"))
    }

    @Test("Object types map to the two routine kinds")
    func objectTypeMapping() {
        #expect(MSSQLObjectQueries.routineKind(forObjectType: "P ") == "PROCEDURE")
        #expect(MSSQLObjectQueries.routineKind(forObjectType: "FN") == "FUNCTION")
        #expect(MSSQLObjectQueries.routineKind(forObjectType: "IF") == "FUNCTION")
        #expect(MSSQLObjectQueries.routineKind(forObjectType: "TF") == "FUNCTION")
    }

    @Test("A quote in a schema or table is escaped")
    func literalsAreEscaped() {
        #expect(MSSQLObjectQueries.routineList(schema: "it's").contains("'it''s'"))
        #expect(MSSQLObjectQueries.triggerList(schema: "dbo", table: "o'brien").contains("'o''brien'"))
    }
}

@Suite("Oracle Object Catalog Queries")
struct OracleObjectQueryTests {
    @Test("The trigger list selects the body the old query never asked for")
    func triggerListSelectsBody() {
        let sql = OracleObjectQueries.triggerList(schema: "HR", table: nil)
        #expect(sql.contains("TRIGGER_BODY"))
        #expect(sql.contains("DESCRIPTION"))
        #expect(!sql.contains("TABLE_NAME = "))
    }

    @Test("Both trigger scopes come from one builder")
    func triggerScopesShareOneQuery() {
        let one = OracleObjectQueries.triggerList(schema: "HR", table: "EMPLOYEES")
        #expect(one.contains("TABLE_NAME = 'EMPLOYEES'"))
    }

    /// DESCRIPTION already holds the name, timing, events, table and WHEN clause. Assembling that
    /// header from the separate columns is how the old code lost the WHEN clause.
    @Test("A trigger definition is the description plus the body")
    func triggerDefinitionUsesDescription() {
        let definition = OracleObjectQueries.triggerDefinition(
            description: "\"AUDIT_EMP\"\nBEFORE INSERT ON \"HR\".\"EMPLOYEES\"\nFOR EACH ROW\nWHEN (NEW.SALARY > 0)",
            body: "BEGIN NULL; END;",
            name: "AUDIT_EMP"
        )
        #expect(definition.hasPrefix("CREATE OR REPLACE TRIGGER "))
        #expect(definition.contains("WHEN (NEW.SALARY > 0)"))
        #expect(definition.hasSuffix("BEGIN NULL; END;"))
    }

    @Test("A missing description still produces a runnable header")
    func triggerDefinitionFallsBackToName() {
        let definition = OracleObjectQueries.triggerDefinition(
            description: nil, body: "BEGIN NULL; END;", name: "AUDIT_EMP"
        )
        #expect(definition.hasPrefix("CREATE OR REPLACE TRIGGER \"AUDIT_EMP\""))
    }

    @Test("Timing and orientation are read out of the trigger type")
    func timingAndOrientation() {
        #expect(OracleObjectQueries.timing(fromTriggerType: "BEFORE EACH ROW") == "BEFORE")
        #expect(OracleObjectQueries.timing(fromTriggerType: "AFTER STATEMENT") == "AFTER")
        #expect(OracleObjectQueries.timing(fromTriggerType: "INSTEAD OF") == "INSTEAD OF")
        #expect(OracleObjectQueries.orientation(fromTriggerType: "BEFORE EACH ROW") == "ROW")
        #expect(OracleObjectQueries.orientation(fromTriggerType: "AFTER STATEMENT") == "STATEMENT")
    }

    /// A packaged routine is an OBJECT_TYPE of PACKAGE, so listing only PROCEDURE and FUNCTION
    /// keeps it out. It is addressed through its package and has a different DDL call, so a row
    /// for it here would be a row whose source cannot be fetched.
    @Test("Packaged routines stay out of the standalone list")
    func packagedRoutinesExcluded() {
        let sql = OracleObjectQueries.routineList(schema: "HR")
        #expect(sql.contains("OBJECT_TYPE IN ('PROCEDURE', 'FUNCTION')"))
        #expect(sql.contains("ALL_OBJECTS"))
    }

    /// LISTAGG caps at 4000 bytes and raises ORA-01489 past it, which fails the whole SELECT and
    /// loses every routine in the schema over one wide signature. Oracle only overloads inside a
    /// package, so a standalone routine needs no argument list to be identified.
    @Test("The routine list builds no argument signature")
    func routineListAvoidsListagg() {
        let sql = OracleObjectQueries.routineList(schema: "HR")
        #expect(!sql.contains("LISTAGG"))
        #expect(!sql.contains("ALL_ARGUMENTS"))
    }

    /// A schema browse asks for the triggers this schema owns; a per-table fetch asks for the
    /// triggers on that table. The two columns differ for a cross-schema trigger.
    @Test("Schema scope reads OWNER and table scope reads TABLE_OWNER")
    func triggerScopeColumns() {
        let schemaWide = OracleObjectQueries.triggerList(schema: "HR", table: nil)
        #expect(schemaWide.contains("WHERE OWNER = 'HR'"))
        #expect(!schemaWide.contains("TABLE_OWNER = 'HR'"))

        let perTable = OracleObjectQueries.triggerList(schema: "HR", table: "EMPLOYEES")
        #expect(perTable.contains("TABLE_OWNER = 'HR'"))
        #expect(perTable.contains("TABLE_NAME = 'EMPLOYEES'"))
    }

    @Test("ALL_SOURCE is read in line order")
    func routineSourceOrdersByLine() {
        let sql = OracleObjectQueries.routineSource(schema: "HR", name: "P", type: "PROCEDURE")
        #expect(sql.contains("ORDER BY LINE"))
        #expect(sql.contains("ALL_SOURCE"))
    }

    @Test("A quote in a schema or name is escaped")
    func literalsAreEscaped() {
        #expect(OracleObjectQueries.routineList(schema: "IT'S").contains("'IT''S'"))
        #expect(
            OracleObjectQueries.routineSource(schema: "HR", name: "X'; DROP", type: "PROCEDURE")
                .contains("'X''; DROP'")
        )
    }
}
