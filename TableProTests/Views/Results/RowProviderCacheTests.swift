//
//  RowProviderCacheTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("RowProviderCache")
@MainActor
struct RowProviderCacheTests {

    private func makeProvider(rows: [[String?]] = [["a"]]) -> InMemoryRowProvider {
        InMemoryRowProvider(rows: rows, columns: ["c"])
    }

    private func makeSortState(columnIndex: Int = 0, direction: SortDirection = .ascending) -> SortState {
        var state = SortState()
        state.columns = [SortColumn(columnIndex: columnIndex, direction: direction)]
        return state
    }

    @Test("provider(for:) returns nil when the tab id is unknown")
    func providerUnknownReturnsNil() {
        let cache = RowProviderCache()
        let resolved = cache.provider(
            for: UUID(),
            schemaVersion: 1,
            metadataVersion: 1,
            sortState: SortState()
        )
        #expect(resolved == nil)
    }

    @Test("After store(...), the same key returns the stored provider")
    func storeRoundTrips() {
        let cache = RowProviderCache()
        let tabId = UUID()
        let provider = makeProvider()

        cache.store(provider, for: tabId, schemaVersion: 2, metadataVersion: 3, sortState: SortState())

        let resolved = cache.provider(for: tabId, schemaVersion: 2, metadataVersion: 3, sortState: SortState())
        #expect(resolved != nil)
        #expect(resolved.map(ObjectIdentifier.init) == ObjectIdentifier(provider))
    }

    @Test("Different schemaVersion invalidates the cache hit")
    func schemaVersionMismatchReturnsNil() {
        let cache = RowProviderCache()
        let tabId = UUID()
        cache.store(makeProvider(), for: tabId, schemaVersion: 1, metadataVersion: 1, sortState: SortState())

        let resolved = cache.provider(for: tabId, schemaVersion: 2, metadataVersion: 1, sortState: SortState())
        #expect(resolved == nil)
    }

    @Test("Different metadataVersion invalidates the cache hit")
    func metadataVersionMismatchReturnsNil() {
        let cache = RowProviderCache()
        let tabId = UUID()
        cache.store(makeProvider(), for: tabId, schemaVersion: 1, metadataVersion: 1, sortState: SortState())

        let resolved = cache.provider(for: tabId, schemaVersion: 1, metadataVersion: 99, sortState: SortState())
        #expect(resolved == nil)
    }

    @Test("Different sortState invalidates the cache hit")
    func sortStateMismatchReturnsNil() {
        let cache = RowProviderCache()
        let tabId = UUID()
        let storedSort = makeSortState(columnIndex: 0, direction: .ascending)
        cache.store(makeProvider(), for: tabId, schemaVersion: 1, metadataVersion: 1, sortState: storedSort)

        let differentSort = makeSortState(columnIndex: 1, direction: .descending)
        let resolved = cache.provider(for: tabId, schemaVersion: 1, metadataVersion: 1, sortState: differentSort)
        #expect(resolved == nil)
    }

    @Test("remove(for:) removes the entry")
    func removeRemoves() {
        let cache = RowProviderCache()
        let tabId = UUID()
        cache.store(makeProvider(), for: tabId, schemaVersion: 1, metadataVersion: 1, sortState: SortState())

        cache.remove(for: tabId)

        let resolved = cache.provider(for: tabId, schemaVersion: 1, metadataVersion: 1, sortState: SortState())
        #expect(resolved == nil)
        #expect(cache.isEmpty)
    }

    @Test("retain(tabIds:) keeps only the listed tabs")
    func retainKeepsListedOnly() {
        let cache = RowProviderCache()
        let keepId = UUID()
        let dropId1 = UUID()
        let dropId2 = UUID()

        cache.store(makeProvider(), for: keepId, schemaVersion: 1, metadataVersion: 1, sortState: SortState())
        cache.store(makeProvider(), for: dropId1, schemaVersion: 1, metadataVersion: 1, sortState: SortState())
        cache.store(makeProvider(), for: dropId2, schemaVersion: 1, metadataVersion: 1, sortState: SortState())

        cache.retain(tabIds: [keepId])

        #expect(cache.provider(for: keepId, schemaVersion: 1, metadataVersion: 1, sortState: SortState()) != nil)
        #expect(cache.provider(for: dropId1, schemaVersion: 1, metadataVersion: 1, sortState: SortState()) == nil)
        #expect(cache.provider(for: dropId2, schemaVersion: 1, metadataVersion: 1, sortState: SortState()) == nil)
    }

    @Test("removeAll() clears the cache")
    func removeAllClears() {
        let cache = RowProviderCache()
        cache.store(makeProvider(), for: UUID(), schemaVersion: 1, metadataVersion: 1, sortState: SortState())
        cache.store(makeProvider(), for: UUID(), schemaVersion: 1, metadataVersion: 1, sortState: SortState())

        cache.removeAll()

        #expect(cache.isEmpty)
    }

    @Test("isEmpty reflects state across mutations")
    func isEmptyReflectsState() {
        let cache = RowProviderCache()
        #expect(cache.isEmpty)

        let tabId = UUID()
        cache.store(makeProvider(), for: tabId, schemaVersion: 1, metadataVersion: 1, sortState: SortState())
        #expect(!cache.isEmpty)

        cache.remove(for: tabId)
        #expect(cache.isEmpty)
    }
}
