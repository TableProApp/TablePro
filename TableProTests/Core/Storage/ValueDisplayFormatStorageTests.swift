//
//  ValueDisplayFormatStorageTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ValueDisplayFormatStorage")
@MainActor
struct ValueDisplayFormatStorageTests {
    private func makeStorage() throws -> (ValueDisplayFormatStorage, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: "vdf-\(UUID().uuidString)"))
        return (ValueDisplayFormatStorage(defaults: defaults), defaults)
    }

    private func scope(_ schema: String, connectionId: UUID, table: String = "orders") -> TableScope {
        TableScope(connectionId: connectionId, database: "shop", schema: schema, table: table)
    }

    @Test("Round-trips and clears per scope")
    func roundTrip() throws {
        let (storage, _) = try makeStorage()
        let target = scope("public", connectionId: UUID())
        storage.save(["id": .uuid], for: target)
        #expect(storage.load(for: target) == ["id": .uuid])
        storage.clear(for: target)
        #expect(storage.load(for: target) == nil)
    }

    @Test("Same table name in different schemas does not collide")
    func schemasDoNotCollide() throws {
        let (storage, _) = try makeStorage()
        let conn = UUID()
        storage.save(["id": .uuid], for: scope("public", connectionId: conn))
        #expect(storage.load(for: scope("public", connectionId: conn)) == ["id": .uuid])
        #expect(storage.load(for: scope("archive", connectionId: conn)) == nil)
    }

    @Test("Migrates legacy schema-blind formats on first load")
    func migratesLegacy() throws {
        let (storage, defaults) = try makeStorage()
        let conn = UUID()
        let target = scope("public", connectionId: conn)
        let legacyKey = "com.TablePro.columns.displayFormat.\(conn.uuidString).orders"
        defaults.set(try JSONEncoder().encode(["id": ValueDisplayFormat.uuid]), forKey: legacyKey)

        #expect(storage.load(for: target) == ["id": .uuid])
        #expect(defaults.data(forKey: legacyKey) == nil)
        #expect(defaults.data(forKey: PreferenceKeys.columnDisplayFormats(target).name) != nil)
    }
}
