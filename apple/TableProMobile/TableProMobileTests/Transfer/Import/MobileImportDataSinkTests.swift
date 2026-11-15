import Foundation
import TableProDatabase
import TableProModels
import TableProPluginKit
import Testing

@testable import TableProMobile

// The SQLite statements the shared writer builds, without the engine lane's own dialect, so these cases test the sink.
private struct SQLiteTestDialect: MobileWriteDialect {
    let databaseTypeId = "SQLite"

    func importStatements(table: String, schema: String?, columns: [ColumnInfo]) async throws -> SQLImportStatements {
        SQLImportStatements(
            databaseTypeId: "SQLite",
            qualifiedTableName: SQLBuilder.qualifiedIdentifier(table: table, schema: schema, for: .sqlite),
            parameterStyle: .questionMark,
            quoteIdentifier: { SQLBuilder.quoteIdentifier($0, for: .sqlite) },
            columnTypeNames: Dictionary(columns.map { ($0.name, $0.typeName) }, uniquingKeysWith: { first, _ in first })
        )
    }

    func createTableStatements(definition: PluginCreateTableDefinition, schema: String?) throws -> [String] {
        throw MobileTransferRefusal(reason: "not in these tests")
    }
}

struct MobileImportDataSinkTests {
    private let directory: URL

    init() throws {
        directory = try TransferTestFolders.make("sink")
    }

    private func people(_ rows: [(Int, String)] = []) async throws -> SQLiteDriver {
        let driver = SQLiteDriver(source: .file(directory.appendingPathComponent("people.db")), openMode: .createNew)
        try await driver.connect()
        _ = try await driver.execute(query: "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT)")
        for (id, name) in rows {
            _ = try await driver.execute(query: "INSERT INTO people (id, name) VALUES (\(id), '\(name)')")
        }
        return driver
    }

    private func sink(on driver: SQLiteDriver, mode: ImportWriteMode = .insert) -> MobileImportDataSink {
        MobileImportDataSink(
            driver: driver,
            databaseType: .sqlite,
            rowTarget: MobileImportDataSink.RowTarget(
                table: "people",
                schema: nil,
                columnMapping: ["id": "id", "name": "name"],
                sourceFields: ["id", "name"],
                rowWriting: ImportRowWriting(mode: mode, keyColumns: mode == .insert ? [] : ["id"]),
                binaryText: nil
            ),
            dialect: SQLiteTestDialect()
        )
    }

    private func names(_ driver: SQLiteDriver) async throws -> [String] {
        try await driver.execute(query: "SELECT id || ':' || name FROM people ORDER BY id").rows.compactMap { $0.first ?? nil }
    }

    private func row(_ id: String, _ name: String) -> [String: PluginCellValue] {
        ["id": .text(id), "name": .text(name)]
    }

    @Test("Insert writes every row in a transaction of the import's own and commits it")
    func insertCommitsItsOwnTransaction() async throws {
        let driver = try await people()
        let sink = sink(on: driver)

        try await sink.beginTransaction()
        #expect(sink.holdsOwnTransaction)
        try await sink.insertRows([row("1", "Ada"), row("2", "Bo")])
        try await sink.commitTransaction()

        #expect(try await names(driver) == ["1:Ada", "2:Bo"])
        #expect(await sink.transactionEnding() == .committed)
        #expect(sink.rowTally?.inserted == 2)
    }

    @Test("Update changes the matched row and leaves an unmatched one out")
    func updateChangesMatchedRowsOnly() async throws {
        let driver = try await people([(1, "Ada"), (2, "Bo")])
        let sink = sink(on: driver, mode: .update)

        try await sink.insertRows([row("1", "Ann"), row("3", "Cy")])

        #expect(try await names(driver) == ["1:Ann", "2:Bo"])
        #expect(sink.rowTally?.updated == 1)
        #expect(sink.rowTally?.unmatched == 1)
    }

    @Test("Insert or Update updates the matched row and inserts the new one")
    func upsertUpdatesAndInserts() async throws {
        let driver = try await people([(1, "Ada")])
        let sink = sink(on: driver, mode: .upsert)

        try await sink.insertRows([row("1", "Ann"), row("3", "Cy")])

        #expect(try await names(driver) == ["1:Ann", "3:Cy"])
        #expect(sink.rowTally?.updated == 1)
        #expect(sink.rowTally?.inserted == 1)
    }

    @Test("Insert, Skip Existing keeps the stored row and inserts the new one")
    func skipExistingKeepsStoredRows() async throws {
        let driver = try await people([(1, "Ada")])
        let sink = sink(on: driver, mode: .insertSkippingExisting)

        try await sink.insertRows([row("1", "Ann"), row("3", "Cy")])

        #expect(try await names(driver) == ["1:Ada", "3:Cy"])
        #expect(sink.rowTally?.existing == 1)
        #expect(sink.rowTally?.inserted == 1)
    }

