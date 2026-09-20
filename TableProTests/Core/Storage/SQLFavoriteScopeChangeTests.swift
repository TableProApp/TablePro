//
//  SQLFavoriteScopeChangeTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

/// A global favorite is in every connection's list, so moving one into a single connection takes it
/// out of every other connection's. The event has to say so, or the sidebar, the editor's keyword
/// expansion and the Quick Switcher all go on offering a favorite that has left them.
@Suite("SQL favorite scope changes")
struct SQLFavoriteScopeChangeTests {
    private let storage: SQLFavoriteStorage

    init() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("sql_favorites_scope_\(UUID().uuidString).db")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.storage = SQLFavoriteStorage(databaseURL: url, removeDatabaseOnDeinit: true)
    }

    // MARK: - What the write reports

    @Test("Updating a global favorite reports the scope it is leaving")
    func updatingAGlobalFavoriteReportsItWasGlobal() async {
        var favorite = SQLFavorite(name: "Truncate staging", query: "TRUNCATE TABLE staging;", connectionId: nil)
        #expect(await storage.addFavorite(favorite))

        favorite.connectionId = UUID()

        #expect(await storage.updateFavorite(favorite) == .updatedExisting(previousConnectionId: nil))
    }

    @Test("Updating a scoped favorite reports the connection it belonged to")
    func updatingAScopedFavoriteReportsItsConnection() async {
        let connectionId = UUID()
        var favorite = SQLFavorite(name: "Active users", query: "SELECT 1", connectionId: connectionId)
        #expect(await storage.addFavorite(favorite))

        favorite.name = "Active users today"

        #expect(await storage.updateFavorite(favorite) == .updatedExisting(previousConnectionId: connectionId))
    }

    @Test("Updating a favorite that is no longer stored fails rather than reporting success")
    func updatingAMissingFavoriteFails() async {
        let favorite = SQLFavorite(name: "Gone", query: "SELECT 1")

        #expect(await storage.updateFavorite(favorite) == .failed)
    }

    @Test("Updating a global folder reports the scope it is leaving")
    func updatingAGlobalFolderReportsItWasGlobal() async {
        var folder = SQLFavoriteFolder(name: "Reports", connectionId: nil)
        #expect(await storage.addFolder(folder))

        folder.connectionId = UUID()

        #expect(await storage.updateFolder(folder) == .updatedExisting(previousConnectionId: nil))
    }

    @Test("Updating a folder that is no longer stored fails rather than reporting success")
    func updatingAMissingFolderFails() async {
        let folder = SQLFavoriteFolder(name: "Gone")

        #expect(await storage.updateFolder(folder) == .failed)
    }

    @Test("A synced favorite the device has never seen is reported as new")
    func upsertingAnUnseenFavoriteReportsAnInsert() async {
        let favorite = SQLFavorite(name: "From another Mac", query: "SELECT 1", connectionId: UUID())

        #expect(await storage.upsertFavorite(favorite) == .insertedNew)
    }

    @Test("A synced favorite that rescopes an existing one reports the scope it is leaving")
    func upsertingOverAGlobalFavoriteReportsItWasGlobal() async {
        var favorite = SQLFavorite(name: "Truncate staging", query: "TRUNCATE TABLE staging;", connectionId: nil)
        #expect(await storage.addFavorite(favorite))

        favorite.connectionId = UUID()

        #expect(await storage.upsertFavorite(favorite) == .updatedExisting(previousConnectionId: nil))
    }

    @Test("A synced folder the device has never seen is reported as new")
    func upsertingAnUnseenFolderReportsAnInsert() async {
        let folder = SQLFavoriteFolder(name: "From another Mac", connectionId: UUID())

        #expect(await storage.upsertFolder(folder) == .insertedNew)
    }

    @Test("A rescoped favorite keeps the scope it was given")
    func aRescopedFavoriteIsStoredWithItsNewScope() async {
        let connectionId = UUID()
        var favorite = SQLFavorite(name: "Truncate staging", query: "TRUNCATE TABLE staging;", connectionId: nil)
        #expect(await storage.addFavorite(favorite))

        favorite.connectionId = connectionId
        _ = await storage.updateFavorite(favorite)

        let stored = await storage.fetchFavorite(id: favorite.id)
        #expect(stored?.connectionId == connectionId)
    }

    // MARK: - Who the change is announced to

    @Test("A favorite leaving global scope is announced to every connection")
    func leavingGlobalScopeIsAnnouncedToEveryone() {
        let announced = SQLFavoriteManager.scopeToAnnounce(
            for: .updatedExisting(previousConnectionId: nil),
            newConnectionId: UUID()
        )

        #expect(announced == nil, "Every connection was listing it, so every connection has to drop it")
    }

    @Test("A favorite becoming global is announced to every connection")
    func becomingGlobalIsAnnouncedToEveryone() {
        let announced = SQLFavoriteManager.scopeToAnnounce(
            for: .updatedExisting(previousConnectionId: UUID()),
            newConnectionId: nil
        )

        #expect(announced == nil)
    }

    @Test("A favorite moved between two connections is announced to every connection")
    func movingBetweenConnectionsIsAnnouncedToEveryone() {
        let announced = SQLFavoriteManager.scopeToAnnounce(
            for: .updatedExisting(previousConnectionId: UUID()),
            newConnectionId: UUID()
        )

        #expect(announced == nil)
    }

    @Test("An edit that leaves the scope alone is announced to that connection only")
    func anEditWithinOneConnectionStaysThere() {
        let connectionId = UUID()

        let announced = SQLFavoriteManager.scopeToAnnounce(
            for: .updatedExisting(previousConnectionId: connectionId),
            newConnectionId: connectionId
        )

        #expect(announced == connectionId)
    }

    @Test("An edit to a global favorite that stays global is announced to every connection")
    func anEditWithinGlobalScopeStaysGlobal() {
        let announced = SQLFavoriteManager.scopeToAnnounce(
            for: .updatedExisting(previousConnectionId: nil),
            newConnectionId: nil
        )

        #expect(announced == nil)
    }

    @Test("A newly stored favorite is announced to the connection it was made for")
    func aNewFavoriteIsAnnouncedToItsOwnConnection() {
        let connectionId = UUID()

        #expect(SQLFavoriteManager.scopeToAnnounce(for: .insertedNew, newConnectionId: connectionId) == connectionId)
    }
}
