//
//  RowGenerationSessionTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import TableProTestSupport
import Testing

@testable import TablePro

@MainActor
private final class RecordingRowSource: RowGenerationDataSource {
    var table: RowGenerationTable
    var booleanStyle: RowGenerationBooleanStyle = .words
    var uniqueNullsAreDistinct = true
    var gateAfterFirstBatch: AsyncGate?
    var failure: (any Error)?
    private(set) var inserted: [[PluginCellValue]] = []
    private(set) var insertedColumns: [String] = []

    init(table: RowGenerationTable) {
        self.table = table
    }

    func loadTable() async throws -> RowGenerationTable {
        table
    }

    func insert(
        engine: RowGenerationEngine,
        rowCount: Int,
        progress: @escaping @MainActor @Sendable (Int) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> Int {
        if let failure { throw failure }
        insertedColumns = engine.columnNames
        var written = 0
        while written < rowCount {
            if isCancelled() { throw RowGenerationWriteError(underlying: nil, keptRows: 0) }
            let batch = try engine.nextRows(min(100, rowCount - written))
            inserted += batch
            written += batch.count
            progress(written)
            if written == batch.count, let gate = gateAfterFirstBatch { await gate.wait() }
        }
        return written
    }

    func insertScript(columns: [String], rows: [[PluginCellValue]]) throws -> String {
        "\(columns.joined(separator: ",")):\(rows.count)"
    }
}

@MainActor
struct RowGenerationSessionTests {
    private let suite: EphemeralDefaults

    init() throws {
        suite = try EphemeralDefaults()
    }

    private static let scope = TableScope(connectionId: UUID(), database: "shop", schema: "public", table: "people")

    private static let table = RowGenerationTable(
        columns: [
            RowGenerationColumn(name: "id", typeName: "int", valueClass: .integer(minimum: -2_147_483_648, maximum: 2_147_483_647), isNullable: false, isUnique: true),
            RowGenerationColumn(name: "email", typeName: "varchar(120)", valueClass: .text(maxLength: 120), isNullable: false),
            RowGenerationColumn(name: "status", typeName: "status", valueClass: .enumeration(["new", "paid"]), isNullable: false)
        ],
        keyMaximums: ["id": 10]
    )

    private func makeSession(
        _ source: RecordingRowSource,
        onOpenScript: @escaping (String) -> Void = { _ in }
    ) async -> RowGenerationSession {
        let session = RowGenerationSession(
            tableName: "people",
            scopeDescription: "shop.public",
            scope: Self.scope,
            dataSource: source,
            store: RowGenerationSettingsStore(defaults: suite.defaults),
            onOpenScript: onOpenScript
        )
        await session.loadIfNeeded()
        return session
    }

    @Test("Loading picks each column's generator and selects the first column")
    func loadAppliesDefaults() async {
        let session = await makeSession(RecordingRowSource(table: Self.table))

        #expect(session.phase == .configuring)
        #expect(session.selectedColumnName == "id")
        #expect(session.columnSettings("id")?.kind == .sequence)
        #expect(session.columnSettings("id")?.integerMinimum == 11)
        #expect(session.columnSettings("email")?.kind == .email)
        #expect(session.columnSettings("status")?.values == ["new", "paid"])
        #expect(session.issues.isEmpty)
    }

    @Test("The preview shows the first rows the run would insert")
    func previewMatchesTheRun() async throws {
        let source = RecordingRowSource(table: Self.table)
        let session = await makeSession(source)
        session.settings.rowCount = 25
        let preview = try #require(try session.preview?.get())

        session.start()
        await session.runTask?.value

        #expect(preview.columns == ["id", "email", "status"])
        #expect(preview.rows.count == RowGenerationSession.previewRowCount)
        #expect(Array(source.inserted.prefix(RowGenerationSession.previewRowCount)) == preview.rows)
        #expect(session.phase == .finished(.inserted(25)))
        #expect(source.inserted.count == 25)
    }

