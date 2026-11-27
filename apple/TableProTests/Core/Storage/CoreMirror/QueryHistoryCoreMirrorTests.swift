import Foundation
@testable import TablePro
import TableProFFI
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

    @Test("The history moves into the core under the Mac's ids, with the fields that sync")
    func historyMovesInUnderItsIds() async throws {
        let failed = run("SELECT broken", succeeded: false, at: 1_700_000_000)
        #expect(await storage.record(failed))
        #expect(await storage.record(run("SELECT 1", at: 1_700_000_100)))

        await mirror.push()

        let mine = await storage.entryIds() ?? []
        #expect(mine.count == 2)
        #expect(try await coreIds() == mine)
        let page = try await fixture.core.history().search(text: "broken", connectionId: nil, projectId: nil, after: nil, limit: 10)
        let entry = try #require(page.entries.first)
        #expect(UUID(uuidString: entry.recordId) == failed.id)
        #expect(entry.connectionName == "shop")
        #expect(entry.driverId == DatabaseType.postgresql.rawValue)
        #expect(entry.executedAtMs == 1_700_000_000_000)
        #expect(entry.durationMs == 250)
        #expect(entry.outcome == .failed(message: "syntax error"))
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
