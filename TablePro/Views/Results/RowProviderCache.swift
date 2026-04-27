import Foundation

@MainActor
final class RowProviderCache {
    private struct Entry {
        let provider: InMemoryRowProvider
        let schemaVersion: Int
        let metadataVersion: Int
        let sortState: SortState
    }

    private var entries: [UUID: Entry] = [:]

    func provider(
        for tabId: UUID,
        schemaVersion: Int,
        metadataVersion: Int,
        sortState: SortState
    ) -> InMemoryRowProvider? {
        guard let entry = entries[tabId],
              entry.schemaVersion == schemaVersion,
              entry.metadataVersion == metadataVersion,
              entry.sortState == sortState
        else {
            return nil
        }
        return entry.provider
    }

    func store(
        _ provider: InMemoryRowProvider,
        for tabId: UUID,
        schemaVersion: Int,
        metadataVersion: Int,
        sortState: SortState
    ) {
        entries[tabId] = Entry(
            provider: provider,
            schemaVersion: schemaVersion,
            metadataVersion: metadataVersion,
            sortState: sortState
        )
    }

    func remove(for tabId: UUID) {
        entries.removeValue(forKey: tabId)
    }

    func retain(tabIds: Set<UUID>) {
        entries = entries.filter { tabIds.contains($0.key) }
    }

    func removeAll() {
        entries.removeAll()
    }

    var isEmpty: Bool {
        entries.isEmpty
    }
}
