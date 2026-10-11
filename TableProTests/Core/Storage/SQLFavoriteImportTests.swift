//
//  SQLFavoriteImportTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProImport
import Testing

struct SQLFavoriteImportTests {
    private let storage: SQLFavoriteStorage
    private let connectionId = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("sql_favorites_import_\(UUID().uuidString).db")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        storage = SQLFavoriteStorage(databaseURL: url, removeDatabaseOnDeinit: true)
    }

    private func query(
        _ name: String,
        sql: String? = nil,
        keyword: String? = nil,
        connectionId: UUID? = nil,
        folders: [PathComponent] = []
    ) -> PlannedQuery {
        PlannedQuery(
            ref: BundleRef(name),
            name: name,
            sql: sql ?? "SELECT '\(name)'",
            keyword: keyword,
            connectionId: connectionId,
            folderPath: folders
        )
    }

    private func folder(_ name: String, scope: UUID? = nil) -> PathComponent {
        PathComponent(name: name, scope: scope, color: nil)
    }

    private func favorite(named name: String) async throws -> SQLFavorite {
        try #require(await storage.fetchFavorites().first { $0.name == name })
    }

    private func folder(named name: String, scope: UUID? = nil) async throws -> SQLFavoriteFolder {
        try #require(await storage.fetchFolders().first { $0.name == name && $0.connectionId == scope })
    }

    @Test("Imported rows and folders take the import time and sort order 0")
    func importedRowsTakeTheImportTime() async throws {
        let written = await storage.importSavedQueries([query("Daily", folders: [folder("Reports")])], now: now)
        let write = try #require(written)

        #expect(write.insertedIds.count == 1)
        #expect(write.createdFolderIds.count == 1)
        let daily = try await favorite(named: "Daily")
        let reports = try await folder(named: "Reports")
        #expect(write.insertedIds == [daily.id])
        #expect(write.createdFolderIds == [reports.id])
        #expect(daily.folderId == reports.id)
        #expect(daily.sortOrder == 0)
        #expect(daily.createdAt == now)
        #expect(daily.updatedAt == now)
        #expect(reports.sortOrder == 0)
        #expect(reports.createdAt == now)
        #expect(reports.updatedAt == now)
    }

    @Test("Folders match by path and by scope")
    func foldersMatchByPathAndScope() async throws {
        let reports = SQLFavoriteFolder(name: "Reports")
        #expect(await storage.addFolder(reports))

        let written = await storage.importSavedQueries([
            query("Global daily", folders: [folder("reports"), folder("Daily")]),
            query("Scoped", connectionId: connectionId, folders: [folder("Reports", scope: connectionId)])
        ], now: now)
        let write = try #require(written)

        #expect(write.createdFolderIds.count == 2)
        let daily = try await folder(named: "Daily")
        #expect(daily.parentId == reports.id)
        let scopedReports = try await folder(named: "Reports", scope: connectionId)
        #expect(scopedReports.parentId == nil)
        #expect(try await favorite(named: "Global daily").folderId == daily.id)
        #expect(try await favorite(named: "Scoped").folderId == scopedReports.id)
    }

    @Test("A folder that cannot hold the query is cut from the path")
    func folderThatCannotHoldIsCut() async throws {
        let written = await storage.importSavedQueries([
            query("Everywhere", folders: [folder("Team"), folder("Mine", scope: connectionId)]),
            query("Mine only", connectionId: connectionId, folders: [folder("Scoped", scope: connectionId), folder("Shared")])
        ], now: now)
        _ = try #require(written)

        let folderNames = await storage.fetchFolders().map(\.name)
        #expect(Set(folderNames) == ["Team", "Scoped"])
        let team = try await folder(named: "Team")
        let scoped = try await folder(named: "Scoped", scope: connectionId)
        #expect(try await favorite(named: "Everywhere").folderId == team.id)
        #expect(try await favorite(named: "Mine only").folderId == scoped.id)
    }

    @Test("A keyword already taken is dropped instead of hitting the unique index")
    func takenKeywordIsDropped() async throws {
        #expect(await storage.addFavorite(SQLFavorite(name: "Local", query: "SELECT 1", keyword: "dau")))

        let written = await storage.importSavedQueries([
            query("Scoped dau", keyword: "dau", connectionId: connectionId),
            query("First mau", keyword: "mau", connectionId: connectionId),
            query("Second mau", keyword: "mau", connectionId: connectionId),
            query("Spaced", keyword: "two words", connectionId: connectionId)
        ], now: now)
        let write = try #require(written)

        #expect(write.insertedIds.count == 4)
        #expect(write.droppedKeywords == 3)
        #expect(try await favorite(named: "Local").keyword == "dau")
        #expect(try await favorite(named: "Scoped dau").keyword == nil)
        #expect(try await favorite(named: "First mau").keyword == "mau")
        #expect(try await favorite(named: "Second mau").keyword == nil)
        #expect(try await favorite(named: "Spaced").keyword == nil)
    }

    @Test("Importing the same queries again adds nothing")
    func reimportIsIdempotent() async throws {
        let queries = [
            query("Daily", folders: [folder("Reports")]),
            query("Scoped", connectionId: connectionId)
        ]
        _ = try #require(await storage.importSavedQueries(queries, now: now))

        let again = try #require(await storage.importSavedQueries(queries, now: now))

        #expect(again.insertedIds.isEmpty)
        #expect(again.createdFolderIds.isEmpty)
        #expect(again.alreadySaved == 2)
        #expect(await storage.fetchFavorites().count == 2)
        #expect(await storage.fetchFolders().count == 1)
    }

    @Test("Same name with different SQL imports beside the saved one")
    func sameNameDifferentSQLImports() async throws {
        #expect(await storage.addFavorite(SQLFavorite(name: "Daily", query: "SELECT 1")))

        let written = await storage.importSavedQueries([query("daily", sql: "SELECT 2")], now: now)
        let write = try #require(written)

        #expect(write.insertedIds.count == 1)
        #expect(await storage.fetchFavorites().count == 2)
    }

    @Test("A query over the sync limit is counted and not written")
    func tooLargeIsNotWritten() async throws {
        let huge = String(repeating: "x", count: SavedQuerySize.maximumSyncableByteCount + 1)

        let written = await storage.importSavedQueries([query("Huge", sql: huge)], now: now)
        let write = try #require(written)

        #expect(write.tooLarge == 1)
        #expect(write.insertedIds.isEmpty)
        #expect(await storage.fetchFavorites().isEmpty)
    }

    @Test("A blank name is taken from the SQL")
    func blankNameIsDerived() async throws {
        let written = await storage.importSavedQueries(
            [query("  ", sql: "-- Active users\nSELECT * FROM users")],
            now: now
        )
        _ = try #require(written)

        #expect(await storage.fetchFavorites().map(\.name) == ["Active users"])
    }

    @Test("A failure part way through rolls back every row and folder")
    func failureRollsBackEverything() async throws {
        #expect(await storage.run("""
            CREATE TRIGGER refuse_import BEFORE INSERT ON favorites WHEN NEW.name = 'Refused'
            BEGIN SELECT RAISE(ABORT, 'refused'); END;
            """))

        let write = await storage.importSavedQueries([
            query("Accepted", folders: [folder("Created")]),
            query("Refused")
        ], now: now)

        #expect(write == nil)
        #expect(await storage.fetchFavorites().isEmpty)
        #expect(await storage.fetchFolders().isEmpty)
    }

    @Test("Nothing to import writes nothing")
    func emptyImportWritesNothing() async {
        let write = await storage.importSavedQueries([], now: now)

        #expect(write == SavedQueryImportWrite(
            insertedIds: [],
            createdFolderIds: [],
            alreadySaved: 0,
            droppedKeywords: 0,
            tooLarge: 0
        ))
    }
}
