//
//  RowChangeStatementFactoryCoverageTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private struct UnrelatedDriverError: Error, LocalizedError {
    var errorDescription: String? { "socket closed" }
}

@MainActor
struct RowChangeStatementFactoryCoverageTests {
    private let columns = ["_id", "name"]

    private func factory(
        table: String = "items",
        columns: [String]? = nil,
        databaseType: DatabaseType = DatabaseType(rawValue: "MongoDB"),
        driver: (any PluginDatabaseDriver)?
    ) -> RowChangeStatementFactory {
        RowChangeStatementFactory(
            tableName: table,
            schemaName: nil,
            columns: columns ?? self.columns,
            primaryKeyColumns: ["_id"],
            databaseType: databaseType,
            pluginDriver: driver
        )
    }

    private func nameEdit(row: Int = 0) -> RowChange {
        RowChange(
            rowID: .existing(row),
            type: .update,
            cellChanges: [CellChange(columnIndex: 1, columnName: "name", oldValue: "a", newValue: "z")],
            originalRow: [.text("\(row)"), "a"]
        )
    }

    private let personColumns = ["_id", "identifiers", "identifiers.type", "personId"]

    /// The Elasticsearch driver as the host reaches it: its generator's own `generateRowWrites`,
    /// which writes a nested array through its parent column and refuses a value typed into a leaf.
    private func elasticsearchDriver() -> RowWriteStubDriver {
        let generator = ElasticsearchStatementGenerator(
            index: "persons",
            columns: personColumns,
            columnTypeNames: ["keyword", "nested", "keyword", "keyword"]
        )
        return RowWriteStubDriver { changes, insertedRowData, deletedRowIndices, insertedRowIndices in
            try generator.generateRowWrites(
                from: changes,
                insertedRowData: insertedRowData,
                deletedRowIndices: deletedRowIndices,
                insertedRowIndices: insertedRowIndices
            )
        }
    }

    private let nestedLeafReason = "'identifiers.type' is a field of a nested array. Edit the array in 'identifiers' instead."

    private func personEdit(_ cells: [CellChange]) -> RowChange {
        RowChange(
            rowID: .existing(0),
            type: .update,
            cellChanges: cells,
            originalRow: ["doc1", "[{\"type\":\"CPF\"}]", "[\"CPF\"]", "p1"]
        )
    }

    private var leafEdit: CellChange {
        CellChange(columnIndex: 2, columnName: "identifiers.type", oldValue: "[\"CPF\"]", newValue: "[\"X\"]")
    }

    private var personIdEdit: CellChange {
        CellChange(columnIndex: 3, columnName: "personId", oldValue: "p1", newValue: "p2")
    }

    private func writesOnlyUpdates() -> RowWriteStubDriver {
        RowWriteStubDriver { changes, _, _, _ in
            changes.filter { $0.type == .update }.map {
                PluginRowWrite(statement: "updateOne(\($0.rowIndex))", rowIndices: [$0.rowIndex])
            }
        }
    }

    // MARK: - A driver that adopts generateRowWrites

