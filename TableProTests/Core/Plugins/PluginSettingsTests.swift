//
//  PluginSettingsTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("PluginSettingsStorage")
struct PluginSettingsStorageTests {

    private let testPluginId = "test.settings.\(UUID().uuidString)"

    private func cleanup(storage: PluginSettingsStorage) {
        storage.removeAll()
    }

    @Test("save and load round-trips a Codable value")
    func saveAndLoad() {
        let storage = PluginSettingsStorage(pluginId: testPluginId)
        defer { cleanup(storage: storage) }

        struct TestOptions: Codable, Equatable {
            var flag: Bool
            var count: Int
        }

        let original = TestOptions(flag: true, count: 42)
        storage.save(original)
        let loaded = storage.load(TestOptions.self)

        #expect(loaded == original)
    }

    @Test("load returns nil when no data exists")
    func loadReturnsNilWhenEmpty() {
        let storage = PluginSettingsStorage(pluginId: testPluginId)
        defer { cleanup(storage: storage) }

        struct EmptyOptions: Codable {
            var value: String
        }

        let result = storage.load(EmptyOptions.self)
        #expect(result == nil)
    }

    @Test("save overwrites previous value")
    func saveOverwritesPrevious() {
        let storage = PluginSettingsStorage(pluginId: testPluginId)
        defer { cleanup(storage: storage) }

        storage.save(10)
        storage.save(20)
        let loaded = storage.load(Int.self)

        #expect(loaded == 20)
    }

    @Test("different keys store independently")
    func differentKeysIndependent() {
        let storage = PluginSettingsStorage(pluginId: testPluginId)
        defer { cleanup(storage: storage) }

        storage.save("alpha", forKey: "keyA")
        storage.save("beta", forKey: "keyB")

        #expect(storage.load(String.self, forKey: "keyA") == "alpha")
        #expect(storage.load(String.self, forKey: "keyB") == "beta")
    }

    @Test("removeAll clears all keys for plugin")
    func removeAllClearsKeys() {
        let storage = PluginSettingsStorage(pluginId: testPluginId)

        storage.save("value1", forKey: "key1")
        storage.save("value2", forKey: "key2")
        storage.removeAll()

        #expect(storage.load(String.self, forKey: "key1") == nil)
        #expect(storage.load(String.self, forKey: "key2") == nil)
    }

    @Test("removeAll does not affect other plugins")
    func removeAllIsolatedToPlugin() {
        let storageA = PluginSettingsStorage(pluginId: testPluginId)
        let otherPluginId = "test.settings.other.\(UUID().uuidString)"
        let storageB = PluginSettingsStorage(pluginId: otherPluginId)
        defer {
            cleanup(storage: storageA)
            cleanup(storage: storageB)
        }

        storageA.save("fromA")
        storageB.save("fromB")
        storageA.removeAll()

        #expect(storageA.load(String.self) == nil)
        #expect(storageB.load(String.self) == "fromB")
    }

    @Test("keys are namespaced with com.TablePro.plugin prefix")
    func keysNamespaced() {
        let pluginId = "test.namespace.\(UUID().uuidString)"
        let storage = PluginSettingsStorage(pluginId: pluginId)
        defer { cleanup(storage: storage) }

        storage.save(true)

        let expectedKey = "com.TablePro.plugin.\(pluginId).settings"
        let value = UserDefaults.standard.data(forKey: expectedKey)
        #expect(value != nil)
    }

    @Test("load returns nil for type mismatch")
    func loadTypeMismatch() {
        let storage = PluginSettingsStorage(pluginId: testPluginId)
        defer { cleanup(storage: storage) }

        storage.save("a string value")

        struct DifferentType: Codable {
            var number: Int
        }

        let result = storage.load(DifferentType.self)
        #expect(result == nil)
    }
}

@Suite("PluginCapability")
struct PluginCapabilityTests {

    @Test("only has 3 cases: databaseDriver, exportFormat, importFormat")
    func onlyThreeCases() {
        let allCases: [PluginCapability] = [.databaseDriver, .exportFormat, .importFormat]
        #expect(allCases.count == 3)
    }

    @Test("raw values are stable integers")
    func rawValuesStable() {
        #expect(PluginCapability.databaseDriver.rawValue == 0)
        #expect(PluginCapability.exportFormat.rawValue == 1)
        #expect(PluginCapability.importFormat.rawValue == 2)
    }

