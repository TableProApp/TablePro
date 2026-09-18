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

    @Test("Explicit Raw format survives reload")
    func rawOverrideRoundTrip() throws {
        let (storage, _) = try makeStorage()
        let target = scope("public", connectionId: UUID())

        storage.save(["id": .raw], for: target)

        #expect(storage.load(for: target) == ["id": .raw])
    }

    @Test("Explicit Raw overrides automatic UUID detection")
    func rawOverridesAutomaticDetection() throws {
        let (storage, _) = try makeStorage()
        let service = ValueDisplayFormatService(storage: storage)
        let target = scope("public", connectionId: UUID())
        service.setAutoDetectedFormats(["id": .uuid], scope: target)

        service.setOverride(.raw, columnKey: "id", scope: target)

        #expect(service.effectiveFormat(columnKey: "id", scope: target) == .raw)
        #expect(storage.load(for: target) == ["id": .raw])
    }

    @Test("Duplicate column occurrences persist independent formats")
    func duplicateColumnOverridesDoNotCollide() throws {
        let (storage, _) = try makeStorage()
        let service = ValueDisplayFormatService(storage: storage)
        let target = scope("public", connectionId: UUID())
        let keys = ValueDisplayFormatColumnKey.storageKeys(for: ["value", "value"])

        service.setOverride(.uuid, columnKey: keys[0], scope: target)
        service.setOverride(.raw, columnKey: keys[1], scope: target)

        #expect(service.effectiveFormat(columnKey: keys[0], scope: target) == .uuid)
        #expect(service.effectiveFormat(columnKey: keys[1], scope: target) == .raw)
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

    @Test("A table rename moves its formats and leaves a longer name alone")
    func renameTableMovesOnlyThatTable() throws {
        let (storage, _) = try makeStorage()
        let conn = UUID()
        let other = UUID()
        storage.save(["id": .uuid], for: scope("public", connectionId: conn))
        storage.save(["ref": .json], for: scope("public", connectionId: conn, table: "orders_archive"))
        storage.save(["id": .json], for: scope("public", connectionId: other))

        storage.renameTable(
            from: scope("public", connectionId: conn),
            to: scope("public", connectionId: conn, table: "purchases")
        )

        #expect(storage.load(for: scope("public", connectionId: conn)) == nil)
        #expect(storage.load(for: scope("public", connectionId: conn, table: "purchases")) == ["id": .uuid])
        #expect(storage.load(for: scope("public", connectionId: conn, table: "orders_archive")) == ["ref": .json])
        #expect(storage.load(for: scope("public", connectionId: other)) == ["id": .json])
    }

    @Test("A table rename carries formats still stored under the legacy key")
    func renameTableMigratesLegacy() throws {
        let (storage, defaults) = try makeStorage()
        let conn = UUID()
        let legacyKey = "com.TablePro.columns.displayFormat.\(conn.uuidString).orders"
        defaults.set(try JSONEncoder().encode(["id": ValueDisplayFormat.uuid]), forKey: legacyKey)

        storage.renameTable(
            from: scope("public", connectionId: conn),
            to: scope("public", connectionId: conn, table: "purchases")
        )

        #expect(defaults.data(forKey: legacyKey) == nil)
        #expect(storage.load(for: scope("public", connectionId: conn, table: "purchases")) == ["id": .uuid])
        #expect(storage.load(for: scope("public", connectionId: conn)) == nil)
    }

    @Test("A schema rename moves every table in it and nothing outside it")
    func renameContainerMovesTheSchema() throws {
        let (storage, _) = try makeStorage()
        let conn = UUID()
        let other = UUID()
        storage.save(["id": .uuid], for: scope("public", connectionId: conn))
        storage.save(["ref": .json], for: scope("public", connectionId: conn, table: "items"))
        storage.save(["id": .json], for: scope("public_old", connectionId: conn))
        storage.save(["id": .uuid], for: scope("public", connectionId: other))

        storage.renameContainer(
            connectionId: conn, fromDatabase: "shop", fromSchema: "public", toDatabase: "shop", toSchema: "sales"
        )

        #expect(storage.load(for: scope("sales", connectionId: conn)) == ["id": .uuid])
        #expect(storage.load(for: scope("sales", connectionId: conn, table: "items")) == ["ref": .json])
        #expect(storage.load(for: scope("public", connectionId: conn)) == nil)
        #expect(storage.load(for: scope("public_old", connectionId: conn)) == ["id": .json])
        #expect(storage.load(for: scope("public", connectionId: other)) == ["id": .uuid])
    }

    @Test("A database rename moves every schema in it")
    func renameDatabaseMovesEverySchema() throws {
        let (storage, _) = try makeStorage()
        let conn = UUID()
        storage.save(["id": .uuid], for: scope("public", connectionId: conn))
        storage.save(["id": .json], for: scope("archive", connectionId: conn))
        let longerName = TableScope(connectionId: conn, database: "shopping", schema: "public", table: "orders")
        storage.save(["id": .text], for: longerName)

        storage.renameContainer(
            connectionId: conn, fromDatabase: "shop", fromSchema: nil, toDatabase: "store", toSchema: nil
        )

        let moved = TableScope(connectionId: conn, database: "store", schema: "public", table: "orders")
        let movedArchive = TableScope(connectionId: conn, database: "store", schema: "archive", table: "orders")
        #expect(storage.load(for: moved) == ["id": .uuid])
        #expect(storage.load(for: movedArchive) == ["id": .json])
        #expect(storage.load(for: longerName) == ["id": .text])
        #expect(storage.load(for: scope("public", connectionId: conn)) == nil)
    }

    @Test("Deleting a connection removes its formats, legacy keys included, and keeps the rest")
    func purgeConnectionsRemovesOnlyThatConnection() throws {
        let (storage, defaults) = try makeStorage()
        let conn = UUID()
        let other = UUID()
        let legacyKey = "com.TablePro.columns.displayFormat.\(conn.uuidString).customers"
        defaults.set(try JSONEncoder().encode(["id": ValueDisplayFormat.uuid]), forKey: legacyKey)
        storage.save(["id": .uuid], for: scope("public", connectionId: conn))
        storage.save(["id": .json], for: scope("public", connectionId: other))

        storage.purgeConnections([conn])

        #expect(defaults.data(forKey: PreferenceKeys.columnDisplayFormats(scope("public", connectionId: conn)).name) == nil)
        #expect(defaults.data(forKey: legacyKey) == nil)
        #expect(storage.load(for: scope("public", connectionId: other)) == ["id": .json])
    }
}
