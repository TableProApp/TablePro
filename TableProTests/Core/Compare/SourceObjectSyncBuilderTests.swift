//
//  SourceObjectSyncBuilderTests.swift
//  TableProTests
//
//  A routine and a trigger are not addressed by name alone on every engine, so
//  the drop the builder writes has to come from the target driver rather than
//  from a keyword and a qualified name.
//

@testable import TablePro
import TableProPluginKit
import XCTest

/// Shared through a refining protocol rather than a base class on purpose. A conformance is
/// witnessed where it is declared, so a subclass method cannot take over a requirement its
/// superclass already satisfied from the protocol's own default, and both stubs would answer nil.
private protocol DropStubDriver: PluginDatabaseDriver {}

private extension DropStubDriver {
    func connect() async throws {}
    func disconnect() {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
    func quoteIdentifier(_ name: String) -> String { "\"\(name)\"" }
    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func qualified(_ name: String, _ schema: String?) -> String {
        guard let schema, !schema.isEmpty else { return quoteIdentifier(name) }
        return "\(quoteIdentifier(schema)).\(quoteIdentifier(name))"
    }
}

/// Spells both drops its own way, the way PostgreSQL does.
private final class DialectDropDriver: DropStubDriver, @unchecked Sendable {
    func generateDropRoutineSQL(
        name: String,
        signature: String?,
        schema: String?,
        isFunction: Bool
    ) -> String? {
        let keyword = isFunction ? "FUNCTION" : "PROCEDURE"
        return "DROP \(keyword) IF EXISTS \(qualified(name, schema))\(signature ?? "")"
    }

    func generateDropTriggerSQL(name: String, table: String, schema: String?) -> String? {
        "DROP TRIGGER IF EXISTS \(quoteIdentifier(name)) ON \(qualified(table, schema))"
    }
}

/// Takes neither an argument list nor an `ON`, the way MySQL does, and so inherits both defaults.
private final class PlainDropDriver: DropStubDriver, @unchecked Sendable {}

/// Replaces an object with its `CREATE OR REPLACE` definition alone, the way Oracle does.
private final class InPlaceReplacingDriver: DropStubDriver, @unchecked Sendable {
    var replacesDefinitionsInPlace: Bool { true }
}

final class SourceObjectSyncBuilderTests: XCTestCase {
    private func drop(
        _ identity: CompareObjectIdentity,
        driver: any PluginDatabaseDriver
    ) -> String? {
        SourceObjectSyncBuilder(targetDriver: driver, targetDatabaseType: .postgresql)
            .build(for: CompareObjectResult(identity: identity, status: .onlyInTarget), action: .drop)
            .first?.sql
    }

    /// Two overloads are two routines, and a drop that names only `f` is refused as ambiguous.
    func testARoutineDropCarriesItsArgumentListWhereTheEngineNeedsOne() {
        XCTAssertEqual(
            drop(
                CompareObjectIdentity(
                    kind: .function, schema: "public", name: "total", signature: "(integer)"
                ),
                driver: DialectDropDriver()
            ),
            "DROP FUNCTION IF EXISTS \"public\".\"total\"(integer)"
        )
    }

    func testAProcedureDropUsesTheProcedureKeyword() {
        XCTAssertEqual(
            drop(
                CompareObjectIdentity(
                    kind: .procedure, schema: "public", name: "rebuild", signature: "()"
                ),
                driver: DialectDropDriver()
            ),
            "DROP PROCEDURE IF EXISTS \"public\".\"rebuild\"()"
        )
    }

    /// The owning table travels in the signature slot, which is what lets the driver write the `ON`.
    func testATriggerDropNamesTheTableThatOwnsIt() {
        XCTAssertEqual(
            drop(
                CompareObjectIdentity(
                    kind: .trigger, schema: "public", name: "audit", signature: "orders"
                ),
                driver: DialectDropDriver()
            ),
            "DROP TRIGGER IF EXISTS \"audit\" ON \"public\".\"orders\""
        )
    }

    /// Nothing to hang the `ON` off, so the bare qualified name is all that can be written.
    func testATriggerWithNoOwnerFallsBackToTheQualifiedName() {
        XCTAssertEqual(
            drop(
                CompareObjectIdentity(kind: .trigger, schema: "public", name: "audit"),
                driver: DialectDropDriver()
            ),
            "DROP TRIGGER \"public\".\"audit\""
        )
    }

    /// An engine that rejects the argument list keeps the plain drop it has always had.
    func testAnEngineWithoutADialectDropKeepsTheQualifiedName() {
        XCTAssertEqual(
            drop(
                CompareObjectIdentity(
                    kind: .function, schema: "shop", name: "total", signature: "(integer)"
                ),
                driver: PlainDropDriver()
            ),
            "DROP FUNCTION \"shop\".\"total\""
        )
    }

    // MARK: - Create

