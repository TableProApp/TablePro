import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class LocatingDriver: PluginDriverStub, @unchecked Sendable {
    private(set) var writeContexts: [PluginRowWriteContext] = []
    private(set) var restoreContexts: [PluginRowWriteContext] = []
    var readsByLocator = false

    func buildLocatorQuery(table: String, schema: String?, locators: [String], columns: [String]) -> String? {
        readsByLocator ? "READ " + locators.joined(separator: " ") : nil
    }

    func generateRowWrites(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>,
        context: PluginRowWriteContext
    ) throws -> [PluginRowWrite]? {
        writeContexts.append(context)
        return changes.map { PluginRowWrite(statement: "WRITE", rowIndices: [$0.rowIndex]) }
    }

    func generateIdentityPreservingInsert(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        rows: [[PluginCellValue]],
        absentCells: [Int: Set<Int>],
        context: PluginRowWriteContext
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        restoreContexts.append(context)
        return rows.map { _ in (statement: "RESTORE", parameters: []) }
    }

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
}

@MainActor
struct RewindPlannerRowLocatorTests {
    private let columns = ["_id", "name"]
    private let target = DataWriteTarget(database: "shop", schema: nil, table: "users")
    private let hex = "507f1f77bcf86cd799439011"
    private var stringLocator: String { #""\#(hex)""# }
    private var objectIdLocator: String { #"{"$oid":"\#(hex)"}"# }

    private func operation(
        _ kind: RowWriteKind,
        preImage: [PluginCellValue]?,
        postImage: [PluginCellValue]?,
        locator: String?
    ) -> RowWriteOperation {
        var operation = RowWriteOperation(
            kind: kind,
            target: target,
            columns: columns,
            primaryKeyColumns: ["_id"],
            preImage: preImage,
            postImage: postImage,
            writtenColumns: kind == .update ? ["name"] : columns,
            refusal: nil
        )
        operation.rowLocator = locator
        return operation
    }

    private func planner(_ operations: [RowWriteOperation], driver: LocatingDriver) -> RewindPlanner {
        var factory = RowChangeStatementFactory(
            tableName: target.table,
            schemaName: nil,
            columns: columns,
            primaryKeyColumns: ["_id"],
            databaseType: .mongodb,
            pluginDriver: driver
        )
        factory.database = target.database
        return RewindPlanner(
            record: RewindRecord(
                id: UUID(),
                historyId: nil,
                connectionId: UUID(),
                databaseType: .mongodb,
                target: target,
                capturedAt: Date(timeIntervalSince1970: 0),
                generatedColumns: [],
                identityColumns: [],
                operations: operations
            ),
            factory: factory,
            queryBuilder: TableQueryBuilder(databaseType: .mongodb, pagination: .offset, dialectQuote: { $0 })
        )
    }

    private func current(_ name: PluginCellValue, locator: String?) -> RewindCurrentRow {
        RewindCurrentRow(values: [.text(hex), name], locator: locator)
    }

    @Test("An edit is undone on the row its locator names, and the read's twin with the same key text is ignored")
    func editIsUndoneOnItsOwnRow() throws {
        let driver = LocatingDriver()
        let update = operation(
            .update, preImage: [.text(hex), "Ada"], postImage: [.text(hex), "Grace"], locator: stringLocator
        )

        let plan = try planner([update], driver: driver).plan(currentRows: [
            current("Grace", locator: stringLocator),
            current("Other", locator: objectIdLocator)
        ])

        #expect(plan.rows.map { $0.outcome } == [.willRestore])
        let context = try #require(driver.writeContexts.first)
        #expect(context.rowLocators == [0: stringLocator])
        #expect(context.database == "shop")
    }

    @Test("A twin holding the saved values does not stand in for the row the edit changed")
    func twinIsNotTheEditedRow() throws {
        let driver = LocatingDriver()
        let update = operation(
            .update, preImage: [.text(hex), "Ada"], postImage: [.text(hex), "Grace"], locator: stringLocator
        )

        let plan = try planner([update], driver: driver).plan(currentRows: [current("Grace", locator: objectIdLocator)])

        #expect(plan.rows.map { $0.outcome } == [.rowMissing])
        #expect(driver.writeContexts.isEmpty)
    }

    @Test("A deleted row comes back with the locator it was read by, beside a twin whose key reads the same")
    func deleteIsRestoredBesideItsTwin() throws {
        let driver = LocatingDriver()
        let delete = operation(.delete, preImage: [.text(hex), "Ada"], postImage: nil, locator: stringLocator)

        let beside = try planner([delete], driver: driver)
            .plan(currentRows: [current("Other", locator: objectIdLocator)])
        let present = try planner([delete], driver: LocatingDriver())
            .plan(currentRows: [current("Ada", locator: stringLocator)])

        #expect(beside.rows.map { $0.outcome } == [.willRestore])
        #expect(present.rows.map { $0.outcome } == [.rowAlreadyPresent])
        let context = try #require(driver.restoreContexts.first)
        #expect(context.rowLocators == [0: stringLocator])
        #expect(context.database == "shop")
    }

    @Test("A read that carries no locators is matched by key, as before")
    func readWithoutLocatorsMatchesByKey() throws {
        let driver = LocatingDriver()
        let update = operation(
            .update, preImage: [.text(hex), "Ada"], postImage: [.text(hex), "Grace"], locator: stringLocator
        )

        let plan = try planner([update], driver: driver).plan(currentRows: [current("Grace", locator: nil)])

        #expect(plan.rows.map { $0.outcome } == [.willRestore])
        #expect(driver.writeContexts.first?.rowLocators == [0: stringLocator])
    }

    @Test("Undoing the restore of a deleted row deletes that row by its locator, and leaves a twin alone")
    func restoredRowIsDeletedByItsLocator() throws {
        let driver = LocatingDriver()
        let insert = operation(.insert, preImage: nil, postImage: [.text(hex), "Lin"], locator: stringLocator)

        let plan = try planner([insert], driver: driver).plan(currentRows: [current("Lin", locator: stringLocator)])
        let twinOnly = try planner([insert], driver: LocatingDriver())
            .plan(currentRows: [current("Lin", locator: objectIdLocator)])

        #expect(plan.rows.map { $0.outcome } == [.willRestore])
        #expect(driver.writeContexts.first?.rowLocators == [0: stringLocator])
        #expect(twinOnly.rows.map { $0.outcome } == [.alreadyRestored])
    }

    @Test("Rows recorded with a locator are read back by it, through the driver's own query")
    func rowsAreReadByLocator() {
        let driver = LocatingDriver()
        driver.readsByLocator = true
        let update = operation(
            .update, preImage: [.text(hex), "Ada"], postImage: [.text(hex), "Grace"], locator: stringLocator
        )
        let delete = operation(.delete, preImage: [.text(hex), "Bo"], postImage: nil, locator: objectIdLocator)

        let queries = planner([update, delete], driver: driver).readQueries()

        #expect(queries == ["READ \(stringLocator) \(objectIdLocator)"])
    }

    @Test("With a read by locator, a recorded row the read did not return is gone even when its key text is not")
    func readByLocatorNeverFallsBackToKeyText() throws {
        let driver = LocatingDriver()
        driver.readsByLocator = true
        let update = operation(
            .update, preImage: [.text(hex), "Ada"], postImage: [.text(hex), "Grace"], locator: stringLocator
        )

        let plan = try planner([update], driver: driver).plan(currentRows: [current("Grace", locator: nil)])

        #expect(plan.rows.map { $0.outcome } == [.rowMissing])
    }

    @Test("Undoing a restore names the same row again")
    func inverseKeepsTheLocator() throws {
        let update = operation(
            .update, preImage: [.text(hex), "Ada"], postImage: [.text(hex), "Grace"], locator: stringLocator
        )
        let plan = try planner([update], driver: LocatingDriver())
            .plan(currentRows: [current("Grace", locator: stringLocator)])

        #expect(RewindExecutor.inverseOperations(of: plan).map { $0.rowLocator } == [stringLocator])
    }

    @Test("A record keeps its locators through the store, and one saved before them reads none")
    func locatorSurvivesEncoding() throws {
        let delete = operation(.delete, preImage: [.text(hex), "Ada"], postImage: nil, locator: stringLocator)
        let decoded = try JSONDecoder().decode(RowWriteOperation.self, from: JSONEncoder().encode(delete))
        #expect(decoded.rowLocator == stringLocator)

        var older = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(delete)) as? [String: Any]
        )
        older.removeValue(forKey: "rowLocator")
        let legacy = try JSONDecoder().decode(
            RowWriteOperation.self, from: JSONSerialization.data(withJSONObject: older)
        )
        #expect(legacy.rowLocator == nil)
        #expect(legacy.preImage == delete.preImage)
    }

    @Test("A save records the locator of each row it edits or deletes, and none for a new row")
    func builderRecordsLocators() {
        let edit = RowChange(
            rowID: .existing(0),
            type: .update,
            cellChanges: [CellChange(columnIndex: 1, columnName: "name", oldValue: "Ada", newValue: "Grace")],
            originalRow: [.text(hex), "Ada"]
        )
        let delete = RowChange(rowID: .existing(1), type: .delete, originalRow: ["1", "Bo"])
        let insertID = RowID.inserted(UUID())
        let insert = RowChange(rowID: insertID, type: .insert)

        let operations = RowWriteOperationBuilder.operations(
            from: [edit, delete, insert],
            insertedRowData: [insertID: ["__DEFAULT__", "Lin"]],
            deletedRowIDs: [.existing(1)],
            insertedRowIDs: [insertID],
            target: target,
            columns: columns,
            primaryKeyColumns: ["_id"],
            generatedColumns: [],
            containsTableOperation: false,
            rowLocators: [.existing(0): stringLocator, .existing(1): objectIdLocator]
        )

        #expect(operations.map { $0.kind } == [.update, .delete, .insert])
        #expect(operations.map { $0.rowLocator } == [stringLocator, objectIdLocator, nil])
    }
}
