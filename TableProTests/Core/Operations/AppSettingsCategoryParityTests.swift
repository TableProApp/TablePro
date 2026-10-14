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

    @Test("Notification settings are among the synced categories")
    func notificationsSync() {
        #expect(AppSettingsCategory.synced.contains(AppSettingsCategory.notifications))
    }
}