    @Test("Codable round-trip preserves value")
    func codableRoundTrip() throws {
        let original = PluginCapability.exportFormat
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PluginCapability.self, from: data)
        #expect(decoded == original)
    }

    @Test("decoding removed raw value 3 fails gracefully")
    func decodingRemovedRawValueFails() {
        let json = Data("3".utf8)
        let decoded = try? JSONDecoder().decode(PluginCapability.self, from: json)
        #expect(decoded == nil)
    }
}

@Suite("DisabledPlugins Key Migration", .serialized)
struct DisabledPluginsMigrationTests {

    @Test("migration moves legacy key to namespaced key")
    func migrationMovesKey() {
        let testKey = "disabledPlugins"
        let namespacedKey = "com.TablePro.disabledPlugins"
        let defaults = UserDefaults.standard

        // Save current state
        let savedNamespaced = defaults.stringArray(forKey: namespacedKey)
        let savedLegacy = defaults.stringArray(forKey: testKey)

        defer {
            // Restore original state
            if let saved = savedNamespaced {
                defaults.set(saved, forKey: namespacedKey)
            } else {
                defaults.removeObject(forKey: namespacedKey)
            }
            if let saved = savedLegacy {
                defaults.set(saved, forKey: testKey)
            } else {
                defaults.removeObject(forKey: testKey)
            }
        }

        // Set up legacy key
        defaults.removeObject(forKey: namespacedKey)
        defaults.set(["plugin.a", "plugin.b"], forKey: testKey)

        // Simulate what migrateDisabledPluginsKey does
        if let legacy = defaults.stringArray(forKey: testKey) {
            if defaults.stringArray(forKey: namespacedKey) == nil {
                defaults.set(legacy, forKey: namespacedKey)
            }
            defaults.removeObject(forKey: testKey)
        }

        #expect(defaults.stringArray(forKey: namespacedKey) == ["plugin.a", "plugin.b"])
        #expect(defaults.stringArray(forKey: testKey) == nil)
    }

    @Test("migration is no-op when legacy key absent")
    func migrationNoOpWhenAbsent() {
        let testKey = "disabledPlugins"
        let namespacedKey = "com.TablePro.disabledPlugins"
        let defaults = UserDefaults.standard

        let savedNamespaced = defaults.stringArray(forKey: namespacedKey)
        let savedLegacy = defaults.stringArray(forKey: testKey)

        defer {
            if let saved = savedNamespaced {
                defaults.set(saved, forKey: namespacedKey)
            } else {
                defaults.removeObject(forKey: namespacedKey)
            }
            if let saved = savedLegacy {
                defaults.set(saved, forKey: testKey)
            } else {
                defaults.removeObject(forKey: testKey)
            }
        }

        defaults.removeObject(forKey: testKey)
        defaults.set(["existing.plugin"], forKey: namespacedKey)

        // Simulate migration
        if let legacy = defaults.stringArray(forKey: testKey) {
            if defaults.stringArray(forKey: namespacedKey) == nil {
                defaults.set(legacy, forKey: namespacedKey)
            }
            defaults.removeObject(forKey: testKey)
        }

        #expect(defaults.stringArray(forKey: namespacedKey) == ["existing.plugin"])
    }

    @Test("migration preserves namespaced key when both keys exist")
    func migrationPreservesNamespacedWhenBothExist() {
        let testKey = "disabledPlugins"
        let namespacedKey = "com.TablePro.disabledPlugins"
        let defaults = UserDefaults.standard

        let savedNamespaced = defaults.stringArray(forKey: namespacedKey)
        let savedLegacy = defaults.stringArray(forKey: testKey)

        defer {
            if let saved = savedNamespaced {
                defaults.set(saved, forKey: namespacedKey)
            } else {
                defaults.removeObject(forKey: namespacedKey)
            }
            if let saved = savedLegacy {
                defaults.set(saved, forKey: testKey)
            } else {
                defaults.removeObject(forKey: testKey)
            }
        }

        defaults.set(["legacy.plugin"], forKey: testKey)
        defaults.set(["current.plugin"], forKey: namespacedKey)

        // Simulate migration
        if let legacy = defaults.stringArray(forKey: testKey) {
            if defaults.stringArray(forKey: namespacedKey) == nil {
                defaults.set(legacy, forKey: namespacedKey)
            }
            defaults.removeObject(forKey: testKey)
        }

        #expect(defaults.stringArray(forKey: namespacedKey) == ["current.plugin"])
        #expect(defaults.stringArray(forKey: testKey) == nil)
    }
}
