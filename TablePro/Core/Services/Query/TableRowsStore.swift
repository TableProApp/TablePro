import Foundation

@MainActor
@Observable
final class TableRowsStore {
    @ObservationIgnored private var store: [UUID: TableRows] = [:]
    @ObservationIgnored private var evictedSet: Set<UUID> = []

    func tableRows(for tabId: UUID) -> TableRows {
        if let existing = store[tabId] {
            return existing
        }
        let rows = TableRows()
        store[tabId] = rows
        return rows
    }

    func existingTableRows(for tabId: UUID) -> TableRows? {
        store[tabId]
    }

    func setTableRows(_ rows: TableRows, for tabId: UUID) {
        store[tabId] = rows
        evictedSet.remove(tabId)
    }

    func updateTableRows(for tabId: UUID, _ mutate: (inout TableRows) -> Void) {
        var rows = store[tabId] ?? TableRows()
        mutate(&rows)
        store[tabId] = rows
        evictedSet.remove(tabId)
    }

    func removeTableRows(for tabId: UUID) {
        store.removeValue(forKey: tabId)
        evictedSet.remove(tabId)
    }

    func isEvicted(_ tabId: UUID) -> Bool {
        evictedSet.contains(tabId)
    }

    func evict(for tabId: UUID) {
        guard var rows = store[tabId] else { return }
        guard !rows.rows.isEmpty else { return }
        rows.rows = []
        store[tabId] = rows
        evictedSet.insert(tabId)
    }

    func evictAll(except activeTabId: UUID?) {
        for (id, rows) in store where id != activeTabId {
            guard !rows.rows.isEmpty, !evictedSet.contains(id) else { continue }
            var copy = rows
            copy.rows = []
            store[id] = copy
            evictedSet.insert(id)
        }
    }

    func tearDown() {
        store.removeAll()
        evictedSet.removeAll()
    }
}