    @Test("A run saves the settings, and the next session for the table starts from them")
    func settingsAreRememberedPerTable() async {
        let first = await makeSession(RecordingRowSource(table: Self.table))
        first.settings.rowCount = 7
        first.settings.seed = 1_234
        first.updateColumn("email") { $0.kind = .text }
        first.start()
        await first.runTask?.value

        let second = await makeSession(RecordingRowSource(table: Self.table))

        #expect(second.settings.rowCount == 7)
        #expect(second.settings.seed == 1_234)
        #expect(second.columnSettings("email")?.kind == .text)
    }

    @Test("A remembered key sequence moves past rows added since, so a second run does not collide")
    func rememberedSequenceMovesPastNewRows() async {
        let first = await makeSession(RecordingRowSource(table: Self.table))
        first.start()
        await first.runTask?.value

        let grown = RowGenerationTable(columns: Self.table.columns, keyMaximums: ["id": 110])
        let second = await makeSession(RecordingRowSource(table: grown))

        #expect(second.columnSettings("id")?.integerMinimum == 111)
    }

    @Test("Edit Settings after a run continues a key sequence after the rows it added")
    func sequenceContinuesAfterARun() async {
        let session = await makeSession(RecordingRowSource(table: Self.table))
        session.settings.rowCount = 40

        session.start()
        await session.runTask?.value
        session.editSettings()

        #expect(session.phase == .configuring)
        #expect(session.columnSettings("id")?.integerMinimum == 51)
    }

    @Test("A remembered generator the column's type no longer takes gives way to the default")
    func staleGeneratorFallsBack() async {
        let store = RowGenerationSettingsStore(defaults: suite.defaults)
        var saved = RowGenerationSettings(seed: 5, columns: [:])
        saved.columns["status"] = RowGeneratorSettings(kind: .email, dateStart: Date(), dateEnd: Date())
        store.save(saved, for: Self.scope)

        let session = await makeSession(RecordingRowSource(table: Self.table))

        #expect(session.columnSettings("status")?.kind == .list)
        #expect(session.settings.seed == 5)
    }

    @Test("Cancel stops the run between batches and reports what was kept")
    func cancelStopsTheRun() async {
        let source = RecordingRowSource(table: Self.table)
        let gate = AsyncGate()
        source.gateAfterFirstBatch = gate
        let session = await makeSession(source)
        session.settings.rowCount = 500

        session.start()
        await gate.arrived(1)
        #expect(session.phase == .running)
        #expect(session.writtenRows == 100)
        session.cancel()
        await gate.open()
        await session.runTask?.value

        #expect(session.phase == .finished(.cancelled(keptRows: 0)))
        #expect(source.inserted.count == 100)
    }

    @Test("Declining the Safe Mode prompt returns to the settings")
    func declinedPromptReturnsToSettings() async {
        let source = RecordingRowSource(table: Self.table)
        source.failure = ExecutionGateError.cancelledByUser("no")
        let session = await makeSession(source)

        session.start()
        await session.runTask?.value

        #expect(session.phase == .configuring)
    }

    @Test("A failed run reports the server's message and how many rows stayed")
    func failureIsReported() async {
        let source = RecordingRowSource(table: Self.table)
        source.failure = RowGenerationWriteError(underlying: DatabaseError.queryFailed("duplicate key"), keptRows: 0)
        let session = await makeSession(source)

        session.start()
        await session.runTask?.value

        #expect(session.phase == .finished(.failed(message: "duplicate key", keptRows: 0)))
    }

    @Test("Open in Query Editor hands over the statements, and only up to its row limit")
    func scriptGoesToTheEditor() async throws {
        var opened: String?
        let session = await makeSession(RecordingRowSource(table: Self.table)) { opened = $0 }
        session.settings.rowCount = 30

        try session.openScript()
        #expect(opened == "id,email,status:30")

        session.settings.rowCount = RowGenerationSession.scriptRowLimit + 1
        #expect(!session.canOpenScript)
        #expect(session.canGenerate)
    }

    @Test("Settings with a problem disable Generate and hide the preview")
    func issuesBlockTheRun() async {
        let session = await makeSession(RecordingRowSource(table: Self.table))
        session.updateColumn("status") { $0.values = [] }

        #expect(!session.canGenerate)
        #expect(session.preview == nil)
        #expect(session.issues(for: "status").count == 1)
    }
}
