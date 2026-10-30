//
//  SchemaSyncScriptBuilderTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
import XCTest

@testable import TablePro

private final class StubSyncDriver: PluginDriverStub, @unchecked Sendable {
    var createTableStatements: [String]?
    var modifyColumnSQL: String?

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        "CREATE TABLE \(definition.tableName)"
    }

    func generateCreateTableStatements(definition: PluginCreateTableDefinition) -> [String]? {
        createTableStatements ?? generateCreateTableSQL(definition: definition).map { [$0] }
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
        modifyColumnSQL ?? "ALTER TABLE \(table) MODIFY \(newColumn.name)"
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
        builder = SchemaSyncScriptBuilder(targetDriver: driver, targetDatabaseType: .mysql)
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

    // MARK: - Target engine

    /// The classifier reads the target's fractional-seconds default, and only the builder knows
    /// which engine it is writing for. Built with a fixed family, a MySQL `datetime(3)` dropped to
    /// `datetime` lost its milliseconds with nothing said about it.
    func testHazardsReadTheTargetEngineFamily() throws {
        let change = SchemaChange.modifyColumn(
            old: EditableColumnDefinition(
                id: UUID(), name: "seen_at", dataType: "datetime(3)", isNullable: true, defaultValue: nil,
                autoIncrement: false, unsigned: false, comment: nil, collation: nil,
                onUpdate: nil, charset: nil, extra: nil, isPrimaryKey: false
            ),
            new: EditableColumnDefinition(
                id: UUID(), name: "seen_at", dataType: "datetime", isNullable: true, defaultValue: nil,
                autoIncrement: false, unsigned: false, comment: nil, collation: nil,
                onUpdate: nil, charset: nil, extra: nil, isPrimaryKey: false
            )
        )
        let operations: [SchemaSyncOperation] = [.alterTable(name: "visits", schema: nil, changes: [change])]

        let mysql = try builder.build(operations: operations, foreignKeysByTable: [:])
        let postgres = try SchemaSyncScriptBuilder(targetDriver: driver, targetDatabaseType: .postgresql)
            .build(operations: operations, foreignKeysByTable: [:])

        XCTAssertTrue(mysql.first?.hazards.contains { $0.kind == .lossyTypeChange } == true)
        XCTAssertFalse(postgres.first?.hazards.contains { $0.kind == .lossyTypeChange } == true)
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

    /// A statement is what the driver is sent, and the separator after it is the script's to write.
    func testEveryStatementIsSentWithoutASeparator() throws {
        let statements = try builder.build(
            operations: [.createTable(snapshot("users")), .dropTable(name: "old", schema: nil)],
            foreignKeysByTable: [:]
        )

        XCTAssertEqual(statements.map(\.sql), ["DROP TABLE old", "CREATE TABLE users"])
        XCTAssertEqual(
            SQLScriptText(databaseType: .mysql).script(statements.map(\.sql)),
            "DROP TABLE old;\nCREATE TABLE users;"
        )
    }

    /// Sent as one text, Oracle refuses a table and its index with ORA-03405 and creates neither.
    func testATableAndItsIndexGoOutAsTheStatementsTheDriverWrote() throws {
        driver.createTableStatements = ["CREATE TABLE \"T\" (\n  \"A\" NUMBER\n)", "CREATE INDEX \"I\" ON \"T\" (\"A\")"]
        let statements = try SchemaSyncScriptBuilder(targetDriver: driver, targetDatabaseType: .oracle)
            .build(operations: [.createTable(snapshot("T"))], foreignKeysByTable: [:])

        XCTAssertEqual(statements.map(\.sql), driver.createTableStatements)
        XCTAssertEqual(Set(statements.map(\.objectName)), ["T"])
        XCTAssertEqual(Set(statements.map(\.summary)).count, 1)
    }

    /// Oracle's rename plus retype is two statements in one string, which the target refuses whole.
    func testAnAlterTheDriverWritesAsTwoStatementsGoesOutAsTwo() throws {
        driver.modifyColumnSQL = "ALTER TABLE \"T\" RENAME COLUMN \"A\" TO \"B\";\nALTER TABLE \"T\" MODIFY (\"B\" NUMBER)"
        let column = { (name: String) in
            EditableColumnDefinition(
                id: UUID(), name: name, dataType: "NUMBER", isNullable: true, defaultValue: nil,
                autoIncrement: false, unsigned: false, comment: nil, collation: nil,
                onUpdate: nil, charset: nil, extra: nil, isPrimaryKey: false
            )
        }
        let statements = try SchemaSyncScriptBuilder(targetDriver: driver, targetDatabaseType: .oracle).build(
            operations: [.alterTable(name: "T", schema: nil, changes: [.modifyColumn(old: column("A"), new: column("B"))])],
            foreignKeysByTable: [:]
        )

        XCTAssertEqual(statements.map(\.sql), [
            "ALTER TABLE \"T\" RENAME COLUMN \"A\" TO \"B\"",
            "ALTER TABLE \"T\" MODIFY (\"B\" NUMBER)",
        ])
    }
}

// The listing leaves the table's schema nil while each key's `referencedSchema` names the endpoint's
// namespace: MySQL's database, PostgreSQL's schema.
@MainActor
struct CompareForeignKeyOrderTests {
    private func endpoint(database: String, schema: String?, type: DatabaseType) -> DatabaseEndpoint {
        DatabaseEndpoint(
            scope: DatabaseScope(connectionId: UUID(), database: database, schema: schema),
            connectionName: "server",
            databaseType: type,
            safeModeLevel: .silent,
            color: .blue
        )
    }

    private func mysql(_ database: String) -> CompareRunner.ReferenceNamespace {
        CompareRunner.ReferenceNamespace(
            endpoint: endpoint(database: database, schema: nil, type: .mysql),
            supportsSchemas: false,
            supportsDatabases: true
        )
    }

    private func postgres(_ schema: String) -> CompareRunner.ReferenceNamespace {
        CompareRunner.ReferenceNamespace(
            endpoint: endpoint(database: "app", schema: schema, type: .postgresql),
            supportsSchemas: true,
            supportsDatabases: true
        )
    }

    private func table(
        _ name: String,
        schema: String? = nil,
        referencing parent: String? = nil,
        in referencedSchema: String? = nil
    ) -> TableStructureSnapshot {
        let foreignKeys = parent.map { parent in
            [EditableForeignKeyDefinition(
                id: UUID(), name: "fk_\(name)_\(parent)", columns: ["\(parent)_id"],
                referencedTable: parent, referencedColumns: ["id"], referencedSchema: referencedSchema,
                onDelete: .noAction, onUpdate: .noAction
            )]
        } ?? []
        return TableStructureSnapshot(name: name, schema: schema, columns: [], foreignKeys: foreignKeys)
    }

    private func keyed(_ snapshots: TableStructureSnapshot...) -> [String: TableStructureSnapshot] {
        Dictionary(uniqueKeysWithValues: snapshots.map { ($0.qualifiedName, $0) })
    }

    private func rows(
        for table: String,
        schema: String? = nil
    ) -> (plan: DataComparePlan, statements: DataSyncStatements) {
        let qualified = schema.map { "\($0).\(table)" } ?? table
        return (
            DataComparePlan(table: table, schema: schema, columns: [], scope: DataTableScope(), isEnabled: true),
            DataSyncStatements(
                inserts: [SyncStatement(sql: "INSERT \(qualified)", objectName: qualified, summary: "")],
                deletes: [SyncStatement(sql: "DELETE \(qualified)", objectName: qualified, summary: "")]
            )
        )
    }

    @Test
    func mysqlCreatesAParentBeforeItsChild() {
        let estates = table("estates")
        let buildings = table("buildings", referencing: "estates", in: "regest")
        let foreignKeys = CompareRunner.structureForeignKeys(
            source: keyed(buildings, estates), in: mysql("regest"), target: [:], in: mysql("regest_copy")
        )

        let ordered = SchemaSyncScriptBuilder.order(
            operations: [.createTable(buildings), .createTable(estates)], foreignKeysByTable: foreignKeys
        )

        let names = ordered.map(\.tableName)
        #expect(names == ["estates", "buildings"])
    }

    /// A case-sensitive server holds `Shop` and `shop` side by side, so a key into one is not a key into the other.
    @Test
    func mysqlDatabasesThatDifferOnlyInCaseStayApart() {
        #expect(mysql("Shop").names("Shop"))
        #expect(!mysql("Shop").names("shop"))
    }

    @Test
    func mysqlDropsAChildBeforeItsParentFromTheTargetsKeys() {
        let estates = table("estates")
        let buildings = table("buildings", referencing: "estates", in: "regest_copy")
        let foreignKeys = CompareRunner.structureForeignKeys(
            source: [:], in: mysql("regest"), target: keyed(buildings, estates), in: mysql("regest_copy")
        )

        let ordered = SchemaSyncScriptBuilder.order(
            operations: [.dropTable(name: "estates", schema: nil), .dropTable(name: "buildings", schema: nil)],
            foreignKeysByTable: foreignKeys
        )

        let names = ordered.map(\.tableName)
        #expect(names == ["buildings", "estates"])
    }

    @Test
    func mysqlInsertsAParentFirstAndDeletesItLast() {
        let statements = CompareRunner.orderedAcrossTables(
            [rows(for: "buildings"), rows(for: "estates")],
            sourceSnapshots: keyed(table("buildings", referencing: "estates", in: "regest"), table("estates")),
            in: mysql("regest")
        )

        let sql = statements.map(\.sql)
        #expect(sql == ["INSERT estates", "INSERT buildings", "DELETE buildings", "DELETE estates"])
    }

    // The plan takes the endpoint's schema, so its id is qualified while the snapshot's key is bare.
    @Test
    func postgresInsertsAParentFirstWhenTheListingLeavesTheSchemaOff() {
        let statements = CompareRunner.orderedAcrossTables(
            [rows(for: "buildings", schema: "public"), rows(for: "estates", schema: "public")],
            sourceSnapshots: keyed(table("buildings", referencing: "estates", in: "public"), table("estates")),
            in: postgres("public")
        )

        let sql = statements.map(\.sql)
        #expect(sql == [
            "INSERT public.estates", "INSERT public.buildings", "DELETE public.buildings", "DELETE public.estates",
        ])
    }

    @Test
    func postgresKeysIntoTheTablesOwnSchemaKeepTheParentFirst() {
        let estates = table("estates", schema: "public")
        let buildings = table("buildings", schema: "public", referencing: "estates", in: "public")
        let foreignKeys = CompareRunner.structureForeignKeys(
            source: keyed(buildings, estates), in: postgres("public"), target: [:], in: postgres("public")
        )

        let ordered = SchemaSyncScriptBuilder.order(
            operations: [.createTable(buildings), .createTable(estates)], foreignKeysByTable: foreignKeys
        )

        let identifiers = ordered.map(\.tableIdentifier)
        #expect(identifiers == ["public.estates", "public.buildings"])
    }

    // `app` and `App` are two PostgreSQL schemas, so a key into the other one is no edge here.
    @Test
    func postgresSchemaNamesFoldOnlyWhenTheyMatchExactly() {
        let estates = table("estates")
        let buildings = table("buildings", referencing: "estates", in: "app")
        let foreignKeys = CompareRunner.structureForeignKeys(
            source: keyed(buildings, estates), in: postgres("App"), target: [:], in: postgres("App")
        )

        let ordered = SchemaSyncScriptBuilder.order(
            operations: [.createTable(buildings), .createTable(estates)], foreignKeysByTable: foreignKeys
        )

        let names = ordered.map(\.tableName)
        #expect(names == ["buildings", "estates"])
    }
}

