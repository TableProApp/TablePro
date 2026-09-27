//
//  FieldAbsenceWriteTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// Writes through the MongoDB plugin's own generator, so a test sees the statement the plugin
/// would send for what the host handed it.
private final class MongoGeneratorStubDriver: PluginDatabaseDriver, @unchecked Sendable {
    func generateRowWrites(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) throws -> [PluginRowWrite]? {
        try MongoDBStatementGenerator(collectionName: table, columns: columns).generateRowWrites(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        )
    }

    func generateIdentityPreservingInsert(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        rows: [[PluginCellValue]],
        absentCells: [Int: Set<Int>]
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        MongoDBStatementGenerator(collectionName: table, columns: columns)
            .generateRestore(rows: rows, absentCells: absentCells)
    }

    func quoteIdentifier(_ name: String) -> String { name }
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
}

@MainActor
struct FieldAbsenceStatementTests {
    private static let identity: PluginCellValue = "507f1f77bcf86cd799439011"
    private let columns = ["_id", "nick", "deletedAt"]

    private func factory() -> RowChangeStatementFactory {
        RowChangeStatementFactory(
            tableName: "items",
            schemaName: nil,
            columns: columns,
            primaryKeyColumns: ["_id"],
            databaseType: .mongodb,
            pluginDriver: MongoGeneratorStubDriver()
        )
    }

    @Test("Remove Field reaches the driver as a missing field, and Set NULL as a value")
    func removalAndNullReachTheDriverApart() throws {
        let change = RowChange(
            rowID: .existing(0),
            type: .update,
            cellChanges: [
                CellChange(columnIndex: 1, columnName: "nick", oldValue: "Ada", newValue: .null, newIsAbsent: true),
                CellChange(columnIndex: 2, columnName: "deletedAt", oldValue: "2024-05-01", newValue: .null)
            ],
            originalRow: [Self.identity, "Ada", "2024-05-01"]
        )

        let statements = try factory().statements(for: [change]).map(\.sql)

        #expect(statements == [
            #"db.items.updateOne({"_id": {"$oid": "507f1f77bcf86cd799439011"}}, {"$set": {"deletedAt": null}, "$unset": {"nick": ""}})"#
        ])
    }

    @Test("A new row's missing fields are left out and its NULL fields are written")
    func insertKeepsNullAndLeavesOutMissing() throws {
        let inserted = RowID.inserted(UUID())
        let change = RowChange(rowID: inserted, type: .insert, absentColumns: [1])

        let statements = try factory().statements(
            for: [change],
            insertedRowData: [inserted: ["__DEFAULT__", .null, .null]],
            insertedRowIDs: [inserted]
        ).map(\.sql)

        #expect(statements == [#"db.items.insertOne({"deletedAt": null})"#])
    }

    @Test("Every other engine is handed no missing fields")
    func otherEnginesSeeNoAbsence() {
        let keyed = PluginKeyedChanges(
            changes: [
                RowChange(
                    rowID: .existing(0), type: .update,
                    cellChanges: [CellChange(columnIndex: 1, columnName: "name", oldValue: "a", newValue: .null)],
                    originalRow: ["1", "a"]
                ),
                RowChange(rowID: .existing(1), type: .delete, originalRow: ["2", "b"])
            ],
            insertedRowData: [:],
            deletedRowIDs: [.existing(1)],
            insertedRowIDs: []
        )

        #expect(keyed.changes.allSatisfy { $0.absentColumns == nil })
    }
}

struct FieldAbsenceRewindRecordTests {
    private let target = DataWriteTarget(database: "shop", schema: nil, table: "items")
    private let columns = ["_id", "nick", "deletedAt"]

    private func operations(
        changes: [RowChange],
        insertedRowData: [RowID: [PluginCellValue]] = [:],
        deletedRowIDs: Set<RowID> = [],
        insertedRowIDs: Set<RowID> = []
    ) -> [RowWriteOperation] {
        RowWriteOperationBuilder.operations(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIDs: deletedRowIDs,
            insertedRowIDs: insertedRowIDs,
            target: target,
            columns: columns,
            primaryKeyColumns: ["_id"],
            generatedColumns: [],
            containsTableOperation: false
        )
    }

