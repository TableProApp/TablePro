//
//  RowWriterWiringTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// Like ClickHouse, Dameng, Snowflake and Trino: it writes its own rows and builds no browse query.
private final class WriterOnlyDriver: PluginDriverStub, @unchecked Sendable {
    let writesNothing: Bool

    init(writesNothing: Bool = false) {
        self.writesNothing = writesNothing
    }

    var capabilities: PluginCapabilities { [.rowWrites, .repeatingPrimaryKey] }
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func ping() async throws {}

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
        guard !writesNothing else { return nil }
        return changes.map { change in
            PluginRowWrite(
                statement: "ALTER TABLE \(table) DELETE WHERE whole_row AND _part IN (?)",
                parameters: change.originalRow ?? [],
                rowIndices: [change.rowIndex],
                lookup: PluginRowLookup(
                    query: "SELECT _part FROM \(table) WHERE whole_row LIMIT 2",
                    parameters: change.originalRow ?? [],
                    rowCount: 1,
                    pinsRows: true
                )
            )
        }
    }
}

private final class StubDriver: PluginDriverStub, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func ping() async throws {}
}

@MainActor
struct RowWriterWiringTests {
    private func coordinator(with driver: WriterOnlyDriver) -> (MainContentCoordinator, DataChangeManager) {
        let connection = TestFixtures.makeConnection(type: .clickhouse)
        let state = SessionStateFactory.create(connection: connection, payload: nil)
        DatabaseManager.shared.injectSession(
            ConnectionSession(
                connection: connection,
                driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)
            ),
            for: connection.id
        )
        state.coordinator.setupPluginDriver()
        state.changeManager.configureForTable(
            tableName: "events",
            columns: ["d", "id", "v"],
            primaryKeyColumns: ["d"],
            databaseType: .clickhouse,
            generatedColumns: []
        )
        return (state.coordinator, state.changeManager)
    }

    // The bug in #3776: the host keyed this on the sorting key `d`, and its DELETE removed every row sharing `d`.
    @Test("A plugin that writes its rows but builds no browse query writes the grid's saves, with its lookups")
    func writerOnlyDriverWritesTheSave() throws {
        let driver = WriterOnlyDriver()
        let (coordinator, changeManager) = coordinator(with: driver)
        changeManager.recordRowDeletion(rowID: .existing(0), originalRow: ["2026-01-01", "1", "a"])

        let build = try changeManager.buildRowWrites(database: "default", schema: nil, containsTableOperation: false)

        #expect(changeManager.pluginDriver === driver)
        #expect(coordinator.queryBuilder.usesPluginDriver(nil))
        let step = try #require(build.steps.first)
        #expect(build.steps.count == 1)
        #expect(step.statement.sql == "ALTER TABLE events DELETE WHERE whole_row AND _part IN (?)")
        #expect(step.lookup?.query.sql == "SELECT _part FROM events WHERE whole_row LIMIT 2")
        #expect(step.lookup?.rowCount == 1)
        #expect(step.rowKind == .delete)
        #expect(step.expectedRowCount == nil)
    }

    @Test("Copy as UPDATE finds a row by every column where rows share the primary key")
    func repeatingPrimaryKeyNamesNoRow() {
        let connection = TestFixtures.makeConnection(type: .clickhouse)

        #expect(!PluginDriverAdapter(connection: connection, pluginDriver: WriterOnlyDriver()).primaryKeyNamesOneRow)
        #expect(PluginDriverAdapter(connection: connection, pluginDriver: StubDriver()).primaryKeyNamesOneRow)
    }

    // Copy as UPDATE matches a ClickHouse row by every column once the sorting key no longer stands in for it.
    @Test("A ClickHouse JSON, Dynamic or float column is matched through its text")
    func clickHouseTextMatchedColumns() throws {
        let curated = try #require(
            PluginMetadataRegistry.shared.builtInDefaults().first { $0.typeId == "ClickHouse" }?.snapshot
        )
        let columns = [
            "id": "UInt64", "name": "String", "doc": "JSON", "any": "Dynamic", "score": "Float64",
            "maybe": "Nullable(Float32)", "tags": "Array(String)"
        ].map { name, type in
            ColumnInfo(name: name, dataType: type, isNullable: true, isPrimaryKey: false)
        }

        #expect(
            QueryExecutor.columns(in: columns, typedAnyOf: curated.schema.rowMatchTextTypePrefixes)
                == ["doc", "any", "score", "maybe"]
        )
    }

    @Test("A plugin that writes its own rows is never handed back to the host's generator")
    func writerThatWritesNothingRefusesTheSave() {
        let (_, changeManager) = coordinator(with: WriterOnlyDriver(writesNothing: true))
        changeManager.recordRowDeletion(rowID: .existing(0), originalRow: ["2026-01-01", "1", "a"])

        #expect(throws: DataWriteError.self) {
            _ = try changeManager.buildRowWrites(database: "default", schema: nil, containsTableOperation: false)
        }
    }
}
