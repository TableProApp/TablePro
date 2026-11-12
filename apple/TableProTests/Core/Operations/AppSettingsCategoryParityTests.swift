//
//  AppSettingsCategoryParityTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

struct AppSettingsCategoryParityTests {
    @Test("No category is both synced and device-local")
    func deviceLocalCategoriesAreNotSynced() {
        #expect(AppSettingsCategory.deviceLocal.isDisjoint(with: Set(AppSettingsCategory.synced)))
    }

    @Test("The appearance mode is device-local, and the theme ids it sat next to still sync")
    func appearanceModeIsDeviceLocal() {
        #expect(AppSettingsCategory.deviceLocal.contains(AppSettingsCategory.appearanceMode))
        #expect(!AppSettingsCategory.synced.contains(AppSettingsCategory.appearanceMode))
        #expect(AppSettingsCategory.synced.contains(AppSettingsCategory.appearance))
    }

    @Test("Notification settings are among the synced categories")
    func notificationsSync() {
        #expect(AppSettingsCategory.synced.contains(AppSettingsCategory.notifications))
    }

    @MainActor
    @Test("Value colors sync as their own category, and a rewrite of the Data Grid blob keeps them")
    func valueColorsSyncAsTheirOwnCategory() throws {
        #expect(AppSettingsCategory.synced.contains(AppSettingsCategory.valueColors))
        let pool = EphemeralDefaultsPool()
        let storage = AppSettingsStorage(userDefaults: try pool.make().defaults)
        storage.saveValueColors(ValueColorSettings(colorsValuesByType: true))

        storage.saveDataGrid(.default)

        #expect(storage.loadValueColors().colorsValuesByType)
    }

    @MainActor
    @Test("Value colors persist under their own key, read off when never saved, and reset with the rest")
    func valueColorsStorageRoundTrip() throws {
        let pool = EphemeralDefaultsPool()
        let storage = AppSettingsStorage(userDefaults: try pool.make().defaults)
        #expect(storage.loadValueColors() == .default)

        storage.saveValueColors(ValueColorSettings(colorsValuesByType: true))
        #expect(storage.loadValueColors().colorsValuesByType)
        #expect(storage.loadDataGrid() == .default)

        storage.resetToDefaults()
        #expect(storage.loadValueColors() == .default)
    }
}
