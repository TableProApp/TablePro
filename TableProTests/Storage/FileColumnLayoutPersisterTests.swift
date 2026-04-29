//
//  FileColumnLayoutPersisterTests.swift
//  TableProTests
//

import Foundation
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

    @Test("Save then load returns the same widths and order")
    func roundTrip() {
        let (persister, dir) = makeIsolatedPersister()
        defer { cleanup(dir) }

        let connectionId = UUID()
        var layout = ColumnLayoutState()
        layout.columnWidths = ["id": 60, "name": 200, "email": 240]
        layout.columnOrder = ["id", "name", "email"]
        persister.save(layout, for: "users", connectionId: connectionId)

        let loaded = persister.load(for: "users", connectionId: connectionId)
        #expect(loaded?.columnWidths == layout.columnWidths)
        #expect(loaded?.columnOrder == layout.columnOrder)
    }

    @Test("Loading an unknown table returns nil")
    func loadMissing() {
        let (persister, dir) = makeIsolatedPersister()
        defer { cleanup(dir) }

        #expect(persister.load(for: "missing", connectionId: UUID()) == nil)
    }

    @Test("Save with empty widths is a no-op")
    func saveEmptyIsNoOp() {
        let (persister, dir) = makeIsolatedPersister()
        defer { cleanup(dir) }

        let connectionId = UUID()
        persister.save(ColumnLayoutState(), for: "users", connectionId: connectionId)
        #expect(persister.load(for: "users", connectionId: connectionId) == nil)
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

        persister.save(users, for: "users", connectionId: connectionId)
        persister.save(orders, for: "orders", connectionId: connectionId)

        #expect(persister.load(for: "users", connectionId: connectionId)?.columnWidths == ["id": 60])
        #expect(persister.load(for: "orders", connectionId: connectionId)?.columnWidths == ["total": 120])
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

        persister.save(a, for: "a", connectionId: connectionId)
        persister.save(b, for: "b", connectionId: connectionId)
        persister.clear(for: "a", connectionId: connectionId)

        #expect(persister.load(for: "a", connectionId: connectionId) == nil)
        #expect(persister.load(for: "b", connectionId: connectionId)?.columnWidths == ["y": 200])
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
            persister.save(layout, for: "users", connectionId: connectionId)
        }

        let restored = FileColumnLayoutPersister(storageDirectory: directory)
            .load(for: "users", connectionId: connectionId)
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
        #expect(persister.load(for: "users", connectionId: connectionId) == nil)
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
        persister.save(layout, for: "users", connectionId: connectionId)

        let restored = FileColumnLayoutPersister(storageDirectory: directory)
            .load(for: "users", connectionId: connectionId)
        #expect(restored?.columnWidths == ["id": 100])
    }
}