    private func create(
        _ definition: String,
        kind: CompareObjectKind,
        databaseType: DatabaseType
    ) -> [String] {
        SourceObjectSyncBuilder(targetDriver: PlainDropDriver(), targetDatabaseType: databaseType)
            .build(
                for: CompareObjectResult(
                    identity: CompareObjectIdentity(kind: kind, schema: "APP", name: "x"),
                    status: .onlyInSource,
                    sourceDefinition: definition.components(separatedBy: "\n")
                ),
                action: .create
            )
            .map(\.sql)
    }

    /// Measured on Oracle 23ai: sent with a `;` after the call, the trigger is stored INVALID.
    func testAnOracleCallTriggerGoesOutWithoutASemicolon() {
        XCTAssertEqual(
            create(
                "CREATE OR REPLACE TRIGGER x BEFORE INSERT ON t FOR EACH ROW\nCALL p(:NEW.id);",
                kind: .trigger,
                databaseType: .oracle
            ),
            ["CREATE OR REPLACE TRIGGER x BEFORE INSERT ON t FOR EACH ROW\nCALL p(:NEW.id)"]
        )
    }

    /// And a procedure sent without its own `;` is stored INVALID the same way.
    func testAnOracleUnitKeepsItsOwnSemicolon() {
        let unit = "CREATE OR REPLACE PROCEDURE x IS\nBEGIN\n  NULL;\nEND;"
        XCTAssertEqual(create(unit, kind: .procedure, databaseType: .oracle), [unit])
    }

    /// The generic grammar would cut a T-SQL body with no BEGIN into pieces the server rejects.
    func testAnUntrackedEngineSendsTheDefinitionWhole() {
        let body = "CREATE PROCEDURE dbo.x AS SET NOCOUNT ON; SELECT 1; SELECT 2;"
        XCTAssertEqual(create(body, kind: .procedure, databaseType: .mssql), [body])
    }

    func testAMySQLRoutineIsOneStatementWithoutItsSeparator() {
        XCTAssertEqual(
            create("CREATE PROCEDURE x()\nBEGIN\n  SELECT 1;\nEND;", kind: .procedure, databaseType: .mysql),
            ["CREATE PROCEDURE x()\nBEGIN\n  SELECT 1;\nEND"]
        )
    }

    // MARK: - Replace

    private func replace(
        _ definition: String,
        kind: CompareObjectKind = .trigger,
        driver: any PluginDatabaseDriver
    ) -> [SyncStatement] {
        SourceObjectSyncBuilder(targetDriver: driver, targetDatabaseType: .oracle).build(
            for: CompareObjectResult(
                identity: CompareObjectIdentity(kind: kind, schema: "APP", name: "x", signature: "t"),
                status: .differs,
                sourceDefinition: [definition]
            ),
            action: .alter
        )
    }

    /// Measured on Oracle 23ai: a DROP followed by a CREATE the engine refused left no trigger, while
    /// the same CREATE OR REPLACE refused on its own left the existing one VALID.
    func testADefinitionThatReplacesItselfIsNotDroppedFirst() {
        let definition = "CREATE OR REPLACE TRIGGER x BEFORE INSERT ON t FOR EACH ROW\nBEGIN NULL; END;"

        let statements = replace(definition, driver: InPlaceReplacingDriver())

        XCTAssertEqual(statements.map(\.sql), [definition])
        XCTAssertEqual(statements.first?.summary.hasPrefix("Replace trigger"), true)
    }

    func testAReplacementIsDroppedFirstWhereTheDriverCannotReplaceInPlace() {
        let definition = "CREATE OR REPLACE TRIGGER x BEFORE INSERT ON t FOR EACH ROW\nBEGIN NULL; END;"

        XCTAssertEqual(replace(definition, driver: PlainDropDriver()).map(\.sql), [
            "DROP TRIGGER \"APP\".\"x\"", definition,
        ])
    }

    func testADefinitionWithoutOrReplaceIsDroppedFirst() {
        let statements = replace(
            "CREATE TRIGGER x BEFORE INSERT ON t FOR EACH ROW\nBEGIN NULL; END;", driver: InPlaceReplacingDriver()
        )

        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].sql.hasPrefix("DROP TRIGGER"))
    }

    func testAMaterializedViewIsAlwaysDroppedFirst() {
        let statements = replace(
            "CREATE OR REPLACE MATERIALIZED VIEW x AS SELECT 1 FROM dual",
            kind: .materializedView,
            driver: InPlaceReplacingDriver()
        )

        XCTAssertEqual(statements.count, 2)
    }

    /// A view is addressed by name on every engine, so it must not be routed through either hook.
    func testAViewDropIsUnchanged() {
        XCTAssertEqual(
            drop(
                CompareObjectIdentity(kind: .view, schema: "public", name: "recent"),
                driver: DialectDropDriver()
            ),
            "DROP VIEW \"public\".\"recent\""
        )
    }
}
