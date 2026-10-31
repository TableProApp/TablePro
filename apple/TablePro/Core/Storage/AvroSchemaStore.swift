//
//  AvroSchemaStore.swift
//  TablePro
//

import CryptoKit
import Foundation
import os

// The schema files chosen for Avro columns, one file each, named by a hash of the text, so a column still
// decodes after the original file moves and the same file chosen twice is kept once. Read from the grid on
// the main actor and from the viewer off it.
internal final class AvroSchemaStore: Sendable {
    static let shared = AvroSchemaStore(
        directory: AppStorageEnvironment.shared.supportDirectory.appendingPathComponent("AvroSchemas", isDirectory: true)
    )

    // Far past any real schema; a file this large is the wrong file.
    static let maxFileBytes = 4_000_000

    private static let fileExtension = "avsc"

    private struct State {
        var parsed: [String: AvroSchema] = [:]
        // Kept from a sweep: a schema can be added before the column's format is saved.
        var addedThisLaunch: Set<String> = []
    }

    private let directory: URL
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(directory: URL) {
        self.directory = directory
    }

    static func isSchemaID(_ text: String) -> Bool {
        text.utf8.count == 32 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    // Parses first, so nothing is kept for a file that is not a schema.
    func add(_ text: String) throws -> String {
        let schema = try AvroSchema.parse(text)
        let id = SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let url = fileURL(id)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        }
        state.withLock {
            $0.parsed[id] = schema
            $0.addedThisLaunch.insert(id)
        }
        return id
    }

    func schema(id: String) -> AvroSchema? {
        if let cached = state.withLock({ $0.parsed[id] }) { return cached }
        guard Self.isSchemaID(id),
              let data = try? Data(contentsOf: fileURL(id)),
              let text = String(data: data, encoding: .utf8),
              let schema = try? AvroSchema.parse(text) else { return nil }
        state.withLock { $0.parsed[id] = schema }
        return schema
    }

    var storedIDs: Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.compactMap { name in
            let url = URL(fileURLWithPath: name)
            guard url.pathExtension == Self.fileExtension else { return nil }
            let id = url.deletingPathExtension().lastPathComponent
            return Self.isSchemaID(id) ? id : nil
        })
    }

    func removeAll(except kept: Set<String>) {
        let addedThisLaunch = state.withLock { $0.addedThisLaunch }
        for id in storedIDs where !kept.contains(id) && !addedThisLaunch.contains(id) {
            try? FileManager.default.removeItem(at: fileURL(id))
            state.withLock { _ = $0.parsed.removeValue(forKey: id) }
        }
    }

    private func fileURL(_ id: String) -> URL {
        directory.appendingPathComponent(id, isDirectory: false).appendingPathExtension(Self.fileExtension)
    }
}
