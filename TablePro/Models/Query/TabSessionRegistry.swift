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
        session.dataRevision &+= 1
    }

    func updateTableRows(for tabId: UUID, _ mutate: (inout TableRows) -> Void) {
        let session = ensureSession(for: tabId)
        var rows = session.tableRows
        mutate(&rows)
        session.tableRows = rows
        session.isEvicted = false
        session.dataRevision &+= 1
    }

    func removeTableRows(for tabId: UUID) {
        guard let session = sessions[tabId] else { return }
        session.tableRows = TableRows()
        session.isEvicted = false
        session.dataRevision &+= 1
    }

    func isEvicted(_ tabId: UUID) -> Bool {
        sessions[tabId]?.isEvicted ?? false
    }

    /// Drops a tab's rows and marks it evicted. Getting them back is the caller's job: SwiftUI's
    /// `.task(id:)` keys on `QueryTab.loadEpoch`, so a caller that wants the lazy load to re-fire
    /// bumps that itself.
    ///
    /// A tab with no rows is left alone, so eviction never marks a tab that has nothing to lose.
    func evict(for tabId: UUID) {
        guard let session = sessions[tabId] else { return }
        guard !session.tableRows.rows.isEmpty else { return }
        session.tableRows.rows = []
        session.isEvicted = true
        session.dataRevision &+= 1
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
