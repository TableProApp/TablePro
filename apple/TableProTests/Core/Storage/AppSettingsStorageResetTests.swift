//
//  AppSettingsStorageResetTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct AppSettingsStorageResetTests {
    private let pool = EphemeralDefaultsPool()

    @Test("Reset clears the selected settings pane and default sidebar layout")
    func resetClearsUIOrphans() throws {
        let defaults = try pool.make().defaults
        let storage = AppSettingsStorage(userDefaults: defaults)
        defaults.set("account", forKey: PreferenceKeys.selectedSettingsPane.name)
        defaults.set("tree", forKey: SidebarPersistenceKey.defaultLayout)

        storage.resetToDefaults()

        #expect(defaults.string(forKey: PreferenceKeys.selectedSettingsPane.name) == nil)
        #expect(defaults.string(forKey: SidebarPersistenceKey.defaultLayout) == nil)
    }

    @Test("Reset clears every remembered inspector field height and the geometry field's mode")
    func resetClearsInspectorFieldPreferences() throws {
        let defaults = try pool.make().defaults
        let storage = AppSettingsStorage(userDefaults: defaults)
        defaults.set(Data("[]".utf8), forKey: PreferenceKeys.rowInspectorFieldHeights.name)
        defaults.set("text", forKey: PreferenceKeys.rowInspectorGeometryFieldMode.name)

        storage.resetToDefaults()

        #expect(defaults.object(forKey: PreferenceKeys.rowInspectorFieldHeights.name) == nil)
        #expect(defaults.object(forKey: PreferenceKeys.rowInspectorGeometryFieldMode.name) == nil)
    }
}
