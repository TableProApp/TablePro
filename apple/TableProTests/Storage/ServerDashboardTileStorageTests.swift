//
//  ServerDashboardTileStorageTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct ServerDashboardTileStorageTests {
    @Test("Tiles are kept per connection, in order, with their intervals")
    func roundTrip() throws {
        let suite = try EphemeralDefaults()
        let defaults = suite.defaults
        let storage = ServerDashboardTileStorage(defaults: { defaults })
        let connection = UUID()
        let layout = ServerDashboardTileLayout(tiles: [
            DashboardTile(favoriteId: UUID(), interval: .fiveMinutes),
            DashboardTile(favoriteId: UUID()),
        ])

        storage.save(layout, for: connection)

        #expect(storage.load(for: connection) == layout)
        #expect(storage.load(for: UUID()) == .empty)
    }

    @Test("Removing the last tile removes the key, and so does deleting the connection")
    func emptyLayoutRemovesKey() throws {
        let suite = try EphemeralDefaults()
        let defaults = suite.defaults
        let storage = ServerDashboardTileStorage(defaults: { defaults })
        let connection = UUID()
        let key = ServerDashboardTileStorage.key(for: connection)

        storage.save(ServerDashboardTileLayout(tiles: [DashboardTile(favoriteId: UUID())]), for: connection)
        #expect(defaults.data(forKey: key) != nil)
        storage.save(.empty, for: connection)
        #expect(defaults.data(forKey: key) == nil)

        storage.save(ServerDashboardTileLayout(tiles: [DashboardTile(favoriteId: UUID())]), for: connection)
        storage.remove(for: connection)
        #expect(defaults.data(forKey: key) == nil)
    }

    @Test("A layout that cannot be read loads as empty")
    func corruptLayout() throws {
        let suite = try EphemeralDefaults()
        let defaults = suite.defaults
        let connection = UUID()
        defaults.set(Data("not json".utf8), forKey: ServerDashboardTileStorage.key(for: connection))

        #expect(ServerDashboardTileStorage(defaults: { defaults }).load(for: connection) == .empty)
    }
}
