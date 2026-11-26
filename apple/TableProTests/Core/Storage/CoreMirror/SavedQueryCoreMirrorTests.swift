import Foundation
import os
@testable import TablePro
import TableProFFI
import TableProSyncTransport
import Testing

@MainActor
struct SavedQueryCoreMirrorTests {
    private let fixture: CoreMirrorFixture
    private let storage: SQLFavoriteStorage
    private let journal = SyncJournalRecorder()
    private let manager: SQLFavoriteManager
    private let connectionId = UUID()

    init() throws {
        fixture = try CoreMirrorFixture()
        storage = SQLFavoriteStorage(databaseURL: fixture.url("sql_favorites.db"))
        manager = SQLFavoriteManager(
            storage: storage,
            syncJournal: journal.journal,
            core: fixture.core,
            mirrorDefaults: try fixture.pool.make().defaults
        )
    }

    private func coreContents() async throws -> SavedQueryStoreContents {
        try await fixture.core.savedQueries().contents()
    }

    private func favorite(_ name: String, keyword: String? = nil, folderId: UUID? = nil, createdAt: Date) -> SQLFavorite {
        SQLFavorite(
            name: name,
            query: "SELECT '\(name)'",
            keyword: keyword,
            folderId: folderId,
            connectionId: connectionId,
            sortOrder: 3,
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(5)
        )
    }

    @Test("The first push moves every saved query and folder in under its own id, with its times and place")
    func firstPushKeepsIdsTimesAndPlaces() async throws {
        let folder = SQLFavoriteFolder(name: "Reports", connectionId: connectionId, sortOrder: 1)
        let daily = favorite("Daily", keyword: "dl", folderId: folder.id, createdAt: Date(timeIntervalSince1970: 1_700_000_000.123))
        #expect(await storage.addFolder(folder))
        #expect(await storage.addFavorite(daily))

        await manager.pushToCore()

        let contents = try await coreContents()
        let query = try #require(contents.queries.first)
        #expect(UUID(uuidString: query.id) == daily.id)
        #expect(UUID(uuidString: query.folderId ?? "") == folder.id)
        #expect(UUID(uuidString: query.connectionId ?? "") == connectionId)
        #expect(query.keyword == "dl")
        #expect(query.order == 3)
        #expect(query.createdAtMs == 1_700_000_000_123)
        #expect(query.updatedAtMs == 1_700_000_005_123)
        let folderIds = contents.folders.map { $0.id }.uuids
        #expect(folderIds == [folder.id])
    }

    @Test("A save, an edit and a delete through the manager reach the core")
    func managerWritesReachTheCore() async throws {
        let report = favorite("Report", createdAt: Date(timeIntervalSince1970: 1_000))
        #expect(await manager.addFavorite(report))
        await manager.pushToCore()
        let saved = try await coreContents().queries.map { $0.id }.uuids
        #expect(saved == [report.id])

        var edited = report
        edited.query = "SELECT 2"
        #expect(await manager.updateFavorite(edited))
        await manager.pushToCore()
        #expect(try await coreContents().queries.first?.sql == "SELECT 2")

        #expect(await manager.deleteFavorite(id: report.id))
        await manager.pushToCore()
        #expect(try await coreContents().queries.isEmpty)
    }