final class SyncSafetyClassifierTests: XCTestCase {
    private let classifier = SyncSafetyClassifier()

    private func hazards(for change: SchemaChange, family: SQLTypeFamily = .mysql) -> [SyncHazard] {
        classifier.hazards(for: change, typeFamily: family)
    }

    private func column(_ name: String, _ dataType: String, nullable: Bool = true) -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(), name: name, dataType: dataType, isNullable: nullable, defaultValue: nil,
            autoIncrement: false, unsigned: false, comment: nil, collation: nil,
            onUpdate: nil, charset: nil, extra: nil, isPrimaryKey: false
        )
    }

    func testDropColumnIsRefusedByDefault() {
        let hazards = hazards(for: .deleteColumn(column("email", "varchar(255)")))

        XCTAssertEqual(hazards.first?.severity, .refusedByDefault)
        XCTAssertEqual(hazards.first?.kind, .dataLoss)
    }

    func testNarrowingTypeChangeIsRefused() {
        let hazards = hazards(for: .modifyColumn(
            old: column("name", "varchar(255)"),
            new: column("name", "varchar(50)")
        ))

        XCTAssertTrue(hazards.contains { $0.kind == .lossyTypeChange && $0.severity == .refusedByDefault })
    }

    func testWideningTypeChangeIsNotRefused() {
        let hazards = hazards(for: .modifyColumn(
            old: column("name", "varchar(50)"),
            new: column("name", "varchar(255)")
        ))

        XCTAssertFalse(hazards.contains { $0.kind == .lossyTypeChange })
    }

    func testMakingColumnNotNullIsRefused() {
        let hazards = hazards(for: .modifyColumn(
            old: column("email", "varchar(50)", nullable: true),
            new: column("email", "varchar(50)", nullable: false)
        ))

        XCTAssertTrue(hazards.contains { $0.kind == .dataLoss && $0.severity == .refusedByDefault })
    }

    func testAddColumnCarriesNoHazard() {
        XCTAssertTrue(hazards(for: .addColumn(column("nickname", "varchar(20)"))).isEmpty)
    }

    func testPrimaryKeyChangeIsRefused() {
        let hazards = hazards(for: .modifyPrimaryKey(old: ["id"], new: ["id", "tenant"]))

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

    func testTiDBPairsOnlyWithItself() {
        XCTAssertTrue(CompareSyncEngineFamily.canGenerateStructureScript(from: .tidb, to: .tidb))
        XCTAssertFalse(CompareSyncEngineFamily.canGenerateStructureScript(from: .mysql, to: .tidb))
        XCTAssertFalse(CompareSyncEngineFamily.canGenerateStructureScript(from: .tidb, to: .mariadb))
        XCTAssertFalse(CompareSyncEngineFamily.canGenerateStructureScript(from: .mysql, to: .databend))
        XCTAssertTrue(CompareSyncEngineFamily.canGenerateStructureScript(from: .oceanbase, to: .oceanbase))
        XCTAssertFalse(CompareSyncEngineFamily.canGenerateStructureScript(from: .mysql, to: .oceanbase))
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
