//
//  SettingsTabSelectionStoreTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

private func makeSettingsTabSelectionDefaults() -> (UserDefaults, String) {
    let suiteName = "TablePro.SettingsTabSelectionStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

@Suite("SettingsTabSelectionStore")
struct SettingsTabSelectionStoreTests {
    @Test("persists selected settings tab")
    func persistsSelectedSettingsTab() {
        let (defaults, suiteName) = makeSettingsTabSelectionDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsTabSelectionStore(userDefaults: defaults)
        store.select(.plugins)

        #expect(defaults.string(forKey: SettingsTabSelectionStore.selectedTabKey) == SettingsTab.plugins.rawValue)
    }
}
