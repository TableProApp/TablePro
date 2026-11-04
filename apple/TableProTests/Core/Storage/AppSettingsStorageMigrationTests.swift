//
//  AppSettingsStorageMigrationTests.swift
//  TableProTests
//
//  Tests the startup-behavior migration and the retired inspector field heights.
//

import Foundation
@testable import TablePro
import Testing

struct AppSettingsStorageMigrationTests {
    private let generalKey = "com.TablePro.settings.general"
    private let scratch: EphemeralDefaults

    init() throws {
        scratch = try EphemeralDefaults()
    }

    private func makeStorage() -> (storage: AppSettingsStorage, defaults: UserDefaults, suite: String) {
        (AppSettingsStorage(userDefaults: scratch.defaults), scratch.defaults, scratch.suiteName)
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

    private let retiredFieldHeightKeys = [
        "rightSidebar.jsonFieldHeight",
        "com.TablePro.rightSidebar.jsonFieldHeight",
        "com.TablePro.rightSidebar.textFieldHeight",
        "com.TablePro.rightSidebar.geometryFieldHeight",
        "com.TablePro.settings.didMigrateJsonFieldHeightKey",
    ]

    @Test("The per-kind field heights an older build saved are removed")
    func removesRetiredFieldHeights() {
        let (storage, defaults, suite) = makeStorage()
        defer { defaults.removePersistentDomain(forName: suite) }

        for key in retiredFieldHeightKeys {
            defaults.set(320.0, forKey: key)
        }
        storage.removeRetiredFieldHeightKeys()

        for key in retiredFieldHeightKeys {
            #expect(defaults.object(forKey: key) == nil, "\(key) survived")
        }
    }

    @Test("Removing the per-kind heights leaves the per-column ones")
    func keepsPerColumnFieldHeights() {
        let (storage, defaults, suite) = makeStorage()
        defer { defaults.removePersistentDomain(forName: suite) }

        let saved = Data("[]".utf8)
        defaults.set(saved, forKey: PreferenceKeys.rowInspectorFieldHeights.name)
        storage.removeRetiredFieldHeightKeys()

        #expect(defaults.data(forKey: PreferenceKeys.rowInspectorFieldHeights.name) == saved)
    }
}
