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
}
