//
//  FileColumnLayoutPersisterTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("FileColumnLayoutPersister")
@MainActor
struct FileColumnLayoutPersisterTests {
    private func makeIsolatedPersister() -> (FileColumnLayoutPersister, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableProTests-\(UUID().uuidString)", isDirectory: true)
        let persister = FileColumnLayoutPersister(storageDirectory: directory)
        return (persister, directory)
    }

    private func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    private func key(
        _ table: String,
        _ connectionId: UUID,
        database: String = "app",
        schema: String? = "public"
    ) -> ColumnLayoutTableKey {
        ColumnLayoutTableKey(
            connectionId: connectionId,
            databaseName: database,
            schemaName: schema,
            tableName: table
        )
    }

    @Test("Save then load returns the same widths and order")
    func roundTrip() {
        let (persister, dir) = makeIsolatedPersister()
        defer { cleanup(dir) }

        let connectionId = UUID()
        var layout = ColumnLayoutState()
        layout.columnWidths = ["id": 60, "name": 200, "email": 240]
        layout.columnOrder = ["id", "name", "email"]
        persister.save(layout, for: key("users", connectionId))

        let loaded = persister.load(for: key("users", connectionId))
        #expect(loaded?.columnWidths == layout.columnWidths)
        #expect(loaded?.columnOrder == layout.columnOrder)
    }

    @Test("Loading an unknown table returns nil")
    func loadMissing() {
        let (persister, dir) = makeIsolatedPersister()
        defer { cleanup(dir) }

        #expect(persister.load(for: key("missing", UUID())) == nil)
    }

    @Test("Save with empty widths is a no-op")
    func saveEmptyIsNoOp() {
        let (persister, dir) = makeIsolatedPersister()
        defer { cleanup(dir) }

        let connectionId = UUID()
        persister.save(ColumnLayoutState(), for: key("users", connectionId))
        #expect(persister.load(for: key("users", connectionId)) == nil)
    }

    @Test("Multiple tables on the same connection coexist")
    func multipleTables() {
        let (persister, dir) = makeIsolatedPersister()
        defer { cleanup(dir) }

        let connectionId = UUID()
        var users = ColumnLayoutState()
        users.columnWidths = ["id": 60]
        var orders = ColumnLayoutState()
        orders.columnWidths = ["total": 120]

        persister.save(users, for: key("users", connectionId))
        persister.save(orders, for: key("orders", connectionId))

        #expect(persister.load(for: key("users", connectionId))?.columnWidths == ["id": 60])
        #expect(persister.load(for: key("orders", connectionId))?.columnWidths == ["total": 120])
    }

    @Test("Clear removes only the targeted table")
    func clearTargeted() {
        let (persister, dir) = makeIsolatedPersister()
        defer { cleanup(dir) }

        let connectionId = UUID()
        var a = ColumnLayoutState()
        a.columnWidths = ["x": 100]
        var b = ColumnLayoutState()
        b.columnWidths = ["y": 200]

        persister.save(a, for: key("a", connectionId))
        persister.save(b, for: key("b", connectionId))
        persister.clear(for: key("a", connectionId))

        #expect(persister.load(for: key("a", connectionId)) == nil)
        #expect(persister.load(for: key("b", connectionId))?.columnWidths == ["y": 200])
    }

    @Test("Save survives a fresh persister instance pointed at the same directory")
    func persistenceAcrossInstances() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableProTests-\(UUID().uuidString)", isDirectory: true)
        defer { cleanup(directory) }

        let connectionId = UUID()
        var layout = ColumnLayoutState()
        layout.columnWidths = ["id": 80, "name": 220]
        layout.columnOrder = ["name", "id"]

        do {
            let persister = FileColumnLayoutPersister(storageDirectory: directory)
            persister.save(layout, for: key("users", connectionId))
        }