    @Test("An edit records which fields the row lacked before and after it")
    func updateRecordsAbsenceOnBothSides() throws {
        let change = RowChange(
            rowID: .existing(0),
            type: .update,
            cellChanges: [
                CellChange(columnIndex: 1, columnName: "nick", oldValue: .null, newValue: "Ada", oldIsAbsent: true),
                CellChange(columnIndex: 2, columnName: "deletedAt", oldValue: "2024", newValue: .null, newIsAbsent: true)
            ],
            originalRow: ["1", .null, "2024"],
            absentColumns: [1]
        )

        let operation = try #require(operations(changes: [change]).first)

        #expect(operation.preImageAbsentColumns == [1])
        #expect(operation.postImageAbsentColumns == [2])
    }

    @Test("A delete records what the row lacked, and a new row what it was saved without")
    func deleteAndInsertRecordAbsence() {
        let inserted = RowID.inserted(UUID())
        let result = operations(
            changes: [
                RowChange(rowID: .existing(0), type: .delete, originalRow: ["1", .null, .null], absentColumns: [2]),
                RowChange(rowID: inserted, type: .insert, absentColumns: [1])
            ],
            insertedRowData: [inserted: ["2", .null, .null]],
            deletedRowIDs: [.existing(0)],
            insertedRowIDs: [inserted]
        )

        #expect(result.first?.preImageAbsentColumns == [2])
        #expect(result.last?.postImageAbsentColumns == [1])
    }

    @Test("A record saved before absence was captured reads every NULL as a missing field, as it was rewound then")
    func legacyRecordReadsNullsAsMissing() throws {
        let current = RowWriteOperation(
            kind: .update, target: target, columns: columns, primaryKeyColumns: ["_id"],
            preImage: ["1", .null, "x"], postImage: ["1", "Ada", .null],
            writtenColumns: ["nick", "deletedAt"], refusal: nil
        )
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        json.removeValue(forKey: "preImageAbsentColumns")
        json.removeValue(forKey: "postImageAbsentColumns")

        let legacy = try JSONDecoder().decode(RowWriteOperation.self, from: JSONSerialization.data(withJSONObject: json))

        #expect(legacy.preImageAbsentColumns == nil)
        #expect(legacy.absentColumnsBeforeWrite == [1])
        #expect(legacy.absentColumnsAfterWrite == [2])
    }
}

@MainActor
struct FieldAbsenceRewindTests {
    private static let identity: PluginCellValue = "507f1f77bcf86cd799439011"
    private let columns = ["_id", "nick", "deletedAt"]
    private let target = DataWriteTarget(database: "shop", schema: nil, table: "items")

    private func planner(_ operation: RowWriteOperation) -> RewindPlanner {
        RewindPlanner(
            record: RewindRecord(
                id: UUID(), historyId: nil, connectionId: UUID(), databaseType: .mongodb,
                target: target, capturedAt: Date(timeIntervalSince1970: 0),
                generatedColumns: [], operations: [operation]
            ),
            factory: RowChangeStatementFactory(
                tableName: target.table, schemaName: nil, columns: columns,
                primaryKeyColumns: ["_id"], databaseType: .mongodb, pluginDriver: MongoGeneratorStubDriver()
            ),
            queryBuilder: TableQueryBuilder(databaseType: .mongodb, pagination: .offset)
        )
    }

    private func update(
        pre: [PluginCellValue], post: [PluginCellValue],
        preAbsent: Set<Int>?, postAbsent: Set<Int>?, written: [String]
    ) -> RowWriteOperation {
        RowWriteOperation(
            kind: .update, target: target, columns: columns, primaryKeyColumns: ["_id"],
            preImage: pre, postImage: post, writtenColumns: written, refusal: nil,
            preImageAbsentColumns: preAbsent, postImageAbsentColumns: postAbsent
        )
    }

    private func inverse(of operation: RowWriteOperation, current: RewindCurrentRow?) throws -> [String] {
        try planner(operation).plan(currentRows: current.map { [$0] } ?? []).statements.map(\.sql)
    }

    private func outcome(of operation: RowWriteOperation, current: RewindCurrentRow) throws -> RewindRowOutcome? {
        try planner(operation).plan(currentRows: [current]).rows.first?.outcome
    }

