//
//  SQLFavoriteVersionTests.swift
//  TableProTests
//

import Foundation
import SQLite3
import TableProSyncTransport
import Testing

@testable import TablePro

struct SQLFavoriteVersionTests {
    private let storage: SQLFavoriteStorage
    private let defaults: UserDefaults
    private let tracker: SyncChangeTracker

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("sql_favorites_versions_\(UUID().uuidString).db")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        storage = SQLFavoriteStorage(databaseURL: url, removeDatabaseOnDeinit: true)
        defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.SQLFavoriteVersions.\(UUID().uuidString)"))
        tracker = SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: defaults))
    }

    private func makeFavorite(name: String = "Revenue", query: String = "SELECT 1", updatedAt: Date = Date(timeIntervalSince1970: 100)) -> SQLFavorite {
        SQLFavorite(name: name, query: query, createdAt: updatedAt, updatedAt: updatedAt)
    }

    @Test("Changing the query records the text it replaced, with the time that text was saved")
    func changingQueryRecordsPreviousText() async throws {
        var favorite = makeFavorite(query: "SELECT 1")
        #expect(await storage.addFavorite(favorite))

        favorite.query = "SELECT 2"
        favorite.updatedAt = Date(timeIntervalSince1970: 200)
        #expect(await storage.updateFavorite(favorite).succeeded)

        let versions = await storage.fetchVersions(favoriteId: favorite.id)
        let version = try #require(versions.first)
        #expect(versions.count == 1)
        #expect(version.query == "SELECT 1")
        #expect(version.name == "Revenue")
        #expect(version.savedAt == Date(timeIntervalSince1970: 100))
    }

    @Test("A write that leaves the query text alone records nothing")
    func unchangedQueryRecordsNothing() async {
        var favorite = makeFavorite()
        #expect(await storage.addFavorite(favorite))

        favorite.name = "Renamed"
        favorite.keyword = "rev"
        favorite.updatedAt = Date(timeIntervalSince1970: 300)
        #expect(await storage.updateFavorite(favorite).succeeded)

        #expect(await storage.fetchVersions(favoriteId: favorite.id).isEmpty)
    }

    @Test("A sync upsert that changes the text records the local text it replaced")
    func syncUpsertRecordsPreviousText() async {
        var favorite = makeFavorite(query: "SELECT local")
        #expect(await storage.addFavorite(favorite))

        favorite.query = "SELECT remote"
        #expect(await storage.upsertFavorite(favorite).succeeded)
        #expect(await storage.upsertFavorite(favorite).succeeded)

        let versions = await storage.fetchVersions(favoriteId: favorite.id)
        #expect(versions.map(\.query) == ["SELECT local"])
    }

    @Test("Each query keeps only its most recent versions, newest first, without touching other queries")
    func pruningIsPerFavorite() async {
        var favorite = makeFavorite(query: "SELECT 0")
        let other = makeFavorite(name: "Other", query: "SELECT other")
        #expect(await storage.addFavorite(favorite))
        #expect(await storage.addFavorite(other))

        var otherEdit = other
        otherEdit.query = "SELECT other 2"
        #expect(await storage.updateFavorite(otherEdit).succeeded)

        let limit = SQLFavoriteStorage.retainedVersionCount
        for index in 1...(limit + 5) {
            favorite.query = "SELECT \(index)"
            #expect(await storage.updateFavorite(favorite).succeeded)
        }

        let versions = await storage.fetchVersions(favoriteId: favorite.id)
        #expect(versions.count == limit)
        #expect(versions.first?.query == "SELECT \(limit + 4)")
        #expect(versions.last?.query == "SELECT 5")
        #expect(await storage.fetchVersions(favoriteId: other.id).map(\.query) == ["SELECT other"])
    }

    @Test("Deleting a query deletes its versions")
    func deletingFavoriteDeletesVersions() async {
        var favorite = makeFavorite()
        #expect(await storage.addFavorite(favorite))
        favorite.query = "SELECT 2"
        #expect(await storage.updateFavorite(favorite).succeeded)
        #expect(await storage.fetchVersions(favoriteId: favorite.id).count == 1)

        #expect(await storage.deleteFavorite(id: favorite.id))

        #expect(await storage.fetchVersions(favoriteId: favorite.id).isEmpty)
    }

    @Test("Restoring writes the old text, records the text it replaced, and marks the query for sync")
    func restoreRecordsReplacedTextAndMarksDirty() async throws {
        let manager = SQLFavoriteManager(storage: storage, syncTracker: tracker)
        var favorite = makeFavorite(query: "SELECT old")
        #expect(await storage.addFavorite(favorite))
        favorite.query = "SELECT new"
        #expect(await storage.updateFavorite(favorite).succeeded)
        let old = try #require(await manager.fetchVersions(favoriteId: favorite.id).first)

        #expect(await manager.restore(old))

        let restored = try #require(await manager.fetchFavorite(id: favorite.id))
        #expect(restored.query == "SELECT old")
        #expect(restored.name == "Revenue")
        #expect(await manager.fetchVersions(favoriteId: favorite.id).map(\.query) == ["SELECT new", "SELECT old"])
        #expect(tracker.dirtyRecords(for: .favorite).contains(favorite.id.uuidString))
    }

    @Test("Restoring a version of a deleted query fails")
    func restoreOfDeletedFavoriteFails() async throws {
        let manager = SQLFavoriteManager(storage: storage, syncTracker: tracker)
        var favorite = makeFavorite(query: "SELECT old")
        #expect(await storage.addFavorite(favorite))
        favorite.query = "SELECT new"
        #expect(await storage.updateFavorite(favorite).succeeded)
        let old = try #require(await manager.fetchVersions(favoriteId: favorite.id).first)
        #expect(await storage.deleteFavorite(id: favorite.id))

        #expect(await manager.restore(old) == false)
    }

    @Test("Reopening the database keeps the versions and does not duplicate the triggers")
    func reopeningKeepsVersions() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("sql_favorites_reopen_\(UUID().uuidString).db")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        var favorite = makeFavorite(query: "SELECT 1")
        do {
            let first = SQLFavoriteStorage(databaseURL: url)
            #expect(await first.addFavorite(favorite))
            favorite.query = "SELECT 2"
            #expect(await first.updateFavorite(favorite).succeeded)
        }

        let reopened = SQLFavoriteStorage(databaseURL: url)
        favorite.query = "SELECT 3"
        #expect(await reopened.updateFavorite(favorite).succeeded)

        #expect(await reopened.fetchVersions(favoriteId: favorite.id).map(\.query) == ["SELECT 2", "SELECT 1"])
    }

    @Test("A database upgraded from the first schema records versions on its first launch")
    func upgradeFromFirstSchemaKeepsVersionTriggers() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("sql_favorites_v1_\(UUID().uuidString).db")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        let id = UUID()
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        let seed = """
            CREATE TABLE favorites (id TEXT PRIMARY KEY, name TEXT NOT NULL, query TEXT NOT NULL, keyword TEXT,
                folder_id TEXT, connection_id TEXT, sort_order INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL, updated_at REAL NOT NULL);
            CREATE TABLE folders (id TEXT PRIMARY KEY, name TEXT NOT NULL, parent_id TEXT, connection_id TEXT,
                sort_order INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, updated_at REAL NOT NULL);
            INSERT INTO favorites VALUES ('\(id.uuidString)', 'Revenue', 'SELECT 1', NULL, NULL, NULL, 0, 1, 1);
            PRAGMA user_version = 1;
            """
        #expect(sqlite3_exec(handle, seed, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        let upgraded = SQLFavoriteStorage(databaseURL: url)
        var favorite = try #require(await upgraded.fetchFavorite(id: id))
        favorite.name = "Renamed"
        favorite.updatedAt = Date(timeIntervalSince1970: 5)
        #expect(await upgraded.updateFavorite(favorite).succeeded)
        favorite.query = "SELECT 2"
        favorite.updatedAt = Date(timeIntervalSince1970: 9)
        #expect(await upgraded.updateFavorite(favorite).succeeded)

        let version = try #require(await upgraded.fetchVersions(favoriteId: id).first)
        #expect(version.query == "SELECT 1")
        #expect(version.savedAt == Date(timeIntervalSince1970: 1))
    }

    @Test("A rename or keyword change does not move the saved time of the SQL it did not touch")
    func metadataEditsKeepTheQuerySaveTime() async throws {
        var favorite = makeFavorite(query: "SELECT 1", updatedAt: Date(timeIntervalSince1970: 100))
        #expect(await storage.addFavorite(favorite))

        favorite.name = "Renamed"
        favorite.updatedAt = Date(timeIntervalSince1970: 200)
        #expect(await storage.updateFavorite(favorite).succeeded)
        #expect(await storage.querySavedAt(favoriteId: favorite.id) == Date(timeIntervalSince1970: 100))

        favorite.query = "SELECT 2"
        favorite.updatedAt = Date(timeIntervalSince1970: 300)
        #expect(await storage.upsertFavorite(favorite).succeeded)

        let version = try #require(await storage.fetchVersions(favoriteId: favorite.id).first)
        #expect(version.savedAt == Date(timeIntervalSince1970: 100))
        #expect(await storage.querySavedAt(favoriteId: favorite.id) == Date(timeIntervalSince1970: 300))
    }
}
