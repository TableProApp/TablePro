//
//  KeychainHelperTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("KeychainHelper")
struct KeychainHelperTests {
    private let helper = KeychainHelper.shared

    @Test("Save and load round trip")
    func saveAndLoadRoundTrip() {
        let key = "test.roundtrip.\(UUID().uuidString)"
        defer { helper.delete(key: key) }

        let saved = helper.saveString("hello", forKey: key)
        #expect(saved)

        let loaded = helper.loadString(forKey: key)
        #expect(loaded == "hello")
    }

    @Test("Delete removes item")
    func deleteRemovesItem() {
        let key = "test.delete.\(UUID().uuidString)"
        defer { helper.delete(key: key) }

        _ = helper.saveString("temporary", forKey: key)
        helper.delete(key: key)

        let loaded = helper.loadString(forKey: key)
        #expect(loaded == nil)
    }

    @Test("Upsert overwrites existing value")
    func upsertOverwritesExistingValue() {
        let key = "test.upsert.\(UUID().uuidString)"
        defer { helper.delete(key: key) }

        _ = helper.saveString("first", forKey: key)
        _ = helper.saveString("second", forKey: key)

        let loaded = helper.loadString(forKey: key)
        #expect(loaded == "second")
    }

    @Test("Load nonexistent returns nil")
    func loadNonexistentReturnsNil() {
        let key = "test.nonexistent.\(UUID().uuidString)"
        defer { helper.delete(key: key) }

        let loaded = helper.loadString(forKey: key)
        #expect(loaded == nil)
    }

    @Test("Migration flag defaults to false")
    func migrationFlagDefaultsFalse() {
        let defaultsKey = "com.TablePro.keychainMigratedToDataProtection"
        let previous = UserDefaults.standard.object(forKey: defaultsKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        UserDefaults.standard.removeObject(forKey: defaultsKey)
        let value = UserDefaults.standard.bool(forKey: defaultsKey)
        #expect(value == false)
    }
}
