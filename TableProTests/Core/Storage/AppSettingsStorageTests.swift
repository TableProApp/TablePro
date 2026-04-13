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
    private let storage = AppSettingsStorage.shared

    /// Clean state before and after each test to prevent cross-test pollution.
    private func cleanup() {
        storage.saveLastOpenConnectionIds([])
    }

    @Test("saveLastOpenConnectionIds + loadLastOpenConnectionIds round-trip")
    func roundTrip() {
        cleanup()
        let ids = [UUID(), UUID(), UUID()]

        storage.saveLastOpenConnectionIds(ids)
        let loaded = storage.loadLastOpenConnectionIds()

        #expect(loaded == ids)

        cleanup()
    }

    @Test("loadLastOpenConnectionIds returns empty when nothing saved")
    func returnsEmptyWhenNothingSaved() {
        cleanup()
        let loaded = storage.loadLastOpenConnectionIds()
        #expect(loaded.isEmpty)
    }

    @Test("saveLastOpenConnectionIds with empty array clears state")
    func emptyArrayClearsState() {
        cleanup()
        let ids = [UUID()]
        storage.saveLastOpenConnectionIds(ids)
        storage.saveLastOpenConnectionIds([])

        let loaded = storage.loadLastOpenConnectionIds()
        #expect(loaded.isEmpty)
    }

    @Test("saveLastOpenConnectionIds overwrites previous state")
    func overwritesPreviousState() {
        cleanup()
        let first = [UUID(), UUID()]
        let second = [UUID()]

        storage.saveLastOpenConnectionIds(first)
        storage.saveLastOpenConnectionIds(second)

        let loaded = storage.loadLastOpenConnectionIds()
        #expect(loaded == second)

        cleanup()
    }

    @Test("loadLastOpenConnectionIds ignores malformed UUID strings")
    func ignoresMalformedUUIDs() {
        cleanup()
        // Write raw strings directly to verify the load method handles bad data
        let validId = UUID()
        storage.saveLastOpenConnectionIds([validId])

        // Overwrite with raw strings including invalid UUIDs
        UserDefaults.standard.set(
            [validId.uuidString, "not-a-uuid", "also-bad"],
            forKey: "com.TablePro.settings.lastOpenConnectionIds"
        )

        let loaded = storage.loadLastOpenConnectionIds()
        #expect(loaded == [validId])

        cleanup()
    }

    @Test("Preserves order of connection IDs")
    func preservesOrder() {
        cleanup()
        let ids = (0..<5).map { _ in UUID() }

        storage.saveLastOpenConnectionIds(ids)
        let loaded = storage.loadLastOpenConnectionIds()

        #expect(loaded == ids)

        cleanup()
    }
}