        let restored = FileColumnLayoutPersister(storageDirectory: directory)
            .load(for: key("users", connectionId))
        #expect(restored?.columnWidths == layout.columnWidths)
        #expect(restored?.columnOrder == layout.columnOrder)
    }

    @Test("Loading malformed JSON returns nil instead of crashing")
    func malformedJSONRecovers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableProTests-\(UUID().uuidString)", isDirectory: true)
        defer { cleanup(directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let connectionId = UUID()
        let fileURL = directory.appendingPathComponent("\(connectionId.uuidString).json")
        try Data("{not valid json".utf8).write(to: fileURL)

        let persister = FileColumnLayoutPersister(storageDirectory: directory)
        #expect(persister.load(for: key("users", connectionId)) == nil)
    }

    @Test("Saving over a corrupted file replaces it cleanly")
    func malformedJSONIsRecoverableBySave() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableProTests-\(UUID().uuidString)", isDirectory: true)
        defer { cleanup(directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let connectionId = UUID()
        let fileURL = directory.appendingPathComponent("\(connectionId.uuidString).json")
        try Data("garbage".utf8).write(to: fileURL)

        let persister = FileColumnLayoutPersister(storageDirectory: directory)
        var layout = ColumnLayoutState()
        layout.columnWidths = ["id": 100]
        persister.save(layout, for: key("users", connectionId))

        let restored = FileColumnLayoutPersister(storageDirectory: directory)
            .load(for: key("users", connectionId))
        #expect(restored?.columnWidths == ["id": 100])
    }

    @Test("Clearing the only entry removes the connection's storage file")
    func clearingLastEntryRemovesFile() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableProTests-\(UUID().uuidString)", isDirectory: true)
        defer { cleanup(directory) }

        let persister = FileColumnLayoutPersister(storageDirectory: directory)
        let connectionId = UUID()
        var layout = ColumnLayoutState()
        layout.columnWidths = ["id": 100]
        persister.save(layout, for: key("users", connectionId))

        let fileURL = directory.appendingPathComponent("\(connectionId.uuidString).json")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        persister.clear(for: key("users", connectionId))
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("Clearing one of multiple tables keeps the connection file with the rest")
    func clearingOneOfManyKeepsFile() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableProTests-\(UUID().uuidString)", isDirectory: true)
        defer { cleanup(directory) }

        let persister = FileColumnLayoutPersister(storageDirectory: directory)
        let connectionId = UUID()
        var users = ColumnLayoutState()
        users.columnWidths = ["id": 60]
        var orders = ColumnLayoutState()
        orders.columnWidths = ["total": 120]
        persister.save(users, for: key("users", connectionId))
        persister.save(orders, for: key("orders", connectionId))

        persister.clear(for: key("users", connectionId))

        let fresh = FileColumnLayoutPersister(storageDirectory: directory)
        #expect(fresh.load(for: key("users", connectionId)) == nil)
        #expect(fresh.load(for: key("orders", connectionId))?.columnWidths == ["total": 120])
    }

    @Test("Clearing a missing entry is a no-op and never creates a file")
    func clearingMissingEntryIsNoOp() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableProTests-\(UUID().uuidString)", isDirectory: true)
        defer { cleanup(directory) }

        let persister = FileColumnLayoutPersister(storageDirectory: directory)
        let connectionId = UUID()
        persister.clear(for: key("missing", connectionId))

        let fileURL = directory.appendingPathComponent("\(connectionId.uuidString).json")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("Connections are isolated even when table names match")
    func sameTableNameAcrossConnectionsAreIsolated() {
        let (persister, dir) = makeIsolatedPersister()
        defer { cleanup(dir) }

        let connectionA = UUID()
        let connectionB = UUID()
        var layoutA = ColumnLayoutState()
        layoutA.columnWidths = ["id": 60]
        var layoutB = ColumnLayoutState()
        layoutB.columnWidths = ["id": 200]

        persister.save(layoutA, for: key("users", connectionA))
        persister.save(layoutB, for: key("users", connectionB))

        #expect(persister.load(for: key("users", connectionA))?.columnWidths == ["id": 60])
        #expect(persister.load(for: key("users", connectionB))?.columnWidths == ["id": 200])
    }

    @Test("Same table name in different databases and schemas do not collide")
    func sameTableNameAcrossDatabasesAndSchemasAreIsolated() {
        let (persister, dir) = makeIsolatedPersister()
        defer { cleanup(dir) }

        let connectionId = UUID()
        var sales = ColumnLayoutState()
        sales.columnWidths = ["id": 60]
        var hr = ColumnLayoutState()
        hr.columnWidths = ["id": 200]
        var authSchema = ColumnLayoutState()
        authSchema.columnWidths = ["id": 320]

        persister.save(sales, for: key("users", connectionId, database: "sales", schema: "public"))
        persister.save(hr, for: key("users", connectionId, database: "hr", schema: "public"))
        persister.save(authSchema, for: key("users", connectionId, database: "sales", schema: "auth"))

        #expect(persister.load(for: key("users", connectionId, database: "sales", schema: "public"))?.columnWidths == ["id": 60])
        #expect(persister.load(for: key("users", connectionId, database: "hr", schema: "public"))?.columnWidths == ["id": 200])
        #expect(persister.load(for: key("users", connectionId, database: "sales", schema: "auth"))?.columnWidths == ["id": 320])
    }

    @Test("Saving overwrites an existing entry instead of merging")
    func saveOverwritesExistingEntry() {
        let (persister, dir) = makeIsolatedPersister()
        defer { cleanup(dir) }

        let connectionId = UUID()
        var first = ColumnLayoutState()
        first.columnWidths = ["id": 60, "name": 200]
        first.columnOrder = ["id", "name"]
        persister.save(first, for: key("users", connectionId))

        var second = ColumnLayoutState()
        second.columnWidths = ["email": 240]
        second.columnOrder = ["email"]
        persister.save(second, for: key("users", connectionId))

        let restored = persister.load(for: key("users", connectionId))
        #expect(restored?.columnWidths == ["email": 240])
        #expect(restored?.columnOrder == ["email"])
    }

    @Test("columnOrder nil is preserved through round-trip")
    func columnOrderNilRoundTrips() {
        let (persister, dir) = makeIsolatedPersister()
        defer { cleanup(dir) }

        let connectionId = UUID()
        var layout = ColumnLayoutState()
        layout.columnWidths = ["id": 60]
        layout.columnOrder = nil
        persister.save(layout, for: key("users", connectionId))

        let restored = persister.load(for: key("users", connectionId))
        #expect(restored?.columnOrder == nil)
        #expect(restored?.columnWidths == ["id": 60])
    }

    @Test("Reading an empty JSON object returns nil for any table lookup")
    func emptyEntriesFileReturnsNil() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableProTests-\(UUID().uuidString)", isDirectory: true)
        defer { cleanup(directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let connectionId = UUID()
        let fileURL = directory.appendingPathComponent("\(connectionId.uuidString).json")
        try Data("{}".utf8).write(to: fileURL)

        let persister = FileColumnLayoutPersister(storageDirectory: directory)
        #expect(persister.load(for: key("anything", connectionId)) == nil)
    }
}
