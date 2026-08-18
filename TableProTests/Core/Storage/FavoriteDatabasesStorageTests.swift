//
//  FavoriteDatabasesStorageTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@MainActor
@Suite("FavoriteDatabasesStorage")
struct FavoriteDatabasesStorageTests {
    private func makeStorage() throws -> (FavoriteDatabasesStorage, UserDefaults) {
        let suite = "FavoriteDatabasesStorageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (FavoriteDatabasesStorage(defaults: defaults), defaults)
    }

    @Test("Favorite identity includes the connection")
    func favoritesAreConnectionScoped() throws {
        let (storage, _) = try makeStorage()
        let first = UUID()
        let second = UUID()

        storage.setFavorite(database: "app", environment: .development, connectionId: first)
        storage.setFavorite(database: "app", environment: .production, connectionId: second)

        #expect(storage.favorites(for: first).first?.environment == .development)
        #expect(storage.favorites(for: second).first?.environment == .production)
    }

    @Test("Changing an environment replaces the favorite instead of duplicating it")
    func environmentUpdateReplacesEntry() throws {
        let (storage, _) = try makeStorage()
        let connectionId = UUID()

        storage.setFavorite(database: "orders", environment: .development, connectionId: connectionId)
        storage.setFavorite(database: "orders", environment: .testing, connectionId: connectionId)

        let entries = storage.favorites(for: connectionId)
        #expect(entries.count == 1)
        #expect(entries.first?.environment == .testing)
    }

    @Test("Removing one database preserves the connection's other favorites")
    func removePreservesOtherEntries() throws {
        let (storage, _) = try makeStorage()
        let connectionId = UUID()
        storage.setFavorite(database: "app", environment: .development, connectionId: connectionId)
        storage.setFavorite(database: "audit", environment: .testing, connectionId: connectionId)

        storage.removeFavorite(database: "app", connectionId: connectionId)

        #expect(storage.favorites(for: connectionId).map(\.database) == ["audit"])
    }

    @Test("An unknown stored environment falls back to Unassigned")
    func unknownEnvironmentFallsBack() throws {
        let (storage, defaults) = try makeStorage()
        let connectionId = UUID()
        let json = """
        [{"connectionId":"\(connectionId.uuidString)","database":"future","environment":"staging"}]
        """
        defaults.set(
            Data(json.utf8),
            forKey: "com.TablePro.favoriteDatabases.\(connectionId.uuidString)"
        )

        #expect(
            storage.favorites(for: connectionId).first?.environment
                == FavoriteDatabaseEnvironment.none
        )
    }

    @Test("Malformed storage is contained to the affected connection")
    func malformedStorageReturnsEmpty() throws {
        let (storage, defaults) = try makeStorage()
        let connectionId = UUID()
        defaults.set(
            Data("not-json".utf8),
            forKey: "com.TablePro.favoriteDatabases.\(connectionId.uuidString)"
        )

        #expect(storage.favorites(for: connectionId).isEmpty)
    }

    @Test("Stored entries cannot cross connection boundaries")
    func ignoresEntriesFromAnotherConnection() throws {
        let (storage, defaults) = try makeStorage()
        let requestedConnectionId = UUID()
        let foreignConnectionId = UUID()
        let json = """
        [{"connectionId":"\(foreignConnectionId.uuidString)","database":"private","environment":"production"}]
        """
        defaults.set(
            Data(json.utf8),
            forKey: "com.TablePro.favoriteDatabases.\(requestedConnectionId.uuidString)"
        )

        #expect(storage.favorites(for: requestedConnectionId).isEmpty)
    }

    @Test("Deleting a connection removes its persisted favorites")
    func removeConnectionFavorites() throws {
        let (storage, defaults) = try makeStorage()
        let connectionId = UUID()
        storage.setFavorite(database: "app", environment: .production, connectionId: connectionId)

        storage.removeFavorites(for: connectionId)

        #expect(storage.favorites(for: connectionId).isEmpty)
        #expect(defaults.object(forKey: "com.TablePro.favoriteDatabases.\(connectionId.uuidString)") == nil)
    }
}
