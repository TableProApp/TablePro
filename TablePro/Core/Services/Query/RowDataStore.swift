import Foundation

@MainActor
@Observable
final class RowDataStore {
    @ObservationIgnored private var store: [UUID: RowBuffer] = [:]

    func buffer(for tabId: UUID) -> RowBuffer {
        if let existing = store[tabId] {
            return existing
        }
        let buffer = RowBuffer()
        store[tabId] = buffer
        return buffer
    }

    func existingBuffer(for tabId: UUID) -> RowBuffer? {
        store[tabId]
    }

    func setBuffer(_ buffer: RowBuffer, for tabId: UUID) {
        store[tabId] = buffer
    }

    func removeBuffer(for tabId: UUID) {
        store.removeValue(forKey: tabId)
    }

    func evict(for tabId: UUID) {
        store[tabId]?.evict()
    }

    func evictAll(except activeTabId: UUID?) {
        for (id, buffer) in store where id != activeTabId {
            if !buffer.rows.isEmpty && !buffer.isEvicted {
                buffer.evict()
            }
        }
    }

    func tearDown() {
        store.removeAll()
    }
}
