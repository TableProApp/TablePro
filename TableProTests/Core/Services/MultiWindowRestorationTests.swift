//
//  MultiWindowRestorationTests.swift
//  TableProTests
//
//  Tests for the restoration group registry and last-open-connections recovery list.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Multi-window restoration")
@MainActor
struct MultiWindowRestorationTests {
    private func tab(_ title: String) -> QueryTab {
        QueryTab(id: UUID(), title: title, query: "SELECT 1", tabType: .query)
    }

    @Test("Registry hands back the registered group exactly once")
    func registryConsumeReturnsGroupOnce() {
        let payloadId = UUID()
        let tabs = [tab("A"), tab("B")]
        RestorationGroupRegistry.register(.init(tabs: tabs, selectedTabId: tabs[1].id), for: payloadId)

        let consumed = RestorationGroupRegistry.consume(for: payloadId)
        #expect(consumed?.tabs.map(\.id) == tabs.map(\.id))
        #expect(consumed?.selectedTabId == tabs[1].id)

        #expect(RestorationGroupRegistry.consume(for: payloadId) == nil)
    }

    @Test("Consuming a nil payload id returns nil")
    func registryConsumeNilReturnsNil() {
        #expect(RestorationGroupRegistry.consume(for: nil) == nil)
    }

    @Test("Window group defaults to immediate load timing")
    func windowGroupDefaultsToImmediate() {
        let group = RestorationGroupRegistry.WindowGroup(tabs: [tab("A")], selectedTabId: nil)
        #expect(group.loadTiming == .immediate)
    }

    @Test("Registry round-trips deferred load timing")
    func registryRoundTripsLoadTiming() {
        let payloadId = UUID()
        RestorationGroupRegistry.register(
            .init(tabs: [tab("A")], selectedTabId: nil, loadTiming: .deferred),
            for: payloadId
        )
        #expect(RestorationGroupRegistry.consume(for: payloadId)?.loadTiming == .deferred)
    }

    @Test("Restored sort columns resolve to indices, preserving order and dropping missing columns")
    func resolveRestoredSortColumns() {
        let persisted = [
            PersistedSortColumn(columnName: "name", direction: .ascending),
            PersistedSortColumn(columnName: "ghost", direction: .descending),
            PersistedSortColumn(columnName: "id", direction: .descending)
        ]

        let resolved = MainContentCoordinator.resolveRestoredSortColumns(persisted, in: ["id", "email", "name"])

        #expect(resolved.count == 2)
        #expect(resolved[0].columnName == "name")
        #expect(resolved[0].columnIndex == 2)
        #expect(resolved[0].direction == .ascending)
        #expect(resolved[1].columnName == "id")
        #expect(resolved[1].columnIndex == 0)
        #expect(resolved[1].direction == .descending)
    }

    @Test("Resolving sort columns against an empty column set yields nothing")
    func resolveRestoredSortColumnsEmpty() {
        let persisted = [PersistedSortColumn(columnName: "id", direction: .ascending)]
        #expect(MainContentCoordinator.resolveRestoredSortColumns(persisted, in: []).isEmpty)
    }

    @Test("Last open connections round-trip through storage")
    func connectionListRoundTrip() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LastOpenConnectionsTests-\(UUID().uuidString)", isDirectory: true)
        let storage = LastOpenConnectionsStorage(directory: directory)
        let ids = [UUID(), UUID(), UUID()]

        storage.save(connectionIds: ids)
        #expect(storage.load() == ids)

        storage.clear()
        #expect(storage.load().isEmpty)
    }

    @Test("Loading from an empty directory returns no connections")
    func connectionListMissingFileReturnsEmpty() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LastOpenConnectionsTests-\(UUID().uuidString)", isDirectory: true)
        #expect(LastOpenConnectionsStorage(directory: directory).load().isEmpty)
    }

    @Test("Saving an empty list clears the stored file")
    func savingEmptyListClears() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LastOpenConnectionsTests-\(UUID().uuidString)", isDirectory: true)
        let storage = LastOpenConnectionsStorage(directory: directory)

        storage.save(connectionIds: [UUID()])
        storage.save(connectionIds: [])
        #expect(storage.load().isEmpty)
    }
}
