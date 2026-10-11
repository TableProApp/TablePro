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

    @Test("Reset clears every remembered inspector field height and the geometry field's mode")
    func resetClearsInspectorFieldPreferences() throws {
        let defaults = try #require(UserDefaults(suiteName: "settings-reset-\(UUID().uuidString)"))
        let storage = AppSettingsStorage(userDefaults: defaults)
        defaults.set(320.0, forKey: PreferenceKeys.rowInspectorJsonFieldHeight.name)
        defaults.set(240.0, forKey: PreferenceKeys.rowInspectorTextFieldHeight.name)
        defaults.set(400.0, forKey: PreferenceKeys.rowInspectorGeometryFieldHeight.name)
        defaults.set("text", forKey: PreferenceKeys.rowInspectorGeometryFieldMode.name)

        storage.resetToDefaults()

        #expect(defaults.object(forKey: PreferenceKeys.rowInspectorJsonFieldHeight.name) == nil)
        #expect(defaults.object(forKey: PreferenceKeys.rowInspectorTextFieldHeight.name) == nil)
        #expect(defaults.object(forKey: PreferenceKeys.rowInspectorGeometryFieldHeight.name) == nil)
        #expect(defaults.object(forKey: PreferenceKeys.rowInspectorGeometryFieldMode.name) == nil)
    }
}
