import Foundation
@testable import TablePro
import TableProFFI
import TableProTestSupport
import Testing

struct QueryHistoryCoreMirrorTests {
    private let fixture: CoreMirrorFixture
    private let storage: QueryHistoryStorage
    private let mirror: QueryHistoryCoreMirror
    private let manager: QueryHistoryManager
    private let connectionId = UUID()

    init() throws {
        fixture = try CoreMirrorFixture()
        storage = QueryHistoryStorage(databaseURL: fixture.url("query_history.db"))
        let connectionId = connectionId
        mirror = QueryHistoryCoreMirror(storage: storage, database: fixture.core) { ids in
            ids.contains(connectionId) ? [connectionId: "shop"] : [:]
        }
        manager = QueryHistoryManager(storage: storage, isCapturePaused: { false }, coreMirror: mirror)
    }

    private func run(_ query: String, succeeded: Bool = true, at seconds: TimeInterval) -> QueryHistoryEntry {
        QueryHistoryEntry(
            query: query,
            connectionId: connectionId,
            databaseName: "shop",
            databaseType: .postgresql,
            source: .editor,
            executedAt: Date(timeIntervalSince1970: seconds),
            executionTime: 0.25,
            rowCount: 3,
            wasSuccessful: succeeded,
            errorMessage: succeeded ? nil : "syntax error"
        )
    }

    private func coreIds() async throws -> Set<UUID> {
        try await fixture.core.history().recordIds().uuids
    }

    private static func filter(_ text: String = "") -> HistoryFilterArg {
        HistoryFilterArg(
            text: text,
            connectionIds: nil,
            projectId: nil,
            sources: nil,
            status: .any,
            executedAfterMs: nil,
            executedBeforeMs: nil
        )
    }

    // A run another device recorded, as a pull leaves it in the core: no source of this Mac's, and no shape.
    private func foreignRun(_ query: String, at milliseconds: Int64) async throws -> UUID {
        let id = UUID()
        _ = try await fixture.core.history().putEntries(entries: [HistoryEntryRecord(
            recordId: id.uuidString,
            sql: query,
            driverId: DatabaseType.postgresql.rawValue,
            connectionId: connectionId.uuidString,
            connectionName: "shop",
            executedAtMs: milliseconds,
            durationMs: 40,
            rowsAffected: 7,
            outcome: .succeeded,
            details: HistoryRunDetails(
                database: "shop",
                schema: nil,
                source: nil,
                statementType: nil,
                firstRowMs: nil,
                serverMs: nil,
                fingerprint: nil
            )
        )])
        return id
    }

    @Test("The history moves into the core under the Mac's ids, with the fields that sync")
    func historyMovesInUnderItsIds() async throws {
        let failed = run("SELECT broken", succeeded: false, at: 1_700_000_000)
        #expect(await storage.record(failed))
        #expect(await storage.record(run("SELECT 1", at: 1_700_000_100)))

        await mirror.push()

        let mine = await storage.entryIds() ?? []
        #expect(mine.count == 2)
        #expect(try await coreIds() == mine)
        let page = try await fixture.core.history().search(filter: Self.filter("broken"), after: nil, limit: 10)
        let entry = try #require(page.entries.first)
        #expect(UUID(uuidString: entry.recordId) == failed.id)
        #expect(entry.connectionName == "shop")
        #expect(entry.driverId == DatabaseType.postgresql.rawValue)
        #expect(entry.executedAtMs == 1_700_000_000_000)
        #expect(entry.durationMs == 250)
        #expect(entry.outcome == .failed(message: "syntax error"))
        #expect(entry.details.database == "shop")
        #expect(entry.details.source == .editor)
        #expect(entry.details.statementType == .select)
        #expect(entry.details.fingerprint == SQLQueryFingerprint.hash("SELECT broken", databaseType: .postgresql))
    }

    @Test("The pane reads the core's history, a run another device synced included, with this Mac's terms")
    func thePaneReadsTheCore() async throws {
        #expect(await manager.record(run("SELECT mine", at: 1_700_000_000)))
        await mirror.push()
        let foreign = try await foreignRun("SELECT theirs", at: 1_700_000_100_000)

        let page = await manager.fetch(QueryHistoryFilter(scope: .connection(connectionId)), after: nil, limit: 1)
        let first = try #require(page.entries.first)
        #expect(first.id == foreign)
        #expect(first.databaseName == "shop")
        #expect(first.source == .editor)
        #expect(first.rowCount == 7)
        #expect(first.executionTime == 0.04)
        let cursor = try #require(page.nextCursor)
        let next = await manager.fetch(QueryHistoryFilter(scope: .connection(connectionId)), after: cursor, limit: 1)
        #expect(next.entries.map(\.query) == ["SELECT mine"])
        #expect(next.nextCursor == nil)

        let none = await manager.fetch(QueryHistoryFilter(scope: .all, sources: [.mcp]), after: nil, limit: 10)
        #expect(none.entries.isEmpty)
    }

