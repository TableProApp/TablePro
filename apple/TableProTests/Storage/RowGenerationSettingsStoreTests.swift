//
//  RowGenerationSettingsStoreTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@MainActor
struct RowGenerationSettingsStoreTests {
    private let suite: EphemeralDefaults

    init() throws {
        suite = try EphemeralDefaults()
    }

    private func makeStore() -> RowGenerationSettingsStore {
        RowGenerationSettingsStore(defaults: suite.defaults)
    }

    private func scope(_ connectionId: UUID, database: String = "shop", schema: String? = "public", table: String = "people") -> TableScope {
        TableScope(connectionId: connectionId, database: database, schema: schema, table: table)
    }

    private func settings(rowCount: Int) -> RowGenerationSettings {
        var column = RowGeneratorSettings(kind: .pattern, dateStart: Date(timeIntervalSince1970: 0), dateEnd: Date(timeIntervalSince1970: 86_400))
        column.pattern = "AB-###"
        column.uuidVersion = .v7
        return RowGenerationSettings(rowCount: rowCount, seed: 99, columns: ["code": column])
    }

    @Test("Settings saved for a table come back for that table only")
    func roundTrip() {
        let store = makeStore()
        let connectionId = UUID()
        store.save(settings(rowCount: 500), for: scope(connectionId))

        #expect(store.settings(for: scope(connectionId)) == settings(rowCount: 500))
        #expect(store.settings(for: scope(connectionId, table: "orders")) == nil)
        #expect(store.settings(for: scope(connectionId, schema: "archive")) == nil)
        #expect(store.settings(for: scope(UUID())) == nil)
    }

    @Test("Renaming the table or its schema carries the settings along")
    func renamesFollowTheTable() {
        let store = makeStore()
        let connectionId = UUID()
        store.save(settings(rowCount: 3), for: scope(connectionId))

        store.renameTable(from: scope(connectionId), to: scope(connectionId, table: "customers"))
        #expect(store.settings(for: scope(connectionId, table: "customers"))?.rowCount == 3)

        store.renameContainer(connectionId: connectionId, fromDatabase: "shop", fromSchema: "public", toDatabase: "shop", toSchema: "crm")
        #expect(store.settings(for: scope(connectionId, schema: "crm", table: "customers"))?.rowCount == 3)
        #expect(store.settings(for: scope(connectionId, table: "customers")) == nil)
    }

    @Test("Dropping the table, its schema or the connection forgets the settings")
    func dropsForget() {
        let store = makeStore()
        let connectionId = UUID()
        store.save(settings(rowCount: 1), for: scope(connectionId))
        store.dropTable(scope(connectionId))
        #expect(store.settings(for: scope(connectionId)) == nil)

        store.save(settings(rowCount: 1), for: scope(connectionId))
        store.dropContainer(connectionId: connectionId, database: "shop", schema: "public")
        #expect(store.settings(for: scope(connectionId)) == nil)

        store.save(settings(rowCount: 1), for: scope(connectionId))
        store.purgeConnections([connectionId], leavesTombstones: true)
        #expect(store.settings(for: scope(connectionId)) == nil)
    }
}