    @Test("Rewinding Remove Field puts the value back")
    func rewindOfRemovalSetsTheValue() throws {
        let operation = update(
            pre: [Self.identity, "Ada", .null], post: [Self.identity, .null, .null],
            preAbsent: [], postAbsent: [1], written: ["nick"]
        )

        let current = RewindCurrentRow(values: [Self.identity, .null, .null], absentColumns: [1])
        #expect(try inverse(of: operation, current: current) == [
            #"db.items.updateOne({"_id": {"$oid": "507f1f77bcf86cd799439011"}}, {"$set": {"nick": "Ada"}})"#
        ])
    }

    @Test("Rewinding a value typed into a missing field removes the field again")
    func rewindOfFillRemovesTheField() throws {
        let operation = update(
            pre: [Self.identity, .null, .null], post: [Self.identity, "Ada", .null],
            preAbsent: [1], postAbsent: [], written: ["nick"]
        )

        #expect(try inverse(of: operation, current: RewindCurrentRow(values: [Self.identity, "Ada", .null])) == [
            #"db.items.updateOne({"_id": {"$oid": "507f1f77bcf86cd799439011"}}, {"$unset": {"nick": ""}})"#
        ])
    }

    @Test("Rewinding an edit of a field that held NULL stores NULL again")
    func rewindOfNullFieldStoresNull() throws {
        let operation = update(
            pre: [Self.identity, .null, .null], post: [Self.identity, "Ada", .null],
            preAbsent: [], postAbsent: [], written: ["nick"]
        )

        #expect(try inverse(of: operation, current: RewindCurrentRow(values: [Self.identity, "Ada", .null])) == [
            #"db.items.updateOne({"_id": {"$oid": "507f1f77bcf86cd799439011"}}, {"$set": {"nick": null}})"#
        ])
    }

    @Test("Rewinding a delete puts NULL fields back as null and leaves missing fields out")
    func rewindOfDeleteKeepsNullAndMissingApart() throws {
        let operation = RowWriteOperation(
            kind: .delete, target: target, columns: columns, primaryKeyColumns: ["_id"],
            preImage: [Self.identity, .null, .null], postImage: nil, writtenColumns: columns, refusal: nil,
            preImageAbsentColumns: [1]
        )

        #expect(try inverse(of: operation, current: nil) == [
            #"db.items.insertOne({"_id": {"$oid": "507f1f77bcf86cd799439011"}, "deletedAt": null})"#
        ])
    }

    @Test("Rewinding Set NULL on a missing field removes the field again, though the value never changed")
    func rewindOfNullOverMissingFieldRemovesIt() throws {
        let operation = update(
            pre: [Self.identity, .null, .null], post: [Self.identity, .null, .null],
            preAbsent: [1], postAbsent: [], written: ["nick"]
        )

        #expect(try inverse(of: operation, current: RewindCurrentRow(values: [Self.identity, .null, .null])) == [
            #"db.items.updateOne({"_id": {"$oid": "507f1f77bcf86cd799439011"}}, {"$unset": {"nick": ""}})"#
        ])
    }

    @Test("Rewinding Remove Field on a NULL field stores null again, though the value never changed")
    func rewindOfRemovalOfNullStoresNull() throws {
        let operation = update(
            pre: [Self.identity, .null, .null], post: [Self.identity, .null, .null],
            preAbsent: [], postAbsent: [1], written: ["nick"]
        )
        let current = RewindCurrentRow(values: [Self.identity, .null, .null], absentColumns: [1])

        #expect(try inverse(of: operation, current: current) == [
            #"db.items.updateOne({"_id": {"$oid": "507f1f77bcf86cd799439011"}}, {"$set": {"nick": null}})"#
        ])
    }

    @Test("A field set to NULL since the save is a change, not the missing field the rewind would restore")
    func presenceChangedSinceTheSaveIsAConflict() throws {
        let filled = update(
            pre: [Self.identity, .null, .null], post: [Self.identity, "Ada", .null],
            preAbsent: [1], postAbsent: [], written: ["nick"]
        )

        let nulled = RewindCurrentRow(values: [Self.identity, .null, .null])
        let missing = RewindCurrentRow(values: [Self.identity, .null, .null], absentColumns: [1])
        #expect(try outcome(of: filled, current: nulled) == .changedSinceSave)
        #expect(try outcome(of: filled, current: missing) == .alreadyRestored)
    }

    @Test("A new document whose left-out field has been added since is a change")
    func insertComparesPresence() throws {
        let inserted = RowWriteOperation(
            kind: .insert, target: target, columns: columns, primaryKeyColumns: ["_id"],
            preImage: nil, postImage: [Self.identity, .null, .null], writtenColumns: columns, refusal: nil,
            postImageAbsentColumns: [1]
        )

        let untouched = RewindCurrentRow(values: [Self.identity, .null, .null], absentColumns: [1])
        let nickAdded = RewindCurrentRow(values: [Self.identity, .null, .null])
        #expect(try outcome(of: inserted, current: untouched) == .willRestore)
        #expect(try outcome(of: inserted, current: nickAdded) == .changedSinceSave)
    }
}

