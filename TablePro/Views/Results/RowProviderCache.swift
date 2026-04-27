import Foundation

@MainActor
final class RowProviderCache {
    private struct Entry {
        let provider: InMemoryRowProvider
        let resultVersion: Int
        let metadataVersion: Int
        let sortState: SortState
    }

    private var entries: [UUID: Entry] = [:]

    func provider(
        for tabId: UUID,
        resultVersion: Int,
        metadataVersion: Int,
        sortState: SortState
    ) -> InMemoryRowProvider? {
        guard let entry = entries[tabId],
              entry.resultVersion == resultVersion,
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
        resultVersion: Int,
        metadataVersion: Int,
        sortState: SortState
    ) {
        entries[tabId] = Entry(
            provider: provider,
            resultVersion: resultVersion,
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
