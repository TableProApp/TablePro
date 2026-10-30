//
//  RoutineDebugOptionStoreTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct RoutineDebugOptionStoreTests {
    private let pool = EphemeralDefaultsPool()

    private static func isolatedQueryHistory() -> QueryHistoryManager {
        QueryHistoryManager(
            storage: QueryHistoryStorage(
                databaseURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("tablepro-tests")
                    .appendingPathComponent("debug_options_\(UUID().uuidString).db"),
                removeDatabaseOnDeinit: true
            ),
            isCapturePaused: { false }
        )
    }

    @Test("Deleting a connection removes its start options and keeps another connection's")
    func connectionDeleteRemovesItsOptions() throws {
        let defaults = try pool.make().defaults
        let store = RoutineDebugOptionStore(defaults: { defaults })
        let deleted = UUID()
        let kept = UUID()
        store.save(["host": "10.0.0.5", "port": "4000"], connectionId: deleted)
        store.save(["host": "10.0.0.9"], connectionId: kept)

        ConnectionLocalState.purge(
            connectionIds: [deleted],
            origin: .remote,
            tableScopedStores: [],
            queryHistory: Self.isolatedQueryHistory(),
            defaults: defaults
        )

        #expect(store.value(for: "host", connectionId: deleted) == nil)
        #expect(store.value(for: "port", connectionId: deleted) == nil)
        #expect(store.value(for: "host", connectionId: kept) == "10.0.0.9")
    }

    @Test("Reset All Settings removes every connection's start options and nothing else")
    func resetRemovesAllOptions() throws {
        let defaults = try pool.make().defaults
        let store = RoutineDebugOptionStore(defaults: { defaults })
        let first = UUID()
        let second = UUID()
        store.save(["host": "10.0.0.5"], connectionId: first)
        store.save(["port": "4000"], connectionId: second)
        defaults.set("kept", forKey: "RoutineDebugOptionsUnrelated")

        AppSettingsStorage(userDefaults: defaults).resetToDefaults()

        #expect(store.value(for: "host", connectionId: first) == nil)
        #expect(store.value(for: "port", connectionId: second) == nil)
        #expect(defaults.string(forKey: "RoutineDebugOptionsUnrelated") == "kept")
    }
}