    @Test("A run another device synced comes down into query_history.db with its details, so Insights see it")
    func runsOtherDevicesSyncedComeDown() async throws {
        let foreign = try await foreignRun("SELECT theirs", at: 1_700_000_100_000)

        #expect(await mirror.push())

        #expect(await storage.entryIds() == [foreign])
        #expect(await storage.coreMirrorBase() == [foreign])
        let local = await storage.fetch(QueryHistoryFilter(scope: .all), after: nil, limit: 10)
        #expect(local.entries.first?.databaseName == "shop")
        #expect(local.entries.first?.rowCount == 7)
        #expect(try await coreIds() == [foreign])
    }

    @Test("The person's deletion leaves a tombstone, and a later push never puts the run back")
    func deletionLeavesATombstone() async throws {
        let entry = run("SELECT 1", at: 1_700_000_000)
        #expect(await manager.record(entry))
        await mirror.push()

        #expect(await manager.delete(id: entry.id))
        #expect(await storage.record(entry))
        await mirror.push()

        #expect(try await coreIds().isEmpty)
    }

    @Test("A deletion a crash cut short after it was noted finishes on the next push, here and with its tombstone")
    func pendingDeletionIsReplayed() async throws {
        let entry = run("SELECT 1", at: 1_700_000_000)
        #expect(await storage.record(entry))
        await mirror.push()

        #expect(await storage.notePendingCoreDeletions([entry.id]))
        #expect(await mirror.push())

        #expect(try await coreIds().isEmpty)
        #expect(await storage.pendingCoreDeletions() == [])
        #expect(await storage.entryIds() == [])
    }

    @Test("A run the core let go after both held it, as a deletion another device synced, leaves this store too")
    func runTheCoreLetGoLeavesThisStore() async throws {
        let entry = run("SELECT 1", at: 1_700_000_000)
        #expect(await storage.record(entry))
        await mirror.push()

        _ = try await fixture.core.history().removeEntries(recordIds: [entry.id.uuidString])
        #expect(await mirror.push())
        #expect(await mirror.push())

        #expect(try await coreIds().isEmpty)
        #expect(await storage.entryIds() == [])
    }

    @Test("A core history replaced since the last agreement is refilled from this store, never read as deletions")
    func replacedCoreIsRefilled() async throws {
        let entry = run("SELECT 1", at: 1_700_000_000)
        #expect(await storage.record(entry))
        #expect(await mirror.push())
        let agreed = try #require(await storage.coreIdentity())

        _ = try await fixture.core.history().removeEntries(recordIds: [entry.id.uuidString])
        #expect(await storage.setCoreIdentity(generation: "a-file-restored-from-elsewhere", sequence: agreed.sequence))
        #expect(await mirror.push())

        #expect(await storage.entryIds() == [entry.id])
        #expect(try await coreIds() == [entry.id])
        #expect(await storage.coreIdentity()?.generation == agreed.generation)
    }

    @Test("A run mirrored before the core kept details gets them from this store once")
    func detailsAreBackfilled() async throws {
        let entry = run("SELECT 1", at: 1_700_000_000)
        #expect(await storage.record(entry))
        _ = try await fixture.core.history().putEntries(entries: [HistoryEntryRecord(
            recordId: entry.id.uuidString,
            sql: entry.query,
            driverId: DatabaseType.postgresql.rawValue,
            connectionId: connectionId.uuidString,
            connectionName: "shop",
            executedAtMs: 1_700_000_000_000,
            durationMs: 250,
            rowsAffected: 3,
            outcome: .succeeded,
            details: HistoryRunDetails(
                database: nil,
                schema: nil,
                source: nil,
                statementType: nil,
                firstRowMs: nil,
                serverMs: nil,
                fingerprint: nil
            )
        )])
        #expect(await storage.updateCoreMirrorBase(adding: [entry.id], removing: []))

        #expect(await mirror.push())

        let stored = try #require(try await fixture.core.history().search(filter: Self.filter(), after: nil, limit: 1).entries.first)
        #expect(stored.details.database == "shop")
        #expect(stored.details.source == .editor)
        #expect(await storage.coreDetailsFilled())
    }