struct RewindCurrentRowTests {
    private static let identity: PluginCellValue = "507f1f77bcf86cd799439011"

    private func result(columns: [String], rows: [[PluginCellValue]], absentCells: [Int: Set<Int>] = [:]) -> QueryResult {
        var result = QueryResult(
            columns: columns,
            columnTypes: columns.map { _ in .text(rawType: nil) },
            rows: rows,
            rowsAffected: 0,
            executionTime: 0,
            error: nil
        )
        result.absentCells = absentCells
        return result
    }

    @Test("Documents read back line up with the record by field name, and a field none returned is missing")
    func documentsAlignByName() {
        let read = result(
            columns: ["_id", "deletedAt"],
            rows: [[Self.identity, .null], [Self.identity, .null]],
            absentCells: [1: [1]]
        )

        let rows = RewindCurrentRow.rows(of: read, alignedTo: ["_id", "nick", "deletedAt"], matchingByName: true)

        #expect(rows == [
            RewindCurrentRow(values: [Self.identity, .null, .null], absentColumns: [1]),
            RewindCurrentRow(values: [Self.identity, .null, .null], absentColumns: [1, 2])
        ])
    }

    @Test("Fields read back in another order are put in the recorded order")
    func documentsAreReordered() {
        let read = result(columns: ["nick", "_id"], rows: [["Ada", Self.identity]])

        let rows = RewindCurrentRow.rows(of: read, alignedTo: ["_id", "nick"], matchingByName: true)

        #expect(rows == [RewindCurrentRow(values: [Self.identity, "Ada"])])
    }

    @Test("A SQL read is already in the recorded order and has no missing fields")
    func sqlRowsStayAsRead() {
        let read = result(columns: ["ID", "NAME"], rows: [["7", .null]])

        let rows = RewindCurrentRow.rows(of: read, alignedTo: ["id", "name"], matchingByName: false)

        #expect(rows == [RewindCurrentRow(values: ["7", .null])])
    }
}

@MainActor
struct FieldAbsenceSidebarSaveTests {
    private static let identity: PluginCellValue = "507f1f77bcf86cd799439011"

    private func makeCoordinator() -> MainContentCoordinator {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(type: .mongodb),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        var tab = QueryTab(title: "items", query: "db.items.find({})", tabType: .table, tableName: "items")
        tab.execution.lastExecutedAt = Date()
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id

        coordinator.setActiveTableRows(
            TableRows.from(
                queryRows: [[Self.identity, "Ada", .null]],
                columns: ["_id", "nick", "deletedAt"],
                columnTypes: Array(repeating: .text(rawType: nil), count: 3),
                hasAuthoritativeSchema: true,
                absentCells: [0: [2]]
            ),
            for: tab.id
        )
        coordinator.changeManager.configureForTable(
            tableName: "items",
            columns: ["_id", "nick", "deletedAt"],
            primaryKeyColumns: ["_id"],
            databaseType: .mongodb,
            generatedColumns: []
        )
        coordinator.changeManager.pluginDriver = MongoGeneratorStubDriver()
        coordinator.selectionState.indices = [0]
        return coordinator
    }

    @Test("An inspector save of Remove Field removes the field rather than storing null in it")
    func removalIsWrittenAsARemoval() throws {
        let statements = try makeCoordinator().sidebarEditStatements(editedFields: [
            InspectorFieldEdit(columnIndex: 1, columnName: "nick", newValue: nil, removesField: true)
        ])

        #expect(statements.map(\.sql) == [
            #"db.items.updateOne({"_id": {"$oid": "507f1f77bcf86cd799439011"}}, {"$unset": {"nick": ""}})"#
        ])
    }

    @Test("An inspector save of NULL into a missing field stores null in it")
    func nullIntoMissingFieldIsStored() throws {
        let statements = try makeCoordinator().sidebarEditStatements(editedFields: [
            InspectorFieldEdit(columnIndex: 2, columnName: "deletedAt", newValue: nil)
        ])

        #expect(statements.map(\.sql) == [
            #"db.items.updateOne({"_id": {"$oid": "507f1f77bcf86cd799439011"}}, {"$set": {"deletedAt": null}})"#
        ])
    }
}
