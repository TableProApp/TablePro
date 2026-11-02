//
//  SchemaFileCache.swift
//  TablePro
//

import CryptoKit
import Foundation
import os

// Named by a hash of the contents, so a column still decodes after the original file moves.
internal final class SchemaFileCache<Schema: Sendable>: Sendable {
    private struct State {
        var parsed: [String: Schema] = [:]
        // Kept from a sweep: a schema can be added before the column's format is saved.
        var addedThisLaunch: Set<String> = []
        // Also answers later reads without the disk, since the grid asks once per cell.
        var missing: Set<String> = []
    }

    private let directory: URL
    private let fileExtension: String
    private let parse: @Sendable (Data) throws -> Schema
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(directory: URL, fileExtension: String, parse: @escaping @Sendable (Data) throws -> Schema) {
        self.directory = directory
        self.fileExtension = fileExtension
        self.parse = parse
    }

    static func isSchemaID(_ text: String) -> Bool {
        text.utf8.count == 32 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    static func schemaID(of contents: Data) -> String {
        SHA256.hash(data: contents).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func add(_ contents: Data) throws -> (id: String, wasMissing: Bool) {
        let schema = try parse(contents)
        let id = Self.schemaID(of: contents)
        let url = fileURL(id)
        // A copy that went bad on disk is written over, or the next launch would find it missing again.
        if (try? Data(contentsOf: url)) != contents {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try contents.write(to: url, options: .atomic)
        }
        let wasMissing = state.withLock { state -> Bool in
            state.parsed[id] = schema
            state.addedThisLaunch.insert(id)
            return state.missing.remove(id) != nil
        }
        return (id, wasMissing)
    }

    func schema(id: String) -> Schema? {
        let known = state.withLock { state -> (schema: Schema?, isMissing: Bool) in
            (state.parsed[id], state.missing.contains(id))
        }
        if let cached = known.schema { return cached }
        if known.isMissing { return nil }
        guard Self.isSchemaID(id),
              let data = try? Data(contentsOf: fileURL(id)),
              let schema = try? parse(data) else {
            // An add() may have landed since the read failed; recorded as missing only if it did not.
            return state.withLock { state in
                if let added = state.parsed[id] { return added }
                state.missing.insert(id)
                return nil
            }
        }
        state.withLock { $0.parsed[id] = schema }
        return schema
    }

    var storedIDs: Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.compactMap { name in
            let url = URL(fileURLWithPath: name)
            guard url.pathExtension == fileExtension else { return nil }
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
        directory.appendingPathComponent(id, isDirectory: false).appendingPathExtension(fileExtension)
    }
}