    @Test("Two saved queries of one name in a connection move in with the later one renamed, and the rename syncs")
    func collidingNamesSettleAndSync() async throws {
        let older = favorite("Report", createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = favorite("Report", createdAt: Date(timeIntervalSince1970: 2_000))
        #expect(await storage.addFavorite(older))
        #expect(await storage.addFavorite(newer))

        await manager.pushToCore()

        #expect(await storage.fetchFavorite(id: older.id)?.name == "Report")
        #expect(await storage.fetchFavorite(id: newer.id)?.name == "Report (2)")
        #expect(journal.dirtyIds(for: .favorite) == [newer.id.uuidString])
        let names = try await coreContents().queries.map { $0.name }.sorted()
        #expect(names == ["Report", "Report (2)"])
    }

    @Test("An older query of one name arriving later renames the one already agreed, and that rename syncs")
    func settlementOfAnAgreedQuerySyncs() async throws {
        let agreed = favorite("Report", createdAt: Date(timeIntervalSince1970: 2_000))
        #expect(await storage.addFavorite(agreed))
        await manager.pushToCore()
        let older = favorite("Report", createdAt: Date(timeIntervalSince1970: 1_000))
        #expect(await storage.addFavorite(older))

        await manager.pushToCore()

        #expect(await storage.fetchFavorite(id: older.id)?.name == "Report")
        #expect(await storage.fetchFavorite(id: agreed.id)?.name == "Report (2)")
        #expect(journal.dirtyIds(for: .favorite) == [agreed.id.uuidString])
    }

    @Test("What the previous stable changed and deleted in its store after a downgrade reaches the core")
    func previousStableEditsReachTheCore() async throws {
        let kept = favorite("Kept", createdAt: Date(timeIntervalSince1970: 1_000))
        let dropped = favorite("Dropped", createdAt: Date(timeIntervalSince1970: 2_000))
        #expect(await storage.addFavorite(kept))
        #expect(await storage.addFavorite(dropped))
        await manager.pushToCore()

        var edited = kept
        edited.name = "Kept, renamed by 0.88"
        #expect(await storage.updateFavorite(edited).succeeded)
        #expect(await storage.deleteFavorites(ids: [dropped.id]) != nil)
        await manager.pushToCore()

        let contents = try await coreContents()
        let held = contents.queries.map { $0.id }.uuids
        #expect(held == [kept.id])
        #expect(contents.queries.first?.name == "Kept, renamed by 0.88")
    }

    @Test("A write that reached the core and not the Mac's store comes back into the store")
    func coreAheadComesBack() async throws {
        let report = favorite("Report", createdAt: Date(timeIntervalSince1970: 1_000))
        #expect(await storage.addFavorite(report))
        await manager.pushToCore()
        var record = try #require(try await coreContents().queries.first)
        record.name = "Renamed in the core"
        _ = try await fixture.core.savedQueries().writeRecords(write: SavedQueryRecordWrite(
            queries: [record],
            folders: [],
            removedQueries: [],
            removedFolders: []
        ))

        await manager.pushToCore()

        #expect(await storage.fetchFavorite(id: report.id)?.name == "Renamed in the core")
        #expect(journal.dirtyIds(for: .favorite).isEmpty)
    }

    @Test("A deletion that reached the core before a crash, then one on the previous stable, leaves both gone")
    func deletionsOnBothSidesStayDeleted() async throws {
        let first = favorite("First", createdAt: Date(timeIntervalSince1970: 1_000))
        let second = favorite("Second", createdAt: Date(timeIntervalSince1970: 2_000))
        #expect(await storage.addFavorite(first))
        #expect(await storage.addFavorite(second))
        await manager.pushToCore()
        #expect(await storage.deleteFavorites(ids: [first.id]) != nil)
        _ = try await fixture.core.savedQueries().writeRecords(write: SavedQueryRecordWrite(
            queries: [],
            folders: [],
            removedQueries: [first.id.uuidString],
            removedFolders: []
        ))
        #expect(await storage.deleteFavorites(ids: [second.id]) != nil)

        await manager.pushToCore()

        #expect(try await coreContents().queries.isEmpty)
        #expect(await storage.readAllFavorites()?.isEmpty == true)
    }

    @Test("A pushed store pushes nothing again until it changes")
    func aSecondPushWritesNothing() async throws {
        #expect(await storage.addFavorite(favorite("Report", createdAt: Date(timeIntervalSince1970: 1_000))))
        await manager.pushToCore()
        let digest = try await coreContents().digest

        await manager.pushToCore()

        #expect(try await coreContents().digest == digest)
    }

    @Test("A policy stop before a pull's apply writes nothing of it (P1-M4)")
    func policyStopEndsTheApply() async throws {
        let deleted = favorite("Deleted", createdAt: Date(timeIntervalSince1970: 1_000))
        #expect(await storage.addFavorite(deleted))
        let folder = SQLFavoriteFolder(name: "Pulled", connectionId: connectionId)
        let pulled = favorite("Pulled", createdAt: Date(timeIntervalSince1970: 2_000))
        // The check before the apply starts passes; the stop lands before the store's first write.
        let checks = StopAfter(checks: 1)

        let outcome = await manager.applyRemote(
            RemoteSQLFavoriteBatch(favorites: [pulled], folders: [folder], deletedFavoriteIds: [deleted.id]),
            isStopped: { checks.isStopped() }
        )

        #expect(outcome == .failed)
        #expect(await storage.fetchFavorite(id: deleted.id) != nil)
        #expect(await storage.fetchFolder(id: folder.id) == nil)
        #expect(await storage.fetchFavorite(id: pulled.id) == nil)
    }

    @Test("A stop that lands while a pulled write waits to commit rolls the write back (P1-M4)")
    func stopWhileTheWriteWaits() async throws {
        let pulled = SQLFavoriteFolder(name: "Pulled", connectionId: connectionId)
        // The checks before the apply and on the store's actor pass; SQLite's commit asks again and sees the stop.
        let stop = StopAfter(checks: 2)

        let outcome = await manager.applyRemote(
            RemoteSQLFavoriteBatch(folders: [pulled]),
            isStopped: { stop.isStopped() }
        )

        #expect(outcome == .failed)
        #expect(await storage.fetchFolder(id: pulled.id) == nil)
    }
}

private final class StopAfter: Sendable {
    private let remaining: OSAllocatedUnfairLock<Int>

    init(checks: Int) {
        remaining = OSAllocatedUnfairLock(initialState: checks)
    }

    func isStopped() -> Bool {
        remaining.withLock { left in
            guard left > 0 else { return true }
            left -= 1
            return false
        }
    }
}
