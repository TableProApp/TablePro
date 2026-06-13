//
//  AppSettingsStorageMigrationTests.swift
//  TableProTests
//
//  Tests the one-time startup-behavior migration to "Reopen Last Session".
//

import Foundation
@testable import TablePro
import Testing

@Suite("AppSettingsStorage startup migration")
struct AppSettingsStorageMigrationTests {
    private let generalKey = "com.TablePro.settings.general"

    private func makeStorage() -> (storage: AppSettingsStorage, defaults: UserDefaults, suite: String) {
        let suite = "StartupMigrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (AppSettingsStorage(userDefaults: defaults), defaults, suite)
    }

    @Test("A saved showWelcome default flips to reopenLast")
    func migratesSavedShowWelcome() {
        let (storage, defaults, suite) = makeStorage()
        defer { defaults.removePersistentDomain(forName: suite) }

        storage.saveGeneral(GeneralSettings(startupBehavior: .showWelcome))
        storage.migrateStartupBehaviorToReopenLastIfNeeded()

        #expect(storage.loadGeneral().startupBehavior == .reopenLast)
    }

    @Test("An explicit reopenLast is left untouched")
    func leavesReopenLast() {
        let (storage, defaults, suite) = makeStorage()
        defer { defaults.removePersistentDomain(forName: suite) }

        storage.saveGeneral(GeneralSettings(startupBehavior: .reopenLast))
        storage.migrateStartupBehaviorToReopenLastIfNeeded()

        #expect(storage.loadGeneral().startupBehavior == .reopenLast)
    }

    @Test("A fresh install with no saved settings is not written by the migration")
    func skipsFreshInstall() {
        let (storage, defaults, suite) = makeStorage()
        defer { defaults.removePersistentDomain(forName: suite) }

        storage.migrateStartupBehaviorToReopenLastIfNeeded()

        #expect(defaults.data(forKey: generalKey) == nil)
    }

    @Test("The migration runs only once, then respects later choices")
    func runsOnce() {
        let (storage, defaults, suite) = makeStorage()
        defer { defaults.removePersistentDomain(forName: suite) }

        storage.saveGeneral(GeneralSettings(startupBehavior: .showWelcome))
        storage.migrateStartupBehaviorToReopenLastIfNeeded()
        #expect(storage.loadGeneral().startupBehavior == .reopenLast)

        storage.saveGeneral(GeneralSettings(startupBehavior: .showWelcome))
        storage.migrateStartupBehaviorToReopenLastIfNeeded()
        #expect(storage.loadGeneral().startupBehavior == .showWelcome)
    }
}
