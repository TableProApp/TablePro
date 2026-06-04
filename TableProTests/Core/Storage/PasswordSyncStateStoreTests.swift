//
//  PasswordSyncStateStoreTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

private func makePasswordSyncDefaults() -> (UserDefaults, String) {
    let suiteName = "TablePro.PasswordSyncStateStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

@Suite("PasswordSyncStateStore")
struct PasswordSyncStateStoreTests {
    @Test("defaults to disabled")
    func defaultsToDisabled() {
        let (defaults, suiteName) = makePasswordSyncDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PasswordSyncStateStore(userDefaults: defaults)

        #expect(store.isEnabled == false)
    }

    @Test("persists explicit flag")
    func persistsExplicitFlag() {
        let (defaults, suiteName) = makePasswordSyncDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PasswordSyncStateStore(userDefaults: defaults)
        store.setEnabled(true)

        #expect(store.isEnabled)
    }

    @Test("enables only when all sync switches allow password sync")
    func appliesEffectiveSyncSettings() {
        let (defaults, suiteName) = makePasswordSyncDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PasswordSyncStateStore(userDefaults: defaults)

        store.apply(syncSettings(enabled: true, syncConnections: true, syncPasswords: true))
        #expect(store.isEnabled)

        let disabledCases = [
            syncSettings(enabled: false, syncConnections: true, syncPasswords: true),
            syncSettings(enabled: true, syncConnections: false, syncPasswords: true),
            syncSettings(enabled: true, syncConnections: true, syncPasswords: false)
        ]

        for settings in disabledCases {
            store.apply(settings)
            #expect(store.isEnabled == false)
        }
    }

    private func syncSettings(
        enabled: Bool,
        syncConnections: Bool,
        syncPasswords: Bool
    ) -> SyncSettings {
        SyncSettings(
            enabled: enabled,
            syncConnections: syncConnections,
            syncGroupsAndTags: true,
            syncSettings: true,
            syncPasswords: syncPasswords
        )
    }
}
