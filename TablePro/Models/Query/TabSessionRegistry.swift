//
//  TabSessionRegistry.swift
//  TablePro
//

import Foundation

@MainActor
final class TabSessionRegistry {
    private var sessions: [UUID: TabSession] = [:]

    func session(for id: UUID) -> TabSession? {
        sessions[id]
    }

    func register(_ session: TabSession) {
        sessions[session.id] = session
    }

    func unregister(id: UUID) {
        sessions.removeValue(forKey: id)
    }

    func removeAll() {
        sessions.removeAll()
    }

    var allSessions: [TabSession] {
        Array(sessions.values)
    }

    // MARK: - Row data access

    func tableRows(for tabId: UUID) -> TableRows {
        sessions[tabId]?.tableRows ?? TableRows()
    }

    func existingTableRows(for tabId: UUID) -> TableRows? {
        guard let session = sessions[tabId] else { return nil }
        guard !session.tableRows.rows.isEmpty || !session.tableRows.columns.isEmpty else { return nil }
        return session.tableRows
    }

    func setTableRows(_ rows: TableRows, for tabId: UUID) {
        let session = ensureSession(for: tabId)
        session.tableRows = rows
        session.isEvicted = false
    }

    func updateTableRows(for tabId: UUID, _ mutate: (inout TableRows) -> Void) {
        let session = ensureSession(for: tabId)
        var rows = session.tableRows
        mutate(&rows)
        session.tableRows = rows
        session.isEvicted = false
    }

    func removeTableRows(for tabId: UUID) {
        guard let session = sessions[tabId] else { return }
        session.tableRows = TableRows()
        session.isEvicted = false
    }

    func isEvicted(_ tabId: UUID) -> Bool {
        sessions[tabId]?.isEvicted ?? false
    }

    /// Evict row data for a tab. Sets `isEvicted = true` and bumps `loadEpoch`
    /// so SwiftUI's `.task(id:)` lazy-load re-fires.
    ///
    /// Returns early if the session has no rows to evict — calling `evict` on
    /// a tab with empty rows is a no-op (no `isEvicted` change, no epoch bump),
    /// matching the original `TableRowsStore.evict` semantics. Use
    /// `tabSessionRegistry.session(for:)?.isEvicted = true` directly if you
    /// need to mark a fresh-but-empty session as evicted.
    func evict(for tabId: UUID) {
        guard let session = sessions[tabId] else { return }
        guard !session.tableRows.rows.isEmpty else { return }
        session.tableRows.rows = []
        session.isEvicted = true
        session.loadEpoch &+= 1
    }

    func evictAll(except activeTabId: UUID?) {
        for session in sessions.values where session.id != activeTabId {
            guard !session.tableRows.rows.isEmpty, !session.isEvicted else { continue }
            session.tableRows.rows = []
            session.isEvicted = true
            session.loadEpoch &+= 1
        }
    }

    private func ensureSession(for tabId: UUID) -> TabSession {
        if let existing = sessions[tabId] {
            return existing
        }
        let session = TabSession(id: tabId)
        sessions[tabId] = session
        return session
    }
}