    @Test("A driver that names nothing for a new row refuses the whole save")
    func driverLeavingOutANewRowRefusesTheSave() {
        let inserted = RowID.inserted(UUID())
        let changes = [nameEdit(), RowChange(rowID: inserted, type: .insert)]

        #expect(throws: DataWriteError.changesNotWritable(table: "items", unwritten: UnwrittenRowCounts(inserts: 1))) {
            _ = try factory(driver: writesOnlyUpdates()).statements(
                for: changes, insertedRowData: [inserted: [.null, .null]], insertedRowIDs: [inserted]
            )
        }
    }

    @Test("The refusal says which kind of change cannot be written, and how many")
    func coverageRefusalNamesTheKindAndCount() {
        let error = DataWriteError.changesNotWritable(table: "items", unwritten: UnwrittenRowCounts(inserts: 1))
        #expect(error.errorDescription == "Cannot save changes to 'items'. The driver cannot write a new row.")

        let several = DataWriteError.changesNotWritable(
            table: "items", unwritten: UnwrittenRowCounts(updates: 2, deletes: 1)
        )
        #expect(
            several.errorDescription
                == "Cannot save changes to 'items'. The driver cannot write 2 edited rows. The driver cannot delete a row marked for deletion."
        )
        #expect(several.recoverySuggestion?.hasPrefix("Nothing was saved") == true)
    }

    @Test("A driver's refusal reaches the user with its reason and the kind of change it refused")
    func driverRefusalReachesTheUser() throws {
        let inserted = RowID.inserted(UUID())
        let driver = RowWriteStubDriver { _, _, _, _ in
            throw PluginRowWriteRefusal(rowIndex: 1, reason: "A document needs at least one field.")
        }

        do {
            _ = try factory(driver: driver).statements(
                for: [nameEdit(), RowChange(rowID: inserted, type: .insert)],
                insertedRowData: [inserted: [.null, .null]],
                insertedRowIDs: [inserted]
            )
            Issue.record("the save was not refused")
        } catch let error as DataWriteError {
            #expect(error == .changeRefused(table: "items", kind: .insert, reason: "A document needs at least one field."))
            #expect(error.errorDescription == "Cannot save the new row in 'items'. A document needs at least one field.")
        }
    }

    @Test("Any other error a driver throws while writing still refuses the save")
    func unrelatedDriverErrorRefusesTheSave() {
        let driver = RowWriteStubDriver { _, _, _, _ in throw UnrelatedDriverError() }

        #expect(throws: DataWriteError.changeRefused(table: "items", kind: nil, reason: "socket closed")) {
            _ = try factory(driver: driver).statements(for: [nameEdit()])
        }
    }

    @Test("A write naming a row that is not in the save covers nothing")
    func aWriteNamingNoPendingChangeCoversNothing() {
        let driver = RowWriteStubDriver { _, _, _, _ in
            [PluginRowWrite(statement: "updateOne(7)", rowIndices: [7])]
        }

        #expect(throws: DataWriteError.changesNotWritable(table: "items", unwritten: UnwrittenRowCounts(updates: 1))) {
            _ = try factory(driver: driver).statements(for: [nameEdit()])
        }
    }

    @Test("A driver that writes every change gets its statements back as written")
    func completeDriverWriteIsKept() throws {
        let statements = try factory(driver: writesOnlyUpdates()).statements(for: [nameEdit(row: 0), nameEdit(row: 1)])
        #expect(statements.map(\.sql) == ["updateOne(0)", "updateOne(1)"])
    }

    // MARK: - A driver built before generateRowWrites

    @Test("A driver built before row writes is still held to every change, which is the save from #3132")
    func driverBuiltBeforeRowWritesIsHeldToEveryChange() {
        let driver = LegacyStatementStubDriver(generator: DocumentStyleGenerator.statements)
        let inserted = RowID.inserted(UUID())

        #expect(throws: DataWriteError.changesNotWritable(table: "items", unwritten: UnwrittenRowCounts(inserts: 1))) {
            _ = try factory(driver: driver).statements(
                for: [nameEdit(), RowChange(rowID: inserted, type: .insert)],
                insertedRowData: [inserted: [.null, .null]],
                insertedRowIDs: [inserted]
            )
        }
    }

    @Test("A driver built before row writes runs exactly the statements it batched itself")
    func driverBuiltBeforeRowWritesKeepsItsOwnStatements() throws {
        let driver = LegacyStatementStubDriver(generator: DocumentStyleGenerator.statements)
        let deletes = [
            RowChange(rowID: .existing(0), type: .delete, originalRow: ["0", "a"]),
            RowChange(rowID: .existing(1), type: .delete, originalRow: ["1", "b"]),
            RowChange(rowID: .existing(2), type: .delete, originalRow: ["2", "c"])
        ]

        let statements = try factory(driver: driver).statements(
            for: deletes, deletedRowIDs: [.existing(0), .existing(1), .existing(2)]
        )

        #expect(statements.map(\.sql) == ["deleteMany(3)"])
    }

    @Test("The default for an older driver hands each per-change call only that change's row")
    func defaultStaysLinearInTheSizeOfTheSave() throws {
        let driver = LegacyStatementStubDriver(generator: DocumentStyleGenerator.statements)
        let rowCount = 2_000
        let rowIDs = (0..<rowCount).map { _ in RowID.inserted(UUID()) }
        var rowData: [RowID: [PluginCellValue]] = [:]
        for rowID in rowIDs {
            rowData[rowID] = ["x", "y"]
        }

        let statements = try factory(driver: driver).statements(
            for: rowIDs.map { RowChange(rowID: $0, type: .insert) },
            insertedRowData: rowData,
            insertedRowIDs: Set(rowIDs)
        )

        #expect(statements.count == rowCount)
        #expect(driver.generateCallCount == rowCount + 1)
        #expect(driver.rowsHanded == rowCount * 3 * 2)
    }

    @Test("The default asks about each change once, however many values it edits")
    func defaultAsksAboutEachChangeOnce() throws {
        let driver = LegacyStatementStubDriver(generator: DocumentStyleGenerator.statements)
        let rowCount = 1_000
        let edits = (0..<rowCount).map { row in
            RowChange(
                rowID: .existing(row),
                type: .update,
                cellChanges: [
                    CellChange(columnIndex: 1, columnName: "name", oldValue: "a", newValue: "z"),
                    CellChange(columnIndex: 2, columnName: "note", oldValue: "b", newValue: "y")
                ],
                originalRow: [.text("\(row)"), "a", "b"]
            )
        }

        let statements = try factory(columns: ["_id", "name", "note"], driver: driver).statements(for: edits)

        #expect(statements.count == rowCount)
        #expect(driver.generateCallCount == 1 + rowCount)
        #expect(driver.cellsHanded == rowCount * 2 * 2)
    }

    @Test("An edit to a nested leaf beside a writable edit refuses the save and names the leaf")
    func elasticsearchMixedEditRefusesTheLeafItWouldDrop() {
        let refusal = DataWriteError.changeRefused(table: "persons", kind: .update, reason: nestedLeafReason)
        #expect(throws: refusal) {
            _ = try factory(
                table: "persons", columns: personColumns,
                databaseType: DatabaseType(rawValue: "Elasticsearch"), driver: elasticsearchDriver()
            ).statements(for: [personEdit([leafEdit, personIdEdit])])
        }
        #expect(
            refusal.errorDescription
                == "Cannot save the edited row in 'persons'. \(nestedLeafReason)"
        )
    }

    @Test("A new Elasticsearch row with only a nested leaf typed is refused rather than saved empty")
    func elasticsearchNewRowWithOnlyALeafIsRefused() {
        let inserted = RowID.inserted(UUID())
        let change = RowChange(
            rowID: inserted,
            type: .insert,
            cellChanges: [CellChange(columnIndex: 2, columnName: "identifiers.type", oldValue: nil, newValue: "[\"X\"]")]
        )

        #expect(throws: DataWriteError.changeRefused(table: "persons", kind: .insert, reason: nestedLeafReason)) {
            _ = try factory(
                table: "persons", columns: personColumns,
                databaseType: DatabaseType(rawValue: "Elasticsearch"), driver: elasticsearchDriver()
            ).statements(
                for: [change],
                insertedRowData: [inserted: [.null, .null, "[\"X\"]", .null]],
                insertedRowIDs: [inserted]
            )
        }
    }

    @Test("An edit the driver writes in every value keeps the one statement the driver wrote for it")
    func elasticsearchEditWrittenInFullIsKept() throws {
        let parentEdit = CellChange(
            columnIndex: 1, columnName: "identifiers",
            oldValue: "[{\"type\":\"CPF\"}]", newValue: "[{\"type\":\"X\"}]"
        )

        let statements = try factory(
            table: "persons", columns: personColumns,
            databaseType: DatabaseType(rawValue: "Elasticsearch"), driver: elasticsearchDriver()
        ).statements(for: [personEdit([parentEdit, personIdEdit])])

        try #require(statements.count == 1)
        let body = ElasticsearchStatementGenerator.decode(statements[0].sql)?.body
        #expect(body?.contains("\"personId\":\"p2\"") == true)
        #expect(body?.contains("\"identifiers\":[{\"type\":\"X\"}]") == true)
    }

    @Test("A Redis Value edit on a list key refuses the save even beside a TTL edit it could write")
    func redisMixedEditRefusesTheValueItWouldDrop() {
        let generator = RedisStatementGenerator(namespaceName: "0", columns: ["Key", "Type", "TTL", "Length", "Value"])
        let driver = RowWriteStubDriver { changes, insertedRowData, deletedRowIndices, insertedRowIndices in
            try generator.generateRowWrites(
                from: changes,
                insertedRowData: insertedRowData,
                deletedRowIndices: deletedRowIndices,
                insertedRowIndices: insertedRowIndices
            )
        }
        let edit = RowChange(
            rowID: .existing(0),
            type: .update,
            cellChanges: [
                CellChange(columnIndex: 4, columnName: "Value", oldValue: "[\"a\"]", newValue: "[\"b\"]"),
                CellChange(columnIndex: 2, columnName: "TTL", oldValue: "-1", newValue: "60")
            ],
            originalRow: ["mylist", "list", "-1", "1", "[\"a\"]"]
        )
        let reason = "The value of a list key cannot be edited in the grid. Change it with a command in the query editor."

        #expect(throws: DataWriteError.changeRefused(table: "0", kind: .update, reason: reason)) {
            _ = try factory(
                table: "0", columns: ["Key", "Type", "TTL", "Length", "Value"],
                databaseType: .redis, driver: driver
            ).statements(for: [edit])
        }
    }

    @Test("A driver built before row writes that returns nil still hands generation to the host")
    func legacyNilStillMeansTheHostGenerates() throws {
        let driver = LegacyStatementStubDriver { _, _, _, _ in nil }

        let statements = try factory(databaseType: .mysql, driver: driver).statements(for: [nameEdit()])

        #expect(statements.map(\.sql) == ["UPDATE \"items\" SET \"name\" = ? WHERE \"_id\" = ?"])
    }

    // MARK: - Ownership

    @Test("A driver that refuses the ownership probe still owns statement generation")
    func ownershipProbeTreatsARefusalAsDriverOwned() {
        let refusing = RowWriteStubDriver { _, _, _, _ in
            throw PluginRowWriteRefusal(rowIndex: 0, reason: "no")
        }
        #expect(factory(driver: refusing).pluginOwnsStatementGeneration)
        #expect(factory(driver: writesOnlyUpdates()).pluginOwnsStatementGeneration)
        #expect(!factory(driver: LegacyStatementStubDriver { _, _, _, _ in nil }).pluginOwnsStatementGeneration)
        #expect(!factory(driver: nil).pluginOwnsStatementGeneration)
    }

    // MARK: - The host generator

    @Test("A new row the host has no statement for is refused rather than dropped from the save")
    func hostAllDefaultsInsertItCannotSpellIsRefused() throws {
        let engine = DatabaseType(rawValue: "ProbeEngine")
        let hostOnly = LegacyStatementStubDriver { _, _, _, _ in nil }
        let inserted = RowID.inserted(UUID())
        let allDefaults: [PluginCellValue] = [.text("__DEFAULT__"), .text("__DEFAULT__")]
        let changes = [nameEdit(), RowChange(rowID: inserted, type: .insert)]

        let generator = try SQLStatementGenerator(
            tableName: "t", columns: columns, primaryKeyColumns: ["_id"], databaseType: engine,
            quoteIdentifier: hostOnly.quoteIdentifier
        )
        let generated = generator.generateAttributedStatements(
            from: changes, insertedRowData: [inserted: allDefaults], deletedRowIDs: [], insertedRowIDs: [inserted]
        )
        #expect(generated.map(\.kind) == [.update])

        #expect(throws: DataWriteError.rowsNotIdentifiable("t", .insert)) {
            _ = try factory(table: "t", databaseType: engine, driver: hostOnly).statements(
                for: changes, insertedRowData: [inserted: allDefaults], insertedRowIDs: [inserted]
            )
        }
    }

    @Test("A host delete statement carries every row it deletes")
    func hostDeleteBatchNamesEveryRow() throws {
        let rows: [RowID] = [.existing(0), .existing(1), .existing(2)]
        let deletes = rows.enumerated().map { offset, rowID in
            RowChange(rowID: rowID, type: .delete, originalRow: [.text("\(offset)"), "n"])
        }

        let written = try factory(databaseType: .mysql, driver: nil).rowWriteStatements(
            for: deletes, deletedRowIDs: Set(rows)
        )

        guard case .counted(let statements) = written else {
            Issue.record("the host's statements came back uncounted")
            return
        }
        #expect(statements.count == 1)
        #expect(statements.first?.rowIDs == rows)
        #expect(statements.first?.rowCount == 3)
    }

    @Test("An update with nothing to write is not a pending change")
    func updateWithNoCellsIsNotPending() throws {
        let empty = RowChange(rowID: .existing(0), type: .update, originalRow: ["0", "a"])
        let statements = try factory(databaseType: .mysql, driver: nil).statements(for: [empty])
        #expect(statements.isEmpty)
    }

    // MARK: - The save plan

    @Test("A driver's statements run with no row count to hold the server to")
    func buildRowWritesNeverCountsADriverStatement() throws {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "items", columns: columns, primaryKeyColumns: ["_id"],
            databaseType: DatabaseType(rawValue: "MongoDB"), generatedColumns: []
        )
        manager.pluginDriver = writesOnlyUpdates()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "a", newValue: "z", originalRow: ["0", "a"]
        )

        let build = try manager.buildRowWrites(database: "d", schema: nil, containsTableOperation: false)

        #expect(build.steps.map(\.statement.sql) == ["updateOne(0)"])
        #expect(build.steps.allSatisfy { $0.expectedRowCount == nil })
    }

    @Test("Preview SQL and Save both refuse the same mixed set")
    func buildRowWritesRefusesWhatGenerateSQLRefuses() {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "items", columns: columns, primaryKeyColumns: ["_id"],
            databaseType: DatabaseType(rawValue: "MongoDB"), generatedColumns: []
        )
        manager.pluginDriver = LegacyStatementStubDriver(generator: DocumentStyleGenerator.statements)
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "a", newValue: "z", originalRow: ["0", "a"]
        )
        manager.recordRowInsertion(rowID: .inserted(UUID()), values: [.null, .null])

        let expected = DataWriteError.changesNotWritable(table: "items", unwritten: UnwrittenRowCounts(inserts: 1))
        #expect(throws: expected) { _ = try manager.generateSQL() }
        #expect(throws: expected) {
            _ = try manager.buildRowWrites(database: "d", schema: nil, containsTableOperation: false)
        }
    }
}
