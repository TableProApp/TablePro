//
//  TabQueryOverflowStore.swift
//  TablePro
//
//  Keeps a query too large to sit inside the tab-state JSON in a sidecar file
//  beside it, so restoring a tab returns the text instead of an empty editor.
//  Mirrors the sidecar `RecentlyClosedTabStore` already uses for the same limit.
//

import Foundation
import os

internal enum TabQueryOverflowStore {
    private static let logger = Logger(subsystem: "com.TablePro", category: "TabDiskActor")

    static func directory(inside tabStateDirectory: URL) -> URL {
        tabStateDirectory.appendingPathComponent("Overflow", isDirectory: true)
    }

    private static func fileName(connectionId: UUID, tabId: UUID) -> String {
        "\(connectionId.uuidString)_\(tabId.uuidString).sql"
    }

    /// Moves any oversized query out to a sidecar and blanks the inline field.
    /// Sidecars this connection no longer references are removed in the same pass,
    /// so a closed tab does not leave its text behind forever.
    static func externalize(
        _ tabs: [PersistedTab],
        connectionId: UUID,
        tabStateDirectory: URL
    ) -> [PersistedTab] {
        let overflowDirectory = directory(inside: tabStateDirectory)
        var written: Set<String> = []

        let processed = tabs.map { tab -> PersistedTab in
            guard (tab.query as NSString).length > TabQueryContent.maxPersistableQuerySize else { return tab }
            let name = fileName(connectionId: connectionId, tabId: tab.id)
            guard write(tab.query, named: name, in: overflowDirectory) else { return tab }
            written.insert(name)
            var copy = tab
            copy.query = ""
            copy.overflowFileName = name
            return copy
        }

        pruneOrphans(connectionId: connectionId, keeping: written, in: overflowDirectory)
        return processed
    }

    /// Reads sidecar text back into the tabs it belongs to.
    static func inline(_ tabs: [PersistedTab], tabStateDirectory: URL) -> [PersistedTab] {
        let overflowDirectory = directory(inside: tabStateDirectory)
        return tabs.map { tab -> PersistedTab in
            guard let name = tab.overflowFileName else { return tab }
            let url = overflowDirectory.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                logger.error("Missing overflow sidecar \(name, privacy: .public)")
                return tab
            }
            var copy = tab
            copy.query = text
            return copy
        }
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
