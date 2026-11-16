//
//  JSONStoreTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

private struct Sample: Codable, Equatable {
    var name: String
    var count: Int
    var savedAt: Date
}

private let sample = Sample(name: "orders", count: 3, savedAt: Date(timeIntervalSince1970: 1_700_000_000))

struct JSONDefaultsKeyTests {
    @Test
    func missingKeyReadsAsMissing() throws {
        let scratch = try EphemeralDefaults()
        let read = scratch.defaults.read(JSONDefaultsKey<Sample>("com.TablePro.test.sample"))
        guard case .missing = read else {
            Issue.record("expected missing, got \(read)")
            return
        }
    }

    @Test
    func writtenValueReadsBackWithTheBytesAPlainEncoderWrites() throws {
        let scratch = try EphemeralDefaults()
        let key = JSONDefaultsKey<Sample>("com.TablePro.test.sample")

        try scratch.defaults.write(sample, to: key)

        #expect(scratch.defaults.read(key).value == sample)
        let stored = try #require(scratch.defaults.data(forKey: key.name))
        let storedObject = try JSONSerialization.jsonObject(with: stored) as? NSDictionary
        let plainObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? NSDictionary
        #expect(storedObject == plainObject)
    }

    @Test
    func undecodableValueReadsAsUnreadableAndStaysStored() throws {
        let scratch = try EphemeralDefaults()
        let key = JSONDefaultsKey<Sample>("com.TablePro.test.sample")
        let damaged = Data("not json".utf8)
        scratch.defaults.set(damaged, forKey: key.name)

        #expect(scratch.defaults.read(key).isUnreadable)
        #expect(scratch.defaults.data(forKey: key.name) == damaged)
    }

    @Test
    func removeClearsTheKey() throws {
        let scratch = try EphemeralDefaults()
        let key = JSONDefaultsKey<Sample>("com.TablePro.test.sample")
        try scratch.defaults.write(sample, to: key)

        scratch.defaults.removeValue(for: key)

        #expect(scratch.defaults.object(forKey: key.name) == nil)
    }

    @Test
    func sortedKeysCodingWritesKeysInOrder() throws {
        let scratch = try EphemeralDefaults()
        let key = JSONDefaultsKey<[String: Int]>("com.TablePro.test.sorted", coding: .sortedKeys)

        try scratch.defaults.write(["b": 2, "a": 1, "c": 3], to: key)

        let stored = try #require(scratch.defaults.data(forKey: key.name))
        #expect(String(decoding: stored, as: UTF8.self) == #"{"a":1,"b":2,"c":3}"#)
    }
}

struct JSONFileStoreTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test
    func missingFileReadsAsMissing() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONFileStore<Sample>(url: directory.appendingPathComponent("absent.json"))

        guard case .missing = store.read() else {
            Issue.record("expected missing")
            return
        }
        #expect(!store.exists)
    }

    @Test
    func writeCreatesTheFolderAndReadsBack() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/sample.json")
        let store = JSONFileStore<Sample>(url: url, coding: .prettyISO8601)

        try store.write(sample)

        #expect(store.read().value == sample)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        #expect(try Data(contentsOf: url) == (try encoder.encode(sample)))
    }

    @Test
    func undecodableFileReadsAsUnreadableAndIsKept() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("damaged.json")
        let damaged = Data("{\"name\":".utf8)
        try damaged.write(to: url)
        let store = JSONFileStore<Sample>(url: url)

        #expect(store.read().isUnreadable)
        #expect(try Data(contentsOf: url) == damaged)
    }

    @Test
    func removingAMissingFileSucceeds() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONFileStore<Sample>(url: directory.appendingPathComponent("absent.json"))

        try store.remove()

        #expect(!store.exists)
    }
}

struct StoreLogTests {
    @Test
    func publicPartStopsAtTheConnectionId() {
        let scope = TableScope(connectionId: UUID(), database: "shop", schema: "public", table: "orders")
        let name = PreferenceKeys.columnDisplayFormats(scope).name

        #expect(StoreLog.publicPart(of: name) == "com.TablePro.columns.displayFormat.*")
    }

    @Test
    func publicPartKeepsANameWithNoConnectionId() {
        #expect(StoreLog.publicPart(of: "com.TablePro.favoriteDatabases") == "com.TablePro.favoriteDatabases")
        #expect(StoreLog.publicPart(of: "AgentSessions.json") == "AgentSessions.json")
    }
}
