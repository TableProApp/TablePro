//
//  AppSettingsStorageResetTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct AppSettingsStorageResetTests {
    @Test("Reset clears the selected settings pane and default sidebar layout")
    func resetClearsUIOrphans() throws {
        let defaults = try #require(UserDefaults(suiteName: "settings-reset-\(UUID().uuidString)"))
        let storage = AppSettingsStorage(userDefaults: defaults)
        defaults.set("account", forKey: PreferenceKeys.selectedSettingsPane.name)
        defaults.set("tree", forKey: SidebarPersistenceKey.defaultLayout)
        defaults.set(320.0, forKey: PreferenceKeys.rowInspectorJsonFieldHeight.name)

        storage.resetToDefaults()

        #expect(defaults.string(forKey: PreferenceKeys.selectedSettingsPane.name) == nil)
        #expect(defaults.string(forKey: SidebarPersistenceKey.defaultLayout) == nil)
        #expect(defaults.object(forKey: PreferenceKeys.rowInspectorJsonFieldHeight.name) == nil)
    }

    @Test("Reset restores recent connection visibility")
    func resetRestoresRecentConnections() throws {
        let suite = "settings-reset-recents-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = AppSettingsStorage(userDefaults: defaults)
        storage.saveGeneral(GeneralSettings(showRecentConnections: false))

        storage.resetToDefaults()

        #expect(storage.loadGeneral().showRecentConnections)
    }
}