    @Test("Clearing what the pane shows takes another device's matching runs from the core and this store")
    func clearingTheFilterReachesOtherDevicesRuns() async throws {
        let kept = run("SELECT kept", at: 1_700_000_000)
        #expect(await manager.record(run("SELECT orders", at: 1_700_000_050)))
        #expect(await manager.record(kept))
        await mirror.push()
        _ = try await foreignRun("SELECT orders", at: 1_700_000_100_000)
        await mirror.push()

        #expect(await manager.clear(matching: QueryHistoryFilter(scope: .all, searchText: "orders")))

        #expect(try await coreIds() == [kept.id])
        #expect(await storage.entryIds() == [kept.id])
    }

    @Test("A filtered clear leaves a run the core did not match, though this store's search would")
    func clearKeepsRunsThePaneDidNotShow() async throws {
        let foreign = try await foreignRun("SELECT theirs", at: 1_700_000_100_000)
        await mirror.push()

        #expect(await manager.clear(matching: QueryHistoryFilter(scope: .all, sources: [.editor])))

        #expect(try await coreIds() == [foreign])
        #expect(await storage.entryIds() == [foreign])
    }

    @Test("A clear of every run a crash cut short finishes on the next push, other devices' runs included")
    func pendingClearIsReplayed() async throws {
        #expect(await storage.record(run("SELECT mine", at: 1_700_000_000)))
        await mirror.push()
        _ = try await foreignRun("SELECT theirs", at: 1_700_000_100_000)

        #expect(await storage.notePendingCoreClear("*"))
        #expect(await mirror.push())

        #expect(try await coreIds().isEmpty)
        #expect(await storage.entryIds() == [])
        #expect(await storage.pendingCoreClears() == [])
    }

    @Test("Runs another device synced get their shape from this Mac's grammar, a page at a time")
    func shapesAreFilledIn() async throws {
        _ = try await foreignRun("SELECT * FROM orders WHERE id = 1", at: 1_700_000_000_000)

        #expect(await mirror.fillFingerprints())

        let store = try await fixture.core.history()
        #expect(try await store.entriesWithoutFingerprint(limit: 10).isEmpty)
        let entry = try #require(try await store.search(filter: Self.filter(), after: nil, limit: 1).entries.first)
        #expect(entry.details.fingerprint == SQLQueryFingerprint.hash("SELECT * FROM orders WHERE id = 1", databaseType: .postgresql))
    }

    @Test("A run recorded through the manager reaches the core, and a deleted one leaves it")
    func recordedAndDeletedRunsReachTheCore() async throws {
        let entry = run("SELECT 1", at: 1_700_000_000)
        #expect(await manager.record(entry))
        await mirror.recorded(entry.id)
        #expect(try await coreIds() == [entry.id])

        #expect(await manager.delete(id: entry.id))
        await mirror.push()

        #expect(try await coreIds().isEmpty)
    }

    @Test("Runs the previous stable recorded and deleted after a downgrade reach the core")
    func previousStableRunsReachTheCore() async throws {
        let first = run("SELECT 1", at: 1_700_000_000)
        #expect(await storage.record(first))
        await mirror.push()

        let later = run("SELECT 2", at: 1_700_000_100)
        #expect(await storage.record(later))
        #expect(await storage.delete(id: first.id))
        await mirror.push()

        #expect(try await coreIds() == [later.id])
    }

    @Test("A history file set aside for damage leaves the core's runs, and Clear History clears them")
    func setAsideKeepsTheCoreRuns() async throws {
        let kept = run("SELECT kept", at: 1_700_000_000)
        #expect(await storage.record(kept))
        await mirror.push()

        let replacement = QueryHistoryStorage(databaseURL: fixture.url("replacement.db"))
        let replacementMirror = QueryHistoryCoreMirror(storage: replacement, database: fixture.core) { _ in [:] }
        #expect(await replacementMirror.push())
        #expect(try await coreIds() == [kept.id])

        let replacementManager = QueryHistoryManager(
            storage: replacement,
            isCapturePaused: { false },
            coreMirror: replacementMirror
        )
        #expect(await replacementManager.clear(matching: QueryHistoryFilter(scope: .all)))
        #expect(try await coreIds().isEmpty)
    }
}
