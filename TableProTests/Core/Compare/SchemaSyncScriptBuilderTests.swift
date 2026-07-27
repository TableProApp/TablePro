//
//  SchemaSyncScriptBuilderTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import XCTest

@testable import TablePro

private final class StubSyncDriver: PluginDatabaseDriver, @unchecked Sendable {
    func connect() async throws {}

    func disconnect() {}

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

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

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        "CREATE TABLE \(definition.tableName)"
    }

    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? {
        "DROP \(objectType) \(name)"
    }

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        "ALTER TABLE \(table) ADD \(column.name)"
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE \(table) DROP \(columnName)"
    }

    func generateModifyColumnSQL(
        table: String,
        oldColumn: PluginColumnDefinition,
        newColumn: PluginColumnDefinition
    ) -> String? {
        "ALTER TABLE \(table) MODIFY \(newColumn.name)"
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        "CREATE INDEX \(index.name) ON \(table)"
    }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        "DROP INDEX \(indexName) ON \(table)"
    }

    func generateAddForeignKeySQL(table: String, fk: PluginForeignKeyDefinition) -> String? {
        "ALTER TABLE \(table) ADD CONSTRAINT \(fk.name)"
    }

    func generateDropForeignKeySQL(table: String, constraintName: String) -> String? {
        "ALTER TABLE \(table) DROP CONSTRAINT \(constraintName)"
    }
}

final class SchemaSyncScriptBuilderTests: XCTestCase {
    private var driver: StubSyncDriver!
    private var builder: SchemaSyncScriptBuilder!

    override func setUp() {
        super.setUp()
        driver = StubSyncDriver()
        builder = SchemaSyncScriptBuilder(targetDriver: driver)
    }

    override func tearDown() {
        driver = nil
        builder = nil
        super.tearDown()
    }

    private func snapshot(_ name: String) -> TableStructureSnapshot {
        TableStructureSnapshot(
            name: name,
            columns: [
                EditableColumnDefinition(
                    id: UUID(), name: "id", dataType: "int", isNullable: false, defaultValue: nil,
                    autoIncrement: false, unsigned: false, comment: nil, collation: nil,
                    onUpdate: nil, charset: nil, extra: nil, isPrimaryKey: true
                )
            ]
        )
    }

    private func foreignKey(from child: String, to parent: String) -> PluginForeignKeyInfo {
        PluginForeignKeyInfo(
            name: "fk_\(child)_\(parent)",
            column: "\(parent)_id",
            referencedTable: parent,
            referencedColumn: "id"
        )
    }

    // MARK: - Cross-table ordering

    func testCreatesEmitParentsBeforeChildren() {
        let operations: [SchemaSyncOperation] = [
            .createTable(snapshot("orders")),
            .createTable(snapshot("customers"))
        ]
        let foreignKeys = ["orders": [foreignKey(from: "orders", to: "customers")]]

        let ordered = SchemaSyncScriptBuilder.order(operations: operations, foreignKeysByTable: foreignKeys)

        XCTAssertEqual(ordered.map { $0.tableName }, ["customers", "orders"])
    }

    func testDropsEmitChildrenBeforeParents() {
        let operations: [SchemaSyncOperation] = [
            .dropTable(name: "customers", schema: nil),
            .dropTable(name: "orders", schema: nil)
        ]
        let foreignKeys = ["orders": [foreignKey(from: "orders", to: "customers")]]

        let ordered = SchemaSyncScriptBuilder.order(operations: operations, foreignKeysByTable: foreignKeys)

        XCTAssertEqual(ordered.map { $0.tableName }, ["orders", "customers"])
    }

    func testThreeTableChainOrdersTransitively() {
        let operations: [SchemaSyncOperation] = [
            .createTable(snapshot("line_items")),
            .createTable(snapshot("orders")),
            .createTable(snapshot("customers"))
        ]
        let foreignKeys = [
            "orders": [foreignKey(from: "orders", to: "customers")],
            "line_items": [foreignKey(from: "line_items", to: "orders")]
        ]

        let ordered = SchemaSyncScriptBuilder.order(operations: operations, foreignKeysByTable: foreignKeys)

        XCTAssertEqual(ordered.map { $0.tableName }, ["customers", "orders", "line_items"])
    }

