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
        session.bufferEpoch &+= 1
        session.rowSetRevision &+= 1
    }

    /// A mutation of what the tab already holds, so it cannot resurrect a tab that holds nothing.
    ///
    /// Phase-2 metadata (foreign keys, defaults, enum values) lands at background priority long
    /// after the load that asked for it, and it is keyed on the result rather than on the rows, so
    /// it arrives on tabs that were evicted while it was in flight. Clearing `isEvicted` for a
    /// mutation that leaves the buffer empty leaves a tab with no rows that `canAutoLoadTableTab`
    /// reads as already loaded, and eviction cannot re-mark it because it has nothing left to lose:
    /// the grid stays empty until an explicit refresh.
    @discardableResult
    func updateTableRows(for tabId: UUID, _ mutate: (inout TableRows) -> Delta) -> Delta {
        let session = ensureSession(for: tabId)
        var rows = session.tableRows
        let delta = mutate(&rows)
        session.tableRows = rows
        if !rows.rows.isEmpty {
            session.isEvicted = false
        }
        session.dataRevision &+= 1
        if delta.changesRowSet {
            session.rowSetRevision &+= 1
        }
        return delta
    }

    func removeTableRows(for tabId: UUID) {
        guard let session = sessions[tabId] else { return }
        session.tableRows = TableRows()
        session.isEvicted = false
        session.dataRevision &+= 1
        session.bufferEpoch &+= 1
        session.rowSetRevision &+= 1
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
        session.tableRows.discardRowsKeepingMetadata()
        session.isEvicted = true
        session.dataRevision &+= 1
        session.bufferEpoch &+= 1
        session.rowSetRevision &+= 1
    }

    func isStale(_ tabId: UUID) -> Bool {
        sessions[tabId]?.freshness.isStale ?? false
    }

    /// Whether the next load has to fetch the table's definition rather than reuse the metadata the
    /// tab holds.
    func needsDefinition(_ tabId: UUID) -> Bool {
        sessions[tabId]?.freshness.needsDefinition ?? false
    }

    /// Records that the tab's table changed. Nothing is discarded, and a tab holding no rows is
    /// marked all the same: an empty collection that gains its first document is exactly the tab
    /// eviction refuses.
    func recordChange(_ change: TableFreshness.Change, for tabId: UUID) {
        ensureSession(for: tabId).freshness.record(change)
    }

    func pendingChange(for tabId: UUID) -> TableFreshness.Change? {
        sessions[tabId]?.freshness.pendingChange
    }

    func definitionIsCurrent(asOf startedAt: ContinuousClock.Instant, for tabId: UUID) -> Bool {
        sessions[tabId]?.freshness.definitionIsCurrent(asOf: startedAt) ?? true
    }

    /// Called only where a fetched result is committed. `setTableRows` also installs rows the tab
    /// already held, a result set switch or a re-sort, and those answer nothing about the change.
    /// Answers whether the read covered a change to the table's rows.
    @discardableResult
    func recordRead(_ read: TableFreshness.Read, for tabId: UUID) -> Bool {
        sessions[tabId]?.freshness.record(read) ?? false
    }

    func stageViewportPlacement(_ placement: GridViewportPlacement, for tabId: UUID) {
        guard let session = sessions[tabId] else { return }
        session.viewportStage = GridViewportStage(bufferEpoch: session.bufferEpoch, placement: placement)
    }

    func takeViewportPlacement(for tabId: UUID) -> GridViewportPlacement? {
        guard let session = sessions[tabId], let stage = session.viewportStage else { return nil }
        session.viewportStage = nil
        guard stage.bufferEpoch == session.bufferEpoch else { return nil }
        return stage.placement
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
