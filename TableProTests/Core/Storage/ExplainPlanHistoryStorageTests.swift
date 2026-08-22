import Foundation
import SQLite3
@testable import TablePro
import Testing

@Suite("Explain plan history storage")
struct ExplainPlanHistoryStorageTests {
    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("explain_plan_history_\(UUID().uuidString).db")
    }

    private func makeContext(
        historyId: UUID = UUID(),
        subjectQuery: String = "SELECT * FROM users WHERE id = 1",
        connectionId: UUID = UUID(),
        databaseName: String = "app",
        databaseType: DatabaseType = .postgresql,
        schemaName: String? = "public",
        variantId: String? = "analyze",
        formatRawValue: String = "json",
        capturedAt: Date = Date()
    ) -> ExplainPlanHistoryContext {
        ExplainPlanHistoryContext(
            historyId: historyId,
            subjectQuery: subjectQuery,
            connectionId: connectionId,
            databaseName: databaseName,
            databaseType: databaseType,
            schemaName: schemaName,
            variantId: variantId,
            formatRawValue: formatRawValue,
            capturedAt: capturedAt
        )
    }

    private func makeEntry(
        context: ExplainPlanHistoryContext,
        executionTime: TimeInterval = 0.25,
        wasSuccessful: Bool = true
    ) -> QueryHistoryEntry {
        QueryHistoryEntry(
            id: context.historyId,
            query: context.subjectQuery,
            connectionId: context.connectionId,
            databaseName: context.databaseName,
            databaseType: context.databaseType,
            schemaName: context.schemaName,
            source: .explain,
            executedAt: context.capturedAt,
            executionTime: executionTime,
            rowCount: 1,
            wasSuccessful: wasSuccessful
        )
    }

    @discardableResult
    private func record(
        _ context: ExplainPlanHistoryContext,
        rawText: String,
        executionTime: TimeInterval = 0.25,
        wasSuccessful: Bool = true,
        in storage: QueryHistoryStorage
    ) async -> Bool {
        await storage.record(
            makeEntry(context: context, executionTime: executionTime, wasSuccessful: wasSuccessful),
            explainPlan: ExplainPlanHistoryRecord(context: context, rawText: rawText)
        )
    }

    private func scalarInt(at url: URL, sql: String) -> Int {
        var database: OpaquePointer?
        guard sqlite3_open(url.path(percentEncoded: false), &database) == SQLITE_OK else { return -1 }
        defer { sqlite3_close_v2(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    @Test("metadata round-trips and raw payload loads by selected ID")
    func metadataRoundTripsAndRawPayloadLoadsBySelectedID() async {
        let url = makeURL()
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let context = makeContext(capturedAt: capturedAt)
        let first = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: false)
        #expect(await record(context, rawText: "[{\"Plan\":{}}]", executionTime: 1.5, in: first))

        let reopened = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: true)
        let current = makeContext(
            subjectQuery: context.subjectQuery,
            connectionId: context.connectionId,
            databaseName: context.databaseName,
            databaseType: context.databaseType,
            schemaName: context.schemaName,
            variantId: context.variantId,
            formatRawValue: context.formatRawValue,
            capturedAt: capturedAt.addingTimeInterval(1)
        )
        let snapshots = await reopened.explainPlanHistory(matching: current, limit: 10)

        #expect(snapshots.count == 1)
        #expect(snapshots.first?.id == context.historyId)
        #expect(snapshots.first?.context == context)
        #expect(snapshots.first?.executionTime == 1.5)
        #expect(await reopened.explainPlanRawText(historyId: context.historyId) == "[{\"Plan\":{}}]")
        #expect(await reopened.explainPlanRawText(historyId: UUID()) == nil)
    }

    @Test("baseline matching isolates every scope field and the exact query")
    func baselineMatchingIsExact() async {
        let storage = QueryHistoryStorage(databaseURL: makeURL(), removeDatabaseOnDeinit: true)
        let connectionId = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let current = makeContext(connectionId: connectionId, capturedAt: now)
        let valid = makeContext(connectionId: connectionId, capturedAt: now.addingTimeInterval(-10))
        #expect(await record(valid, rawText: "valid", in: storage))

        let mismatches = [
            makeContext(
                subjectQuery: "SELECT * FROM users WHERE id = 2",
                connectionId: connectionId,
                capturedAt: now.addingTimeInterval(-9)
            ),
            makeContext(connectionId: UUID(), capturedAt: now.addingTimeInterval(-8)),
            makeContext(connectionId: connectionId, databaseName: "other", capturedAt: now.addingTimeInterval(-7)),
            makeContext(connectionId: connectionId, databaseType: .mysql, capturedAt: now.addingTimeInterval(-6)),
            makeContext(connectionId: connectionId, schemaName: "private", capturedAt: now.addingTimeInterval(-5)),
            makeContext(connectionId: connectionId, variantId: nil, capturedAt: now.addingTimeInterval(-4)),
            makeContext(connectionId: connectionId, formatRawValue: "text", capturedAt: now.addingTimeInterval(-3))
        ]
        for (index, mismatch) in mismatches.enumerated() {
            #expect(await record(mismatch, rawText: "mismatch-\(index)", in: storage))
        }

        let snapshots = await storage.explainPlanHistory(matching: current, limit: 20)
        #expect(snapshots.map(\.id) == [valid.historyId])
        #expect(await storage.explainPlanRawText(historyId: valid.historyId) == "valid")
    }

    @Test("nullable schema and variant are matched null-safely")
    func nullableScopeIsExact() async {
        let storage = QueryHistoryStorage(databaseURL: makeURL(), removeDatabaseOnDeinit: true)
        let connectionId = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = makeContext(
            connectionId: connectionId,
            schemaName: nil,
            variantId: nil,
            capturedAt: now.addingTimeInterval(-1)
        )
        #expect(await record(previous, rawText: "nullable", in: storage))

        let current = makeContext(
            connectionId: connectionId,
            schemaName: nil,
            variantId: nil,
            capturedAt: now
        )
        #expect(await storage.explainPlanHistory(matching: current, limit: 10).map(\.id) == [previous.historyId])
    }

    @Test("history returns newest prior successful snapshots only")
    func historyReturnsNewestPriorSuccessfulSnapshots() async {
        let url = makeURL()
        let storage = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: true)
        let connectionId = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let current = makeContext(connectionId: connectionId, capturedAt: now)
        let older = makeContext(connectionId: connectionId, capturedAt: now.addingTimeInterval(-30))
        let newer = makeContext(connectionId: connectionId, capturedAt: now.addingTimeInterval(-10))
        let failed = makeContext(connectionId: connectionId, capturedAt: now.addingTimeInterval(-5))
        let future = makeContext(connectionId: connectionId, capturedAt: now.addingTimeInterval(10))

        for (context, rawText, successful) in [
            (older, "older", true),
            (newer, "newer", true),
            (failed, "failed", false),
            (future, "future", true)
        ] {
            #expect(await record(context, rawText: rawText, wasSuccessful: successful, in: storage))
        }
        #expect(await record(current, rawText: "current", in: storage))
        #expect(scalarInt(at: url, sql: "SELECT COUNT(*) FROM query_plan_snapshots;") == 4)

        let snapshots = await storage.explainPlanHistory(matching: current, limit: 10)
        #expect(snapshots.map(\.id) == [newer.historyId, older.historyId])
        #expect(await storage.explainPlanHistory(matching: current, limit: 1).map(\.id) == [newer.historyId])
        #expect(await storage.explainPlanHistory(matching: current, limit: 0).isEmpty)
        #expect(await storage.explainPlanRawText(historyId: newer.historyId) == "newer")
    }

    @Test("ordinary history records have no plan snapshot")
    func ordinaryHistoryHasNoSnapshot() async {
        let storage = QueryHistoryStorage(databaseURL: makeURL(), removeDatabaseOnDeinit: true)
        let context = makeContext(capturedAt: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(await storage.record(makeEntry(context: context)))

        let current = makeContext(
            subjectQuery: context.subjectQuery,
            connectionId: context.connectionId,
            databaseName: context.databaseName,
            databaseType: context.databaseType,
            schemaName: context.schemaName,
            variantId: context.variantId,
            formatRawValue: context.formatRawValue,
            capturedAt: context.capturedAt.addingTimeInterval(1)
        )
        #expect(await storage.explainPlanHistory(matching: current, limit: 10).isEmpty)
    }

    @Test("two megabytes is stored and one byte more keeps only the parent")
    func snapshotSizeBoundary() async {
        let url = makeURL()
        let storage = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: true)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let exact = makeContext(subjectQuery: "SELECT exact", capturedAt: base)
        let oversized = makeContext(subjectQuery: "SELECT oversized", capturedAt: base.addingTimeInterval(1))
        let exactText = String(repeating: "é", count: ExplainPlanHistoryRecord.maximumRawByteCount / 2)
        let oversizedText = exactText + "x"

        #expect(await record(exact, rawText: exactText, in: storage))
        #expect(await record(oversized, rawText: oversizedText, in: storage))
        #expect(await storage.count(scope: .all) == 2)
        #expect(scalarInt(at: url, sql: "SELECT COUNT(*) FROM query_plan_snapshots;") == 1)
        #expect(
            scalarInt(
                at: url,
                sql: "SELECT raw_byte_count FROM query_plan_snapshots WHERE history_id = '\(exact.historyId.uuidString)';"
            ) == ExplainPlanHistoryRecord.maximumRawByteCount
        )

        let exactCurrent = makeContext(
            subjectQuery: exact.subjectQuery,
            connectionId: exact.connectionId,
            databaseName: exact.databaseName,
            databaseType: exact.databaseType,
            schemaName: exact.schemaName,
            variantId: exact.variantId,
            formatRawValue: exact.formatRawValue,
            capturedAt: base.addingTimeInterval(10)
        )
        #expect(await storage.explainPlanHistory(matching: exactCurrent, limit: 1).first?.id == exact.historyId)
        #expect(await storage.explainPlanRawText(historyId: exact.historyId) == exactText)
        #expect(await storage.explainPlanRawText(historyId: oversized.historyId) == nil)
    }

    @Test("manager uses the plan identity and timestamp and obeys capture pause")
    func managerUsesPlanContextAndPause() async {
        let storage = QueryHistoryStorage(databaseURL: makeURL(), removeDatabaseOnDeinit: true)
        let context = makeContext(capturedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let record = ExplainPlanHistoryRecord(context: context, rawText: "plan")
        let request = QueryHistoryRecordRequest(
            query: context.subjectQuery,
            connectionId: context.connectionId,
            databaseName: context.databaseName,
            databaseType: context.databaseType,
            schemaName: context.schemaName,
            source: .explain,
            executionTime: 0.5,
            rowCount: 1,
            wasSuccessful: true,
            explainPlan: record
        )

        let paused = QueryHistoryManager(storage: storage, isCapturePaused: { true })
        #expect(await paused.record(request) == false)
        #expect(await storage.count(scope: .all) == 0)

        let manager = QueryHistoryManager(storage: storage, isCapturePaused: { false })
        #expect(await manager.record(request))
        let parent = await storage.fetch(.init(scope: .all), after: nil, limit: 1).entries.first
        #expect(parent?.id == context.historyId)
        #expect(parent?.executedAt == context.capturedAt)
        #expect(await manager.explainPlanRawText(historyId: context.historyId) == "plan")

        let oversizedContext = makeContext(
            subjectQuery: "SELECT oversized",
            connectionId: context.connectionId,
            databaseName: context.databaseName,
            databaseType: context.databaseType,
            schemaName: context.schemaName,
            variantId: context.variantId,
            formatRawValue: context.formatRawValue,
            capturedAt: context.capturedAt.addingTimeInterval(1)
        )
        let oversizedPlan = ExplainPlanHistoryRecord(
            context: oversizedContext,
            rawText: String(repeating: "x", count: ExplainPlanHistoryRecord.maximumRawByteCount + 1)
        )
        let oversizedRequest = QueryHistoryRecordRequest(
            query: oversizedContext.subjectQuery,
            connectionId: oversizedContext.connectionId,
            databaseName: oversizedContext.databaseName,
            databaseType: oversizedContext.databaseType,
            schemaName: oversizedContext.schemaName,
            source: .explain,
            executionTime: 0.5,
            rowCount: 1,
            wasSuccessful: true,
            explainPlan: oversizedPlan
        )
        #expect(await manager.record(oversizedRequest))
        #expect(await storage.count(scope: .all) == 2)
        #expect(await manager.explainPlanRawText(historyId: oversizedContext.historyId) == nil)
    }

    @Test("plan byte budget prunes oldest payloads but keeps history parents")
    func planByteBudgetPrunesOldestPayloads() async {
        let url = makeURL()
        let storage = QueryHistoryStorage(
            databaseURL: url,
            removeDatabaseOnDeinit: true,
            explainPlanRawByteLimit: 10
        )
        let connectionIds = [UUID(), UUID(), UUID()]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let contexts = (0..<3).map { offset in
            makeContext(
                connectionId: connectionIds[offset],
                capturedAt: base.addingTimeInterval(TimeInterval(offset))
            )
        }

        for context in contexts {
            #expect(await record(context, rawText: "123456", in: storage))
        }

        #expect(await storage.count(scope: .all) == 3)
        #expect(scalarInt(at: url, sql: "SELECT COALESCE(SUM(raw_byte_count), 0) FROM query_plan_snapshots;") == 6)
        #expect(await storage.explainPlanRawText(historyId: contexts[0].historyId) == nil)
        #expect(await storage.explainPlanRawText(historyId: contexts[1].historyId) == nil)
        #expect(await storage.explainPlanRawText(historyId: contexts[2].historyId) == "123456")
    }

    @Test("plan count budget prunes oldest payloads but keeps history parents")
    func planCountBudgetPrunesOldestPayloads() async {
        let storage = QueryHistoryStorage(
            databaseURL: makeURL(),
            removeDatabaseOnDeinit: true,
            explainPlanRawByteLimit: 100,
            explainPlanSnapshotLimit: 2
        )
        let connectionId = UUID()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let contexts = (0..<3).map { offset in
            makeContext(
                connectionId: connectionId,
                capturedAt: base.addingTimeInterval(TimeInterval(offset))
            )
        }

        for context in contexts {
            #expect(await record(context, rawText: "x", in: storage))
        }

        #expect(await storage.count(scope: .all) == 3)
        #expect(await storage.explainPlanRawText(historyId: contexts[0].historyId) == nil)
        #expect(await storage.explainPlanRawText(historyId: contexts[1].historyId) == "x")
        #expect(await storage.explainPlanRawText(historyId: contexts[2].historyId) == "x")
    }

    @Test("snapshot context mismatch keeps only its parent")
    func snapshotContextMismatchKeepsOnlyParent() async {
        let context = makeContext()
        let entry = makeEntry(context: context)
        let mismatches = [
            makeContext(
                subjectQuery: context.subjectQuery,
                connectionId: context.connectionId,
                databaseName: context.databaseName,
                databaseType: context.databaseType,
                schemaName: context.schemaName,
                variantId: context.variantId,
                formatRawValue: context.formatRawValue,
                capturedAt: context.capturedAt
            ),
            makeContext(
                historyId: context.historyId,
                subjectQuery: context.subjectQuery,
                databaseName: context.databaseName,
                databaseType: context.databaseType,
                schemaName: context.schemaName,
                variantId: context.variantId,
                formatRawValue: context.formatRawValue,
                capturedAt: context.capturedAt
            ),
            makeContext(
                historyId: context.historyId,
                subjectQuery: context.subjectQuery,
                connectionId: context.connectionId,
                databaseName: "other",
                databaseType: context.databaseType,
                schemaName: context.schemaName,
                variantId: context.variantId,
                formatRawValue: context.formatRawValue,
                capturedAt: context.capturedAt
            ),
            makeContext(
                historyId: context.historyId,
                subjectQuery: context.subjectQuery,
                connectionId: context.connectionId,
                databaseName: context.databaseName,
                databaseType: .mysql,
                schemaName: context.schemaName,
                variantId: context.variantId,
                formatRawValue: context.formatRawValue,
                capturedAt: context.capturedAt
            ),
            makeContext(
                historyId: context.historyId,
                subjectQuery: context.subjectQuery,
                connectionId: context.connectionId,
                databaseName: context.databaseName,
                databaseType: context.databaseType,
                schemaName: "other",
                variantId: context.variantId,
                formatRawValue: context.formatRawValue,
                capturedAt: context.capturedAt
            ),
            makeContext(
                historyId: context.historyId,
                subjectQuery: context.subjectQuery,
                connectionId: context.connectionId,
                databaseName: context.databaseName,
                databaseType: context.databaseType,
                schemaName: context.schemaName,
                variantId: context.variantId,
                formatRawValue: context.formatRawValue,
                capturedAt: context.capturedAt.addingTimeInterval(1)
            )
        ]

        for mismatch in mismatches {
            let storage = QueryHistoryStorage(databaseURL: makeURL(), removeDatabaseOnDeinit: true)
            let plan = ExplainPlanHistoryRecord(context: mismatch, rawText: "plan")
            #expect(await storage.record(entry, explainPlan: plan))
            #expect(await storage.count(scope: .all) == 1)
            #expect(await storage.explainPlanRawText(historyId: context.historyId) == nil)
        }
    }

    @Test("missing snapshot storage keeps parent history")
    func missingSnapshotStorageKeepsParentHistory() async {
        let storage = QueryHistoryStorage(databaseURL: makeURL(), removeDatabaseOnDeinit: true)
        _ = await storage.count(scope: .all)
        await storage.execute("DROP TABLE query_plan_snapshots;")
        let context = makeContext()

        #expect(await record(context, rawText: "plan", in: storage))
        #expect(await storage.count(scope: .all) == 1)
        let parent = await storage.fetch(.init(scope: .all), after: nil, limit: 1).entries.first
        #expect(parent?.id == context.historyId)
        #expect(await storage.explainPlanRawText(historyId: context.historyId) == nil)
    }

    @Test("prune failure rolls back child and keeps parent history")
    func pruneFailureRollsBackChildAndKeepsParentHistory() async {
        let url = makeURL()
        let storage = QueryHistoryStorage(
            databaseURL: url,
            removeDatabaseOnDeinit: true,
            explainPlanRawByteLimit: 0
        )
        _ = await storage.count(scope: .all)
        await storage.execute("""
            CREATE TRIGGER reject_plan_prune BEFORE DELETE ON query_plan_snapshots BEGIN
                SELECT RAISE(ABORT, 'forced prune failure');
            END;
            """)
        let context = makeContext()

        #expect(await record(context, rawText: "plan", in: storage))
        #expect(await storage.count(scope: .all) == 1)
        #expect(scalarInt(at: url, sql: "SELECT COUNT(*) FROM query_plan_snapshots;") == 0)
        #expect(await storage.explainPlanRawText(historyId: context.historyId) == nil)
    }

    @Test("commit failure rolls back child and keeps parent history")
    func commitFailureRollsBackChildAndKeepsParentHistory() async {
        let url = makeURL()
        let storage = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: true)
        _ = await storage.count(scope: .all)
        await storage.execute("CREATE TABLE missing_plan_parents (id INTEGER PRIMARY KEY);")
        await storage.execute("""
            CREATE TABLE rejected_plan_commits (
                id INTEGER PRIMARY KEY,
                parent_id INTEGER NOT NULL REFERENCES missing_plan_parents(id)
                    DEFERRABLE INITIALLY DEFERRED
            );
            """)
        await storage.execute("""
            CREATE TRIGGER reject_plan_commit AFTER INSERT ON query_plan_snapshots BEGIN
                INSERT INTO rejected_plan_commits (id, parent_id) VALUES (1, 1);
            END;
            """)
        let context = makeContext()

        #expect(await record(context, rawText: "plan", in: storage))
        #expect(await storage.count(scope: .all) == 1)
        #expect(scalarInt(at: url, sql: "SELECT COUNT(*) FROM query_plan_snapshots;") == 0)
        #expect(scalarInt(at: url, sql: "SELECT COUNT(*) FROM rejected_plan_commits;") == 0)
        #expect(await storage.explainPlanRawText(historyId: context.historyId) == nil)
    }

    @Test("history deletion paths remove child snapshots")
    func deletionPathsRemoveSnapshots() async {
        let url = makeURL()
        let storage = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: true)
        let dropConnection = UUID()
        let keepConnection = UUID()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let deleteDirectly = makeContext(connectionId: dropConnection, capturedAt: base)
        let clearWithConnection = makeContext(connectionId: dropConnection, capturedAt: base.addingTimeInterval(1))
        let keep = makeContext(connectionId: keepConnection, capturedAt: base.addingTimeInterval(2))
        for context in [deleteDirectly, clearWithConnection, keep] {
            #expect(await record(context, rawText: context.historyId.uuidString, in: storage))
        }
        #expect(scalarInt(at: url, sql: "SELECT COUNT(*) FROM query_plan_snapshots;") == 3)

        #expect(await storage.delete(id: deleteDirectly.historyId))
        #expect(scalarInt(at: url, sql: "SELECT COUNT(*) FROM query_plan_snapshots;") == 2)
        #expect(await storage.clear(matching: .init(scope: .connection(dropConnection))))
        #expect(scalarInt(at: url, sql: "SELECT COUNT(*) FROM query_plan_snapshots;") == 1)

        let newest = makeContext(connectionId: keepConnection, capturedAt: base.addingTimeInterval(3))
        #expect(await record(newest, rawText: "newest", in: storage))
        await storage.updateSettingsCache(maxEntries: 1, maxDays: 0, autoCleanup: true)
        #expect(await storage.cleanup())
        #expect(scalarInt(at: url, sql: "SELECT COUNT(*) FROM query_plan_snapshots;") == 1)
    }
}