    func testDropsRunBeforeCreatesWhichRunBeforeAlters() {
        let operations: [SchemaSyncOperation] = [
            .alterTable(name: "a", schema: nil, changes: []),
            .createTable(snapshot("b")),
            .dropTable(name: "c", schema: nil)
        ]

        let ordered = SchemaSyncScriptBuilder.order(operations: operations, foreignKeysByTable: [:])

        XCTAssertEqual(ordered.map { $0.tableName }, ["c", "b", "a"])
    }

    func testSameTableNameInTwoSchemasBothSurviveOrdering() {
        let operations: [SchemaSyncOperation] = [
            .alterTable(name: "users", schema: "app", changes: []),
            .alterTable(name: "users", schema: "audit", changes: [])
        ]

        let ordered = SchemaSyncScriptBuilder.order(operations: operations, foreignKeysByTable: [:])

        XCTAssertEqual(ordered.count, 2, "a bare-name collision must not drop or duplicate an operation")
        XCTAssertEqual(Set(ordered.map { $0.tableIdentifier }), ["app.users", "audit.users"])
    }

    func testOrderingUsesQualifiedNamesForDependencies() {
        let operations: [SchemaSyncOperation] = [
            .createTable(snapshot("orders")),
            .createTable(snapshot("customers"))
        ]
        let foreignKeys = [
            "orders": [PluginForeignKeyInfo(
                name: "fk", column: "customer_id", referencedTable: "customers", referencedColumn: "id"
            )]
        ]

        let ordered = SchemaSyncScriptBuilder.order(operations: operations, foreignKeysByTable: foreignKeys)

        XCTAssertEqual(ordered.map { $0.tableIdentifier }, ["customers", "orders"])
    }

    func testCircularForeignKeysStillEmitEveryTable() {
        let operations: [SchemaSyncOperation] = [
            .createTable(snapshot("a")),
            .createTable(snapshot("b"))
        ]
        let foreignKeys = [
            "a": [foreignKey(from: "a", to: "b")],
            "b": [foreignKey(from: "b", to: "a")]
        ]

        let ordered = SchemaSyncScriptBuilder.order(operations: operations, foreignKeysByTable: foreignKeys)

        XCTAssertEqual(Set(ordered.map { $0.tableName }), ["a", "b"], "a cycle must not drop tables from the script")
    }

    // MARK: - Intra-table ordering

    func testIntraTableOrderDropsConstraintsBeforeColumnsAndAddsThemLast() {
        let column = EditableColumnDefinition.placeholder()
        let index = EditableIndexDefinition.placeholder()
        let foreignKeyDefinition = EditableForeignKeyDefinition.placeholder()

        let sortedChanges = SchemaChangeOrdering.sorted([
            .addForeignKey(foreignKeyDefinition),
            .addColumn(column),
            .deleteForeignKey(foreignKeyDefinition),
            .addIndex(index),
            .deleteColumn(column)
        ])

        let positions = sortedChanges.map { change -> Int in
            switch change {
            case .deleteForeignKey: return 0
            case .deleteColumn: return 1
            case .addColumn: return 2
            case .addIndex: return 3
            case .addForeignKey: return 4
            default: return 99
            }
        }
        XCTAssertEqual(positions, positions.sorted(), "changes must be emitted in dependency-safe order")
    }

    // MARK: - Hazards

    func testDropTableIsRefusedByDefault() throws {
        let statements = try builder.build(
            operations: [.dropTable(name: "users", schema: nil)],
            foreignKeysByTable: [:]
        )

        XCTAssertEqual(statements.count, 1)
        XCTAssertTrue(statements[0].isRefusedByDefault)
        XCTAssertEqual(statements[0].hazards.first?.kind, .dataLoss)
    }

    func testCreateTableCarriesNoHazard() throws {
        let statements = try builder.build(
            operations: [.createTable(snapshot("users"))],
            foreignKeysByTable: [:]
        )

        XCTAssertEqual(statements.count, 1)
        XCTAssertFalse(statements[0].isRefusedByDefault)
        XCTAssertTrue(statements[0].hazards.isEmpty)
    }