    @Test("Clearing the table first is refused in a mode that matches rows")
    func clearingRefusedWhenMatching() async throws {
        let driver = try await people([(1, "Ada")])
        let sink = sink(on: driver, mode: .update)
        await #expect(throws: PluginImportError.self) {
            try await sink.deleteAllRowsFromTargetTable()
        }
        #expect(try await names(driver) == ["1:Ada"])
    }

    @Test("Stop and Rollback refuses the next write and rolls back the rows the import wrote")
    func stopRollsBackOwnedRows() async throws {
        let driver = try await people([(1, "Ada")])
        let sink = sink(on: driver)
        try await sink.beginTransaction()
        try await sink.insertRows([row("2", "Bo")])

        sink.stop(.rollBack)
        await #expect(throws: PluginImportCancellationError.self) {
            try await sink.insertRows([row("3", "Cy")])
        }
        await #expect(throws: PluginImportCancellationError.self) {
            try await sink.commitTransaction()
        }
        try await sink.rollbackTransaction()

        #expect(try await names(driver) == ["1:Ada"])
        #expect(await sink.transactionEnding() == .rolledBack)
    }

    @Test("Stop and Commit skips the plugin's rollback and the run's finish keeps the rows")
    func stopAndCommitKeepsRows() async throws {
        let driver = try await people()
        let sink = sink(on: driver)
        try await sink.beginTransaction()
        try await sink.insertRows([row("1", "Ada")])

        sink.stop(.commit)
        try await sink.rollbackTransaction()
        #expect(sink.holdsOwnTransaction)
        await sink.finish(commit: true)

        #expect(try await names(driver) == ["1:Ada"])
        #expect(await sink.transactionEnding() == .committed)
    }

    // Critic M8: the import never commits or rolls back the user's transaction, and says the rows wait in it.
    @Test("An import into the user's open transaction joins it and leaves the rows there")
    func joinsTheUsersTransaction() async throws {
        let driver = try await people()
        _ = try await driver.execute(query: "BEGIN")
        let sink = sink(on: driver)

        try await sink.beginTransaction()
        #expect(sink.joinsUserTransaction)
        #expect(!sink.holdsOwnTransaction)
        try await sink.insertRows([row("1", "Ada")])
        sink.stop(.rollBack)
        try await sink.rollbackTransaction()
        await sink.finish(commit: false)

        #expect(await driver.sessionTransactionState() != .idle)
        #expect(try await names(driver) == ["1:Ada"])
        #expect(await sink.transactionEnding() == .leftInOpenTransaction)
        _ = try await driver.execute(query: "ROLLBACK")
        #expect(try await names(driver).isEmpty)
    }

    @Test("Rows written with no transaction report as kept, not rolled back")
    func noTransactionReportsKeptRows() async throws {
        let driver = try await people()
        let sink = sink(on: driver)
        try await sink.insertRow(row("1", "Ada"))
        #expect(await sink.transactionEnding() == .none)
    }

    @Test("The expiry and stop messages say where the rows are")
    func outcomeMessagesNameTheRows() {
        func outcome(_ ending: DataImportOutcome.Ending, _ transaction: ImportTransactionEnding) -> DataImportOutcome {
            DataImportOutcome(
                ending: ending, transaction: transaction, tally: nil, executedStatements: 0, skippedStatements: 0,
                errors: [], createdTable: false, catalogChanges: []
            )
        }
        #expect(outcome(.expired, .leftInOpenTransaction).transactionMessage == ImportRun.joinedTransactionMessage)
        #expect(outcome(.expired, .rolledBack).transactionMessage?.contains("rolled back") == true)
        #expect(outcome(.completed, .committed).transactionMessage == nil)
        #expect(outcome(.stopped, .none).transactionMessage != nil)
    }

    @Test("Boolean words become 1 and 0 only for a flag column on an engine whose dialect writes numbers")
    func numericBooleansFollowTheEngine() throws {
        func written(_ typeName: String, on databaseType: DatabaseType) throws -> PluginCellValue? {
            let values = ImportTargetValues(
                columns: [ColumnInfo(name: "flag", typeName: typeName)], databaseType: databaseType, binaryText: nil
            )
            return try values.values([.text("true")], columns: ["flag"]).first
        }
        #expect(try written("tinyint(1)", on: .mysql) == .text("1"))
        #expect(try written("bit", on: .mssql) == .text("1"))
        #expect(try written("boolean", on: .sqlite) == .text("1"))
        #expect(try written("boolean", on: .postgresql) == .text("true"))
        #expect(try written("BOOLEAN", on: .duckdb) == .text("true"))
        #expect(!ImportTargetValues.writesNumericBooleans(.redshift))
    }

    @Test("A CSV value in a binary column is read as bytes, and text that only starts like hex is refused")
    func binaryColumnReadsPrefixedHex() throws {
        let values = ImportTargetValues(
            columns: [ColumnInfo(name: "data", typeName: "BLOB")], databaseType: .sqlite, binaryText: .prefixedHex
        )
        #expect(try values.values([.text("0x00ff")], columns: ["data"]) == [.bytes(Data([0x00, 0xFF]))])
        #expect(throws: PluginImportError.self) {
            _ = try values.values([.text("0x0")], columns: ["data"])
        }
    }
}
