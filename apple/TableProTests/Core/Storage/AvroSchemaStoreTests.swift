//
//  AvroSchemaStoreTests.swift
//  TableProTests
//

import Foundation
import os
@testable import TablePro
import Testing

struct AvroSchemaStoreTests {
    private static let schema = #"{"type":"record","name":"Reading","namespace":"com.example","fields":[{"name":"id","type":"long"}]}"#

    private func withDirectory(_ body: (URL) throws -> Void) rethrows {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test("The same text kept twice is one file, read back by a later launch")
    func sameTextIsOneFile() throws {
        try withDirectory { directory in
            let store = AvroSchemaStore(directory: directory)
            let id = try store.add(Self.schema)
            #expect(try store.add(Self.schema) == id)
            #expect(AvroSchemaStore.isSchemaID(id))
            #expect(store.storedIDs == [id])
            #expect(AvroSchemaStore(directory: directory).schema(id: id)?.displayName == "Reading")
        }
    }

    @Test("A schema file that cannot be read is not read again on every cell, until it is added back")
    func unreadableFileIsRememberedUntilAdded() throws {
        try withDirectory { directory in
            let id = AvroSchemaStore.schemaID(of: Self.schema)
            let file = directory.appendingPathComponent(id).appendingPathExtension("avsc")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: file)
            let store = AvroSchemaStore(directory: directory)
            #expect(store.schema(id: id) == nil)

            try Data(Self.schema.utf8).write(to: file)
            #expect(store.schema(id: id) == nil)
            #expect(try store.add(Self.schema) == id)
            #expect(store.schema(id: id)?.displayName == "Reading")
        }
    }

    @Test("Text that is not a schema is refused and leaves nothing behind")
    func invalidTextIsRefused() throws {
        try withDirectory { directory in
            let store = AvroSchemaStore(directory: directory)
            #expect(throws: AvroSchemaError.self) { try store.add(#"{"type":"record","name":"R"}"#) }
            #expect(store.storedIDs.isEmpty)
        }
    }

    @Test("An ID that is not one of the store's never reaches the file system")
    func foreignIDsAreRefused() throws {
        try withDirectory { directory in
            let store = AvroSchemaStore(directory: directory)
            #expect(store.schema(id: "../../etc/hosts") == nil)
            #expect(ValueDisplayFormat(rawValue: "avro:../../etc/hosts") == nil)
            #expect(ValueDisplayFormat(rawValue: "avro:") == nil)
            let id = try store.add(Self.schema)
            #expect(ValueDisplayFormat(rawValue: "avro:" + id) == .avro(schemaID: id))
        }
    }

    @Test("Adding a schema that was looked up and missing announces it, and only then")
    func restoreIsAnnounced() throws {
        try withDirectory { directory in
            let store = AvroSchemaStore(directory: directory)
            let announced = OSAllocatedUnfairLock<[String]>(initialState: [])
            let observer = NotificationCenter.default.addObserver(
                forName: AvroSchemaStore.didRestoreSchema, object: store, queue: nil
            ) { notification in
                let schemaID = notification.userInfo?[AvroSchemaStore.schemaIDKey] as? String ?? ""
                announced.withLock { $0.append(schemaID) }
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            _ = try store.add(#""int""#)
            #expect(announced.withLock { $0 }.isEmpty)

            let lost = AvroSchemaStore.schemaID(of: Self.schema)
            #expect(store.schema(id: lost) == nil)
            #expect(try store.add(Self.schema) == lost)
            #expect(announced.withLock { $0 } == [lost])
            _ = try store.add(Self.schema)
            #expect(announced.withLock { $0 } == [lost])
        }
    }

    @Test("A sweep keeps what is named and what this launch added")
    func sweepKeepsNamedAndNew() throws {
        try withDirectory { directory in
            let earlier = AvroSchemaStore(directory: directory)
            let named = try earlier.add(Self.schema)
            let orphan = try earlier.add(#""long""#)
            let store = AvroSchemaStore(directory: directory)
            let fresh = try store.add(#""string""#)

            store.removeAll(except: [named])

            #expect(store.storedIDs == [named, fresh])
            #expect(store.schema(id: orphan) == nil)
        }
    }
}
