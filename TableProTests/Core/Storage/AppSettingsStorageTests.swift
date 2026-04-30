//
//  AppSettingsStorageTests.swift
//  TableProTests
//
//  Tests for AppSettingsStorage multi-connection session restoration.
//

import Foundation
@testable import TablePro
import Testing

@Suite("AppSettingsStorage - Last Open Connection IDs")
struct AppSettingsStorageLastOpenConnectionTests {
    private let storage: AppSettingsStorage
    private let defaults: UserDefaults

    init() {
        let suiteName = "com.TablePro.tests.AppSettingsStorage.\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: suiteName)!
        self.storage = AppSettingsStorage(userDefaults: defaults)
    }

    @Test("saveLastOpenConnectionIds + loadLastOpenConnectionIds round-trip")
    func roundTrip() {
        let ids = [UUID(), UUID(), UUID()]

        storage.saveLastOpenConnectionIds(ids)
        let loaded = storage.loadLastOpenConnectionIds()

        #expect(loaded == ids)
    }

    @Test("loadLastOpenConnectionIds returns empty when nothing saved")
    func returnsEmptyWhenNothingSaved() {
        let loaded = storage.loadLastOpenConnectionIds()
        #expect(loaded.isEmpty)
    }

    @Test("saveLastOpenConnectionIds with empty array clears state")
    func emptyArrayClearsState() {
        let ids = [UUID()]
        storage.saveLastOpenConnectionIds(ids)
        storage.saveLastOpenConnectionIds([])

        let loaded = storage.loadLastOpenConnectionIds()
        #expect(loaded.isEmpty)
    }

    @Test("saveLastOpenConnectionIds overwrites previous state")
    func overwritesPreviousState() {
        let first = [UUID(), UUID()]
        let second = [UUID()]

        storage.saveLastOpenConnectionIds(first)
        storage.saveLastOpenConnectionIds(second)

        let loaded = storage.loadLastOpenConnectionIds()
        #expect(loaded == second)
    }

    @Test("loadLastOpenConnectionIds ignores malformed UUID strings")
    func ignoresMalformedUUIDs() {
        let validId = UUID()
        storage.saveLastOpenConnectionIds([validId])

        defaults.set(
            [validId.uuidString, "not-a-uuid", "also-bad"],
            forKey: "com.TablePro.settings.lastOpenConnectionIds"
        )

        let loaded = storage.loadLastOpenConnectionIds()
        #expect(loaded == [validId])
    }

    @Test("Preserves order of connection IDs")
    func preservesOrder() {
        let ids = (0..<5).map { _ in UUID() }

        storage.saveLastOpenConnectionIds(ids)
        let loaded = storage.loadLastOpenConnectionIds()

        #expect(loaded == ids)
    }
}
