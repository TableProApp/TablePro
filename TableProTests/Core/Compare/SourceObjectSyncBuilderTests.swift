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
    ) throws -> String? {
        try SourceObjectSyncBuilder(targetDriver: driver, targetDatabaseType: .postgresql)
            .build(for: CompareObjectResult(identity: identity, status: .onlyInTarget), action: .drop)
            .first?.sql
    }

    /// Two overloads are two routines, and a drop that names only `f` is refused as ambiguous.
    func testARoutineDropCarriesItsArgumentListWhereTheEngineNeedsOne() {
        XCTAssertEqual(
            try drop(
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
            try drop(
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
            try drop(
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
            try drop(
                CompareObjectIdentity(kind: .trigger, schema: "public", name: "audit"),
                driver: DialectDropDriver()
            ),
            "DROP TRIGGER \"public\".\"audit\""
        )
    }

    /// An engine that rejects the argument list keeps the plain drop it has always had.
    func testAnEngineWithoutADialectDropKeepsTheQualifiedName() {
        XCTAssertEqual(
            try drop(
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
    ) throws -> [String] {
        try SourceObjectSyncBuilder(targetDriver: PlainDropDriver(), targetDatabaseType: databaseType)
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
            try create(
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
        XCTAssertEqual(try create(unit, kind: .procedure, databaseType: .oracle), [unit])
    }

    /// The generic grammar would cut a T-SQL body with no BEGIN into pieces the server rejects.
    func testAnUntrackedEngineSendsTheDefinitionWhole() {
        let body = "CREATE PROCEDURE dbo.x AS SET NOCOUNT ON; SELECT 1; SELECT 2;"
        XCTAssertEqual(try create(body, kind: .procedure, databaseType: .mssql), [body])
    }

    func testAMySQLRoutineIsOneStatementWithoutItsSeparator() {
        XCTAssertEqual(
            try create("CREATE PROCEDURE x()\nBEGIN\n  SELECT 1;\nEND;", kind: .procedure, databaseType: .mysql),
            ["CREATE PROCEDURE x()\nBEGIN\n  SELECT 1;\nEND"]
        )
    }

    // MARK: - Replace

    private func replace(
        _ definition: String,
        kind: CompareObjectKind = .trigger,
        driver: any PluginDatabaseDriver
    ) throws -> [SyncStatement] {
        try SourceObjectSyncBuilder(targetDriver: driver, targetDatabaseType: .oracle).build(
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
    func testADefinitionThatReplacesItselfIsNotDroppedFirst() throws {
        let definition = "CREATE OR REPLACE TRIGGER x BEFORE INSERT ON t FOR EACH ROW\nBEGIN NULL; END;"

        let statements = try replace(definition, driver: InPlaceReplacingDriver())

        XCTAssertEqual(statements.map(\.sql), [definition])
        XCTAssertEqual(statements.first?.summary.hasPrefix("Replace trigger"), true)
    }

    func testAReplacementIsDroppedFirstWhereTheDriverCannotReplaceInPlace() throws {
        let definition = "CREATE OR REPLACE TRIGGER x BEFORE INSERT ON t FOR EACH ROW\nBEGIN NULL; END;"

        XCTAssertEqual(try replace(definition, driver: PlainDropDriver()).map(\.sql), [
            "DROP TRIGGER \"APP\".\"x\"", definition,
        ])
    }

    func testADefinitionWithoutOrReplaceIsDroppedFirst() throws {
        let statements = try replace(
            "CREATE TRIGGER x BEFORE INSERT ON t FOR EACH ROW\nBEGIN NULL; END;", driver: InPlaceReplacingDriver()
        )

        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].sql.hasPrefix("DROP TRIGGER"))
    }

    func testAMaterializedViewIsAlwaysDroppedFirst() throws {
        let statements = try replace(
            "CREATE OR REPLACE MATERIALIZED VIEW x AS SELECT 1 FROM dual",
            kind: .materializedView,
            driver: InPlaceReplacingDriver()
        )

        XCTAssertEqual(statements.count, 2)
    }

    /// A view is addressed by name on every engine, so it must not be routed through either hook.
    func testAViewDropIsUnchanged() {
        XCTAssertEqual(
            try drop(
                CompareObjectIdentity(kind: .view, schema: "public", name: "recent"),
                driver: DialectDropDriver()
            ),
            "DROP VIEW \"public\".\"recent\""
        )
    }

    // MARK: - A definition that cannot recreate the object

    func testAReplacementWithNoDefinitionIsRefusedRatherThanScriptedAsADropAlone() {
        let result = CompareObjectResult(
            identity: CompareObjectIdentity(kind: .view, schema: "shop", name: "recent"),
            status: .differs,
            sourceDefinition: [""]
        )
        let builder = SourceObjectSyncBuilder(targetDriver: PlainDropDriver(), targetDatabaseType: .mysql)

        XCTAssertThrowsError(try builder.build(for: result, action: .alter)) { error in
            XCTAssertTrue(error.localizedDescription.contains("shop.recent"))
        }
        XCTAssertThrowsError(try builder.build(for: result, action: .create))
    }

    func testAReplacementWhoseDefinitionIsABodyIsRefused() {
        let result = CompareObjectResult(
            identity: CompareObjectIdentity(kind: .function, schema: "main", name: "add", signature: "(a, b)"),
            status: .differs,
            sourceDefinition: ["SELECT 1 AS x"]
        )
        let builder = SourceObjectSyncBuilder(targetDriver: PlainDropDriver(), targetDatabaseType: .duckdb)

        XCTAssertThrowsError(try builder.build(for: result, action: .alter))
        XCTAssertThrowsError(try builder.build(for: result, action: .create))
    }

    func testADropNeedsNoDefinition() throws {
        let result = CompareObjectResult(
            identity: CompareObjectIdentity(kind: .view, schema: "shop", name: "recent"),
            status: .onlyInTarget
        )

        let statements = try SourceObjectSyncBuilder(targetDriver: PlainDropDriver(), targetDatabaseType: .mysql)
            .build(for: result, action: .drop)

        XCTAssertEqual(statements.map(\.sql), ["DROP VIEW \"shop\".\"recent\""])
    }

    // MARK: - A materialized view's indexes

    private let matviewDefinition = "CREATE MATERIALIZED VIEW \"public\".\"mv\" AS SELECT id, customer FROM orders"

    private func index(_ name: String, _ columns: [String], unique: Bool = false) -> EditableIndexDefinition {
        EditableIndexDefinition(
            id: UUID(), name: name, columns: columns, type: .btree, isUnique: unique, isPrimary: false, comment: nil
        )
    }

    private func matview(
        schema: String = "public",
        status: TableDiffStatus,
        changes: [SchemaChange] = [],
        sourceIndexes: [EditableIndexDefinition]?,
        targetIndexes: [EditableIndexDefinition]? = nil,
        definitionMatches: Bool = false
    ) -> CompareObjectResult {
        CompareObjectResult(
            identity: CompareObjectIdentity(kind: .materializedView, schema: schema, name: "mv"),
            status: status,
            changes: changes,
            sourceDefinition: [matviewDefinition],
            sourceIndexes: sourceIndexes,
            targetIndexes: targetIndexes,
            definitionMatches: definitionMatches
        )
    }

    private func indexBuilder(
        _ driver: IndexStatementStubDriver = IndexStatementStubDriver(),
        indexSchema: String? = "public"
    ) -> SourceObjectSyncBuilder {
        SourceObjectSyncBuilder(targetDriver: driver, targetDatabaseType: .postgresql, indexSchema: indexSchema)
    }

    func testACreatedMaterializedViewGetsTheSourcesIndexesAfterIt() throws {
        let result = matview(
            status: .onlyInSource,
            sourceIndexes: [index("mv_id_idx", ["id"], unique: true), index("mv_customer_idx", ["customer"])]
        )

        let statements = try indexBuilder().build(for: result, action: .create)

        XCTAssertEqual(statements.map(\.sql), [
            matviewDefinition,
            "CREATE UNIQUE INDEX \"mv_id_idx\" ON \"public\".\"mv\" USING btree (\"id\")",
            "CREATE INDEX \"mv_customer_idx\" ON \"public\".\"mv\" USING btree (\"customer\")"
        ])
        XCTAssertEqual(Set(statements.map(\.objectName)), ["public.mv"], "one view is one object in the Apply sheet")
    }

    func testAReplacedMaterializedViewGetsTheSourcesIndexesBack() throws {
        let result = matview(
            status: .differs,
            sourceIndexes: [index("mv_id_idx", ["id"], unique: true)],
            targetIndexes: [index("mv_id_idx", ["id"], unique: true)]
        )

        let statements = try indexBuilder().build(for: result, action: .alter)

        XCTAssertEqual(statements.map(\.sql), [
            "DROP MATERIALIZED VIEW \"public\".\"mv\"",
            matviewDefinition,
            "CREATE UNIQUE INDEX \"mv_id_idx\" ON \"public\".\"mv\" USING btree (\"id\")"
        ])
        let dropHazards = statements[0].hazards
        XCTAssertTrue(dropHazards.contains { $0.severity == .refusedByDefault })
        XCTAssertTrue(dropHazards.contains { $0.explanation.contains("the source's indexes are created on it") })
        XCTAssertFalse(dropHazards.contains { $0.kind == .concurrentRefresh })
    }

    /// Measured on PostgreSQL 17.11: an index changed in place kept the 100 rows the view stored
    /// while its base table had 101, where a DROP and CREATE would have computed them again.
    func testAnIndexOnlyDifferenceChangesTheIndexesInPlace() throws {
        let old = index("mv_customer_idx", ["customer"])
        let new = index("mv_customer_amount_idx", ["customer", "amount"])
        let result = matview(
            status: .differs,
            changes: [.addIndex(new), .deleteIndex(old)],
            sourceIndexes: [new],
            targetIndexes: [old],
            definitionMatches: true
        )

        let statements = try indexBuilder().build(for: result, action: .alter)

        XCTAssertEqual(statements.map(\.sql), [
            "DROP INDEX \"public\".\"mv_customer_idx\"",
            "CREATE INDEX \"mv_customer_amount_idx\" ON \"public\".\"mv\" USING btree (\"customer\", \"amount\")"
        ])
        XCTAssertFalse(statements.contains { $0.sql.contains("MATERIALIZED VIEW") })
        XCTAssertEqual(Set(statements.map(\.objectName)), ["public.mv"])
    }

    func testDroppingTheLastUniqueIndexWarnsThatAConcurrentRefreshStopsWorking() throws {
        let unique = index("mv_id_idx", ["id"], unique: true)
        let plain = index("mv_id_plain_idx", ["id"])
        let result = matview(
            status: .differs,
            changes: [.addIndex(plain), .deleteIndex(unique)],
            sourceIndexes: [plain],
            targetIndexes: [unique],
            definitionMatches: true
        )

        let statements = try indexBuilder().build(for: result, action: .alter)

        let drop = try XCTUnwrap(statements.first { $0.sql.hasPrefix("DROP INDEX") })
        let create = try XCTUnwrap(statements.first { $0.sql.hasPrefix("CREATE INDEX") })
        XCTAssertTrue(drop.hazards.contains { $0.kind == .concurrentRefresh && $0.severity == .warning })
        XCTAssertFalse(create.hazards.contains { $0.kind == .concurrentRefresh })
    }

    func testAReplacementThatLosesTheUniqueIndexWarnsOnTheDrop() throws {
        let result = matview(
            status: .differs,
            sourceIndexes: [index("mv_id_idx", ["id"])],
            targetIndexes: [index("mv_id_idx", ["id"], unique: true)]
        )

        let statements = try indexBuilder().build(for: result, action: .alter)

        XCTAssertTrue(statements[0].hazards.contains { $0.kind == .concurrentRefresh })
    }

    func testAnIndexChangeThatKeepsAUsableUniqueIndexDoesNotWarn() throws {
        let unique = index("mv_id_idx", ["id"], unique: true)
        let key = index("mv_id_key", ["id", "customer"], unique: true)
        let result = matview(
            status: .differs,
            changes: [.addIndex(key), .deleteIndex(unique)],
            sourceIndexes: [key],
            targetIndexes: [unique],
            definitionMatches: true
        )

        let statements = try indexBuilder().build(for: result, action: .alter)

        XCTAssertFalse(statements.contains { $0.hazards.contains { $0.kind == .concurrentRefresh } })
    }

    /// Measured on PostgreSQL 17.11: `CREATE MATERIALIZED VIEW "a"."mv"` followed by an index on
    /// `"b"."mv"` left `a.mv` with no index and indexed the target's own `b.mv` instead.
    func testIndexesThatWouldNameAnotherSchemaThanTheDefinitionAreRefused() {
        let result = matview(schema: "a", status: .onlyInSource, sourceIndexes: [index("mv_id_idx", ["id"])])
        let unknown = matview(status: .onlyInSource, sourceIndexes: [index("mv_id_idx", ["id"])])

        XCTAssertThrowsError(try indexBuilder(indexSchema: "b").build(for: result, action: .create)) { error in
            XCTAssertTrue(error.localizedDescription.contains("a.mv"), error.localizedDescription)
        }
        XCTAssertThrowsError(try indexBuilder(indexSchema: nil).build(for: unknown, action: .create))
    }

    func testAViewWithNoIndexesToWriteNeedsNoSchemaToWriteThemIn() throws {
        let result = matview(schema: "a", status: .onlyInSource, sourceIndexes: [])

        XCTAssertEqual(try indexBuilder(indexSchema: "b").build(for: result, action: .create).count, 1)
    }

    func testAnIndexTheTargetCannotWriteRefusesTheScript() {
        let result = matview(status: .onlyInSource, sourceIndexes: [index("mv_id_idx", ["id"])])

        XCTAssertThrowsError(
            try indexBuilder(IndexStatementStubDriver(writesIndexes: false)).build(for: result, action: .create)
        )
    }

    func testAMaterializedViewWhoseIndexesAreNotComparedKeepsTheDefinitionOnlyReplacement() throws {
        let result = matview(status: .differs, sourceIndexes: nil)

        let statements = try indexBuilder().build(for: result, action: .alter)

        XCTAssertEqual(statements.map(\.sql), ["DROP MATERIALIZED VIEW \"public\".\"mv\"", matviewDefinition])
        XCTAssertTrue(statements[0].hazards.contains { $0.explanation.contains("along with its indexes") })
    }
}
