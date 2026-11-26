//
//  SQLFavoriteManagerImportTests.swift
//  TableProTests
//

import Combine
import Foundation
import SQLite3
@testable import TablePro
import TableProImport
import TableProSyncTransport
import Testing

@MainActor
struct SQLFavoriteManagerImportTests {
    private let databasePath: String
    private let storage: SQLFavoriteStorage
    private let journal = SyncJournalRecorder()
    private let events: AppEvents
    private let manager: SQLFavoriteManager

    init() throws {
        let unique = UUID().uuidString
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("sql_favorites_manager_import_\(unique).db")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        databasePath = url.path(percentEncoded: false)
        storage = SQLFavoriteStorage(databaseURL: url, removeDatabaseOnDeinit: true)
        let appEvents = AppEvents()
        events = appEvents
        manager = SQLFavoriteManager(
            storage: storage,
            syncJournal: journal.journal,
            appEvents: appEvents
        )
    }

    private func planned(_ name: String, keyword: String? = nil, folders: [String] = []) -> PlannedQuery {
        PlannedQuery(
            ref: BundleRef(name),
            name: name,
            sql: "SELECT '\(name)'",
            keyword: keyword,
            connectionId: nil,
            folderPath: folders.map { PathComponent(name: $0, scope: nil, color: nil) }
        )
    }

    private var sampleImport: [PlannedQuery] {
        [
            planned("Daily", folders: ["Reports", "Daily"]),
            planned("Weekly", keyword: "wk", folders: ["Reports"]),
            planned("Loose")
        ]
    }

    @Test("An import marks each record type once and announces once")
    func oneMarkPerTypeAndOneAnnouncement() async throws {
        let announcements = AnnouncementLog(events.sqlFavoritesDidUpdate)

        let written = await manager.importSavedQueries(sampleImport)
        let write = try #require(written)

        #expect(write.insertedIds.count == 3)
        #expect(write.createdFolderIds.count == 2)
        #expect(journal.changes.map(\.kind).sorted() == ["saved_query", "saved_query_folder"])
        #expect(journal.dirtyIds(for: .favorite) == Set(write.insertedIds.map(\.uuidString)))
        #expect(journal.dirtyIds(for: .favoriteFolder) == Set(write.createdFolderIds.map(\.uuidString)))
        #expect(announcements.payloads == [nil])
    }

    @Test("Rows are committed before the journal hears of them")
    func rowsAreReadableBeforeTheyAreJournaled() async throws {
        let path = databasePath
        var seen: [CommittedRows?] = []
        let observing = journal.journal.changes.sink { _ in
            seen.append(committedRows(at: path))
        }
        defer { observing.cancel() }

        let written = await manager.importSavedQueries(sampleImport)
        let write = try #require(written)

        let expected = CommittedRows(favorites: write.insertedIds.count, folders: write.createdFolderIds.count)
        #expect(seen.count == 2)
        #expect(seen.allSatisfy { $0 == expected })
    }

    @Test("A failed import marks nothing and announces nothing")
    func failedImportMarksNothing() async throws {
        #expect(await storage.run("""
            CREATE TRIGGER refuse_import BEFORE INSERT ON favorites
            BEGIN SELECT RAISE(ABORT, 'refused'); END;
            """))
        let announcements = AnnouncementLog(events.sqlFavoritesDidUpdate)

        let write = await manager.importSavedQueries(sampleImport)

        #expect(write == nil)
        #expect(journal.changes.isEmpty)
        #expect(announcements.payloads.isEmpty)
    }

    @Test("An import that finds everything saved marks nothing and announces nothing")
    func alreadySavedImportIsSilent() async throws {
        _ = try #require(await manager.importSavedQueries(sampleImport))
        journal.clear()
        let announcements = AnnouncementLog(events.sqlFavoritesDidUpdate)

        let written = await manager.importSavedQueries(sampleImport)
        let write = try #require(written)

        #expect(write.alreadySaved == 3)
        #expect(journal.changes.isEmpty)
        #expect(announcements.payloads.isEmpty)
    }

    @Test("Ledger entries and the export snapshot cover every saved query")
    func readsCoverEveryQuery() async throws {
        let scope = UUID()
        let folder = SQLFavoriteFolder(name: "Reports", connectionId: scope)
        let global = SQLFavorite(name: "Global", query: "SELECT 1", keyword: "g")
        let scoped = SQLFavorite(name: "Scoped", query: "SELECT 2", folderId: folder.id, connectionId: scope)
        #expect(await manager.addFolder(folder))
        #expect(await manager.addFavorite(global))
        #expect(await manager.addFavorite(scoped))

        let entries = try #require(await manager.ledgerEntries())
        #expect(entries.count == 2)
        #expect(entries.contains(SavedQueryLedger.Entry(name: "Global", sql: "SELECT 1", keyword: "g", connectionId: nil)))
        #expect(entries.contains(SavedQueryLedger.Entry(name: "Scoped", sql: "SELECT 2", keyword: nil, connectionId: scope)))

        let snapshot = try #require(await manager.exportSnapshot())
        #expect(Set(snapshot.favorites.map(\.id)) == [global.id, scoped.id])
        #expect(snapshot.folders.map(\.id) == [folder.id])
    }
}

private struct CommittedRows: Equatable, Sendable {
    let favorites: Int
    let folders: Int
}

/// A second connection sees only committed rows, which is what a sync started by the mark reads.
private func committedRows(at path: String) -> CommittedRows? {
    var handle: OpaquePointer?
    defer { sqlite3_close_v2(handle) }
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return nil }

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    let sql = "SELECT (SELECT COUNT(*) FROM favorites), (SELECT COUNT(*) FROM folders);"
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_ROW
    else { return nil }
    return CommittedRows(
        favorites: Int(sqlite3_column_int(statement, 0)),
        folders: Int(sqlite3_column_int(statement, 1))
    )
}

@MainActor
private final class AnnouncementLog {
    private(set) var payloads: [UUID?] = []
    private var subscription: AnyCancellable?

    init(_ subject: PassthroughSubject<UUID?, Never>) {
        subscription = subject.sink { [weak self] payload in
            self?.payloads.append(payload)
        }
    }
}
