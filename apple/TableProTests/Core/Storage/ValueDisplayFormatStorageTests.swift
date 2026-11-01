//
//  ValueDisplayFormatStorageTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct ValueDisplayFormatStorageTests {
    private let pool = EphemeralDefaultsPool()

    private func makeStorage() throws -> (ValueDisplayFormatStorage, UserDefaults) {
        let defaults = try pool.make().defaults
        return (ValueDisplayFormatStorage(defaults: defaults), defaults)
    }

    private func scope(_ schema: String, connectionId: UUID, table: String = "orders") -> TableScope {
        TableScope(connectionId: connectionId, database: "shop", schema: schema, table: table)
    }

    @Test("Dropping a table forgets its formats and leaves its siblings alone")
    func dropTableForgetsOnlyThatTable() throws {
        let (storage, _) = try makeStorage()
        let connectionId = UUID()
        let dropped = scope("public", connectionId: connectionId, table: "orders")
        let kept = scope("public", connectionId: connectionId, table: "customers")
        storage.save(["id": .uuid], for: dropped)
        storage.save(["id": .uuid], for: kept)

        storage.dropTable(dropped)

        #expect(storage.load(for: dropped) == nil)
        #expect(storage.load(for: kept) == ["id": .uuid])
    }

    @Test("Dropping a schema forgets every table in it and nothing outside it")
    func dropContainerForgetsTheWholeSchema() throws {
        let (storage, _) = try makeStorage()
        let connectionId = UUID()
        let inSchema = scope("public", connectionId: connectionId, table: "orders")
        let alsoInSchema = scope("public", connectionId: connectionId, table: "invoices")
        let otherSchema = scope("billing", connectionId: connectionId, table: "orders")
        for target in [inSchema, alsoInSchema, otherSchema] {
            storage.save(["id": .uuid], for: target)
        }

        storage.dropContainer(connectionId: connectionId, database: "shop", schema: "public")

        #expect(storage.load(for: inSchema) == nil)
        #expect(storage.load(for: alsoInSchema) == nil)
        #expect(storage.load(for: otherSchema) == ["id": .uuid])
    }

    @Test("Dropping a database forgets every schema under it")
    func dropContainerWithoutSchemaForgetsTheDatabase() throws {
        let (storage, _) = try makeStorage()
        let connectionId = UUID()
        let publicScope = scope("public", connectionId: connectionId)
        let billingScope = scope("billing", connectionId: connectionId)
        let otherConnection = scope("public", connectionId: UUID())
        for target in [publicScope, billingScope, otherConnection] {
            storage.save(["id": .uuid], for: target)
        }

        storage.dropContainer(connectionId: connectionId, database: "shop", schema: nil)

        #expect(storage.load(for: publicScope) == nil)
        #expect(storage.load(for: billingScope) == nil)
        #expect(storage.load(for: otherConnection) == ["id": .uuid])
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

        storage.purgeConnections([conn], leavesTombstones: true)

        #expect(defaults.data(forKey: PreferenceKeys.columnDisplayFormats(scope("public", connectionId: conn)).name) == nil)
        #expect(defaults.data(forKey: legacyKey) == nil)
        #expect(storage.load(for: scope("public", connectionId: other)) == ["id": .json])
    }

    @Test("A format 0.83 does not have goes in a second key, so the key 0.83 decodes whole still decodes")
    func newFormatsStayOutOfThe083Key() throws {
        let (storage, defaults) = try makeStorage()
        let target = scope("public", connectionId: UUID())
        let avro = ValueDisplayFormat.avro(schemaID: String(repeating: "a", count: 32))
        storage.save(["a": .json, "b": .igbinary, "c": avro], for: target)

        let data = try #require(defaults.data(forKey: PreferenceKeys.columnDisplayFormats(target).name))
        #expect(try JSONDecoder().decode([String: FormatsIn083].self, from: data) == ["a": .json])
        #expect(storage.load(for: target) == ["a": .json, "b": .igbinary, "c": avro])
    }

    @Test("A format 0.83 sets later wins over the one it could not read")
    func formatSetBy083Wins() throws {
        let (storage, defaults) = try makeStorage()
        let target = scope("public", connectionId: UUID())
        storage.save(["b": .igbinary], for: target)

        defaults.set(try JSONEncoder().encode(["b": FormatsIn083.json]), forKey: PreferenceKeys.columnDisplayFormats(target).name)

        #expect(storage.load(for: target) == ["b": .json])
    }

    @Test("A format name this build does not know is kept through other columns' changes")
    func unknownFormatsAreKept() throws {
        let (storage, defaults) = try makeStorage()
        let service = ValueDisplayFormatService(storage: storage)
        let target = scope("public", connectionId: UUID())
        let addedKey = PreferenceKeys.columnDisplayFormats(target).name + ".added"
        defaults.set(try JSONEncoder().encode(["x": "formatFromALaterBuild"]), forKey: addedKey)

        service.setOverride(.igbinary, columnKey: "a", scope: target)
        service.setOverride(nil, columnKey: "a", scope: target)

        #expect(storage.load(for: target) == [:])
        let kept = try #require(defaults.data(forKey: addedKey))
        #expect(try JSONDecoder().decode([String: String].self, from: kept) == ["x": "formatFromALaterBuild"])
    }

    @Test("A table rename moves the formats in both keys")
    func renameTableMovesBothKeys() throws {
        let (storage, _) = try makeStorage()
        let conn = UUID()
        storage.save(["id": .uuid, "payload": .igbinary], for: scope("public", connectionId: conn))

        storage.renameTable(
            from: scope("public", connectionId: conn),
            to: scope("public", connectionId: conn, table: "purchases")
        )

        #expect(storage.load(for: scope("public", connectionId: conn)) == nil)
        #expect(storage.load(for: scope("public", connectionId: conn, table: "purchases")) == ["id": .uuid, "payload": .igbinary])
    }

    @Test("A schema file goes once no saved format names it")
    func schemaFilesFollowTheFormatsThatNameThem() throws {
        let defaults = try pool.make().defaults
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let earlier = AvroSchemaStore(directory: directory)
        let kept = try earlier.add(#"{"type":"array","items":"int"}"#)
        let orphan = try earlier.add(#"{"type":"array","items":"long"}"#)
        let schemas = AvroSchemaStore(directory: directory)
        let storage = ValueDisplayFormatStorage(defaults: defaults, schemas: schemas)
        let target = scope("public", connectionId: UUID())

        storage.save(["payload": .avro(schemaID: kept)], for: target)
        #expect(schemas.storedIDs == [kept])

        storage.dropTable(target)
        #expect(schemas.storedIDs.isEmpty)
        #expect(orphan != kept)
    }

    @Test("A Protobuf schema file goes once no saved format names it, beside the Avro ones")
    func protobufSchemaFilesFollowTheFormatsThatNameThem() throws {
        let defaults = try pool.make().defaults
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let protobuf = ProtobufSchemaStore(directory: directory.appendingPathComponent("proto", isDirectory: true))
        let kept = try protobuf.add(Data("message A { int32 id = 1; }".utf8))
        let storage = ValueDisplayFormatStorage(
            defaults: defaults,
            schemas: AvroSchemaStore(directory: directory.appendingPathComponent("avro", isDirectory: true)),
            protobufSchemas: ProtobufSchemaStore(directory: directory.appendingPathComponent("proto", isDirectory: true))
        )
        let target = scope("public", connectionId: UUID())

        storage.save(["payload": .protobufSchema(schemaID: kept, message: "A")], for: target)
        #expect(storage.load(for: target) == ["payload": .protobufSchema(schemaID: kept, message: "A")])
        #expect(protobuf.storedIDs == [kept])

        storage.dropTable(target)
        #expect(protobuf.storedIDs.isEmpty)
    }
}

// What 0.83.1 decodes a table's formats as: a String enum of the names it shipped.
private enum FormatsIn083: String, Codable {
    case raw, text, uuid, uuidSwappedTime, unixTimestamp, unixTimestampMillis, json, phpSerialized, messagePack, protobuf
}
