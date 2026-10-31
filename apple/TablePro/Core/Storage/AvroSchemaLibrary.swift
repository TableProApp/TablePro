//
//  AvroSchemaLibrary.swift
//  TablePro
//

import CryptoKit
import Foundation

// A column's Avro format names its schema by a hash of the file's text, so the same file chosen twice is
// stored once. Read from the grid on the main actor and from the viewer off it.
internal final class AvroSchemaLibrary: @unchecked Sendable {
    static let shared = AvroSchemaLibrary()

    static let keyPrefix = "com.TablePro.avroSchemas."

    private struct Entry: Codable {
        let name: String
        let text: String
    }

    private let store: KeyValueStore
    private let lock = NSLock()
    private var parsed: [String: AvroSchema] = [:]

    init(store: KeyValueStore = AppStorageEnvironment.shared.defaults) {
        self.store = store
    }

    func register(text: String, name: String) throws -> String {
        let schema = try AvroSchema.parse(text)
        let id = SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        guard let data = try? JSONEncoder().encode(Entry(name: name, text: text)) else {
            throw AvroSchemaError(reason: String(localized: "The schema could not be saved."))
        }
        lock.lock()
        defer { lock.unlock() }
        store.setDataValue(data, forKey: Self.keyPrefix + id)
        parsed[id] = schema
        return id
    }

    func schema(id: String) -> AvroSchema? {
        lock.lock()
        defer { lock.unlock() }
        if let schema = parsed[id] { return schema }
        guard let entry = entry(id: id), let schema = try? AvroSchema.parse(entry.text) else { return nil }
        parsed[id] = schema
        return schema
    }

    func name(id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entry(id: id)?.name
    }

    private func entry(id: String) -> Entry? {
        guard let data = store.dataValue(forKey: Self.keyPrefix + id) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }
}
