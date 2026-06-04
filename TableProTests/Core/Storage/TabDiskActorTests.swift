//
//  TabDiskActorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

private let legacyTabStateKeyPrefix = "com.TablePro.tabs."
private let migrationCompleteKey = "com.TablePro.tabStateMigrationComplete"

private func makeTabDiskDefaults() -> (UserDefaults, String) {
    let suiteName = "TablePro.TabDiskActorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

private func makeTabDiskDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TablePro.TabDiskActorTests.\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makePersistedTab(
    id: UUID = UUID(),
    title: String = "Query"
) -> PersistedTab {
    PersistedTab(
        id: id,
        title: title,
        query: "SELECT 1",
        tabType: .query,
        tableName: nil
    )
}

@Suite("TabDiskActor")
struct TabDiskActorTests {
    @Test("migrates legacy UserDefaults tab state through injected defaults")
    func migratesLegacyDefaultsThroughInjectedDefaults() async throws {
        let (defaults, suiteName) = makeTabDiskDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let directory = try makeTabDiskDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let connectionId = UUID()
        let tab = makePersistedTab(title: "Migrated Query")
        let legacyData = try JSONEncoder().encode(TabDiskState(tabs: [tab], selectedTabId: tab.id))
        let legacyKey = "\(legacyTabStateKeyPrefix)\(connectionId.uuidString)"
        defaults.set(legacyData, forKey: legacyKey)

        let actor = TabDiskActor(tabStateDirectory: directory, userDefaults: defaults)
        let loaded = await actor.load(connectionId: connectionId)

        #expect(loaded?.tabs.first?.title == "Migrated Query")
        #expect(loaded?.selectedTabId == tab.id)
        #expect(defaults.data(forKey: legacyKey) == nil)
        #expect(defaults.bool(forKey: migrationCompleteKey))
    }

    @Test("saves loads and clears tab state in injected directory")
    func savesLoadsAndClearsInjectedDirectory() async throws {
        let (defaults, suiteName) = makeTabDiskDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let directory = try makeTabDiskDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let connectionId = UUID()
        let tab = makePersistedTab(title: "Stored Query")
        let actor = TabDiskActor(tabStateDirectory: directory, userDefaults: defaults)

        try await actor.save(connectionId: connectionId, tabs: [tab], selectedTabId: tab.id)
        let loaded = await actor.load(connectionId: connectionId)

        #expect(loaded?.tabs.first?.title == "Stored Query")
        #expect(loaded?.selectedTabId == tab.id)

        await actor.clear(connectionId: connectionId)
        let cleared = await actor.load(connectionId: connectionId)

        #expect(cleared == nil)
    }
}
