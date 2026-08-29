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

final class SourceObjectSyncBuilderTests: XCTestCase {
    private func drop(
        _ identity: CompareObjectIdentity,
        driver: any PluginDatabaseDriver
    ) -> String? {
        SourceObjectSyncBuilder(targetDriver: driver)
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
            "DROP FUNCTION IF EXISTS \"public\".\"total\"(integer);"
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
            "DROP PROCEDURE IF EXISTS \"public\".\"rebuild\"();"
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
            "DROP TRIGGER IF EXISTS \"audit\" ON \"public\".\"orders\";"
        )
    }

    /// Nothing to hang the `ON` off, so the bare qualified name is all that can be written.
    func testATriggerWithNoOwnerFallsBackToTheQualifiedName() {
        XCTAssertEqual(
            drop(
                CompareObjectIdentity(kind: .trigger, schema: "public", name: "audit"),
                driver: DialectDropDriver()
            ),
            "DROP TRIGGER \"public\".\"audit\";"
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
            "DROP FUNCTION \"shop\".\"total\";"
        )
    }

    /// A view is addressed by name on every engine, so it must not be routed through either hook.
    func testAViewDropIsUnchanged() {
        XCTAssertEqual(
            drop(
                CompareObjectIdentity(kind: .view, schema: "public", name: "recent"),
                driver: DialectDropDriver()
            ),
            "DROP VIEW \"public\".\"recent\";"
        )
    }
}
