//
//  TabQueryOverflowStore.swift
//  TablePro
//

import CryptoKit
import Foundation
import os

// A query too large for the tab-state JSON lives in a sidecar beside it, as in `RecentlyClosedTabStore`.
internal enum TabQueryOverflowStore {
    private static let logger = Logger(subsystem: "com.TablePro", category: "TabDiskActor")

    // The sidecars one connection has on disk from this process, so an unchanged query is not rewritten.
    internal struct WrittenSidecars {
        var digests: [String: SHA256.Digest] = [:]
        var keptByLastPrune: Set<String>?
    }

    static func directory(inside tabStateDirectory: URL) -> URL {
        tabStateDirectory.appendingPathComponent("Overflow", isDirectory: true)
    }

    private static func fileName(connectionId: UUID, tabId: UUID) -> String {
        "\(connectionId.uuidString)_\(tabId.uuidString).sql"
    }

    // Sidecars the connection no longer references are removed in the same pass, so a closed tab leaves no text behind.
    static func externalize(
        _ tabs: [PersistedTab],
        connectionId: UUID,
        tabStateDirectory: URL,
        written: inout WrittenSidecars
    ) -> [PersistedTab] {
        let overflowDirectory = directory(inside: tabStateDirectory)
        var kept: Set<String> = []

        let processed = tabs.map { tab -> PersistedTab in
            guard (tab.query as NSString).length > TabQueryContent.maxPersistableQuerySize else { return tab }
            let name = fileName(connectionId: connectionId, tabId: tab.id)
            let digest = digest(of: tab.query)
            let path = overflowDirectory.appendingPathComponent(name).path
            if written.digests[name] != digest || !FileManager.default.fileExists(atPath: path) {
                written.digests[name] = nil
                guard write(tab.query, named: name, in: overflowDirectory) else { return tab }
                written.digests[name] = digest
            }
            kept.insert(name)
            var copy = tab
            copy.query = ""
            copy.overflowFileName = name
            return copy
        }

        written.digests = written.digests.filter { kept.contains($0.key) }
        if written.keptByLastPrune != kept {
            pruneOrphans(connectionId: connectionId, keeping: kept, in: overflowDirectory)
            written.keptByLastPrune = kept
        }
        return processed
    }

    static func inline(
        _ tabs: [PersistedTab],
        tabStateDirectory: URL,
        written: inout WrittenSidecars
    ) -> [PersistedTab] {
        let overflowDirectory = directory(inside: tabStateDirectory)
        return tabs.map { tab -> PersistedTab in
            guard let name = tab.overflowFileName else { return tab }
            let url = overflowDirectory.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                logger.error("Missing overflow sidecar \(name, privacy: .public)")
                return tab
            }
            written.digests[name] = digest(of: text)
            var copy = tab
            copy.query = text
            return copy
        }
    }

    private static func digest(of query: String) -> SHA256.Digest {
        if let digest = query.utf8.withContiguousStorageIfAvailable({ SHA256.hash(data: UnsafeRawBufferPointer($0)) }) {
            return digest
        }
        return SHA256.hash(data: Data(query.utf8))
    }

    static func removeAll(connectionId: UUID, tabStateDirectory: URL) {
        pruneOrphans(connectionId: connectionId, keeping: [], in: directory(inside: tabStateDirectory))
    }

    private static func write(_ query: String, named name: String, in directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try query.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            return true
        } catch {
            logger.fault("Failed to write overflow sidecar \(name, privacy: .public): \(error.localizedDescription)")
            return false
        }
    }

    private static func pruneOrphans(connectionId: UUID, keeping kept: Set<String>, in directory: URL) {
        let prefix = "\(connectionId.uuidString)_"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(prefix) && !kept.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