    func testEveryStatementIsTerminated() throws {
        let statements = try builder.build(
            operations: [.createTable(snapshot("users")), .dropTable(name: "old", schema: nil)],
            foreignKeysByTable: [:]
        )

        for statement in statements {
            XCTAssertTrue(statement.sql.hasSuffix(";"), "\(statement.sql) is not terminated")
        }
    }
}

final class SyncSafetyClassifierTests: XCTestCase {
    private let classifier = SyncSafetyClassifier()

    private func column(_ name: String, _ dataType: String, nullable: Bool = true) -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(), name: name, dataType: dataType, isNullable: nullable, defaultValue: nil,
            autoIncrement: false, unsigned: false, comment: nil, collation: nil,
            onUpdate: nil, charset: nil, extra: nil, isPrimaryKey: false
        )
    }

    func testDropColumnIsRefusedByDefault() {
        let hazards = classifier.hazards(for: .deleteColumn(column("email", "varchar(255)")))

        XCTAssertEqual(hazards.first?.severity, .refusedByDefault)
        XCTAssertEqual(hazards.first?.kind, .dataLoss)
    }

    func testNarrowingTypeChangeIsRefused() {
        let hazards = classifier.hazards(for: .modifyColumn(
            old: column("name", "varchar(255)"),
            new: column("name", "varchar(50)")
        ))

        XCTAssertTrue(hazards.contains { $0.kind == .lossyTypeChange && $0.severity == .refusedByDefault })
    }

    func testWideningTypeChangeIsNotRefused() {
        let hazards = classifier.hazards(for: .modifyColumn(
            old: column("name", "varchar(50)"),
            new: column("name", "varchar(255)")
        ))

        XCTAssertFalse(hazards.contains { $0.kind == .lossyTypeChange })
    }

    func testMakingColumnNotNullIsRefused() {
        let hazards = classifier.hazards(for: .modifyColumn(
            old: column("email", "varchar(50)", nullable: true),
            new: column("email", "varchar(50)", nullable: false)
        ))

        XCTAssertTrue(hazards.contains { $0.kind == .dataLoss && $0.severity == .refusedByDefault })
    }

    func testAddColumnCarriesNoHazard() {
        XCTAssertTrue(classifier.hazards(for: .addColumn(column("nickname", "varchar(20)"))).isEmpty)
    }

    func testPrimaryKeyChangeIsRefused() {
        let hazards = classifier.hazards(for: .modifyPrimaryKey(old: ["id"], new: ["id", "tenant"]))

        XCTAssertEqual(hazards.first?.severity, .refusedByDefault)
    }
}

final class CompareSyncEngineFamilyTests: XCTestCase {
    func testSameTypeIsAlwaysAllowed() {
        XCTAssertTrue(CompareSyncEngineFamily.canGenerateStructureScript(from: .postgresql, to: .postgresql))
    }

    func testMySqlAndMariaDbAreCompatibleInBothDirections() {
        XCTAssertTrue(CompareSyncEngineFamily.canGenerateStructureScript(from: .mysql, to: .mariadb))
        XCTAssertTrue(CompareSyncEngineFamily.canGenerateStructureScript(from: .mariadb, to: .mysql))
    }

    func testUnrelatedEnginesAreRefused() {
        XCTAssertFalse(CompareSyncEngineFamily.canGenerateStructureScript(from: .postgresql, to: .mysql))
    }

    func testUnknownFutureTypeIsCompatibleOnlyWithItself() {
        let future = DatabaseType(rawValue: "SomeFutureEngine")

        XCTAssertTrue(CompareSyncEngineFamily.canGenerateStructureScript(from: future, to: future))
        XCTAssertFalse(CompareSyncEngineFamily.canGenerateStructureScript(from: future, to: .mysql))
    }

    func testCrossEngineDataWarningOnlyAppearsWhenTypesDiffer() {
        XCTAssertNil(CompareSyncEngineFamily.crossEngineDataWarning(from: .mysql, to: .mysql))
        XCTAssertNotNil(CompareSyncEngineFamily.crossEngineDataWarning(from: .mysql, to: .postgresql))
    }
}
