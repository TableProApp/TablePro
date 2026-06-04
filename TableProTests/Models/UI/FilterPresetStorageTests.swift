//
//  FilterPresetStorageTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@MainActor
@Suite("FilterPresetStorage - savePreset", .serialized)
struct FilterPresetStorageTests {
    private func makeStorage() throws -> (storage: FilterPresetStorage, defaults: UserDefaults, suiteName: String) {
        let suiteName = "com.TablePro.tests.FilterPresetStorage.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (FilterPresetStorage(userDefaults: defaults), defaults, suiteName)
    }

    @Test("Saving a uniquely named preset stores it as typed")
    func savePresetUniqueNameStoresAsTyped() throws {
        let fixture = try makeStorage()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let storage = fixture.storage

        let preset = FilterPreset(name: "Alpha", filters: [])
        storage.savePreset(preset)

        let presets = storage.loadAllPresets()
        #expect(presets.count == 1)
        #expect(presets.first?.name == "Alpha")
    }

    @Test("Saving a duplicate name with a different id appends suffix (2)")
    func savePresetDuplicateNameDifferentIdAppendsSuffix2() throws {
        let fixture = try makeStorage()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let storage = fixture.storage

        storage.savePreset(FilterPreset(name: "Alpha", filters: []))
        storage.savePreset(FilterPreset(id: UUID(), name: "Alpha", filters: []))

        let presets = storage.loadAllPresets()
        #expect(presets.count == 2)
        #expect(Set(presets.map(\.name)) == ["Alpha", "Alpha (2)"])
    }

    @Test("Repeated duplicates increment the counter")
    func savePresetRepeatedDuplicatesIncrementsCounter() throws {
        let fixture = try makeStorage()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let storage = fixture.storage

        storage.savePreset(FilterPreset(name: "Alpha", filters: []))
        storage.savePreset(FilterPreset(id: UUID(), name: "Alpha", filters: []))
        storage.savePreset(FilterPreset(id: UUID(), name: "Alpha", filters: []))

        let presets = storage.loadAllPresets()
        #expect(presets.count == 3)
        #expect(Set(presets.map(\.name)) == ["Alpha", "Alpha (2)", "Alpha (3)"])
    }

    @Test("Saving with the same id replaces the preset in place")
    func savePresetSameIdReplacesInPlace() throws {
        let fixture = try makeStorage()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let storage = fixture.storage

        let id = UUID()
        storage.savePreset(FilterPreset(id: id, name: "Alpha", filters: []))
        storage.savePreset(FilterPreset(id: id, name: "Beta", filters: []))

        let presets = storage.loadAllPresets()
        #expect(presets.count == 1)
        #expect(presets.first?.id == id)
        #expect(presets.first?.name == "Beta")
    }

    @Test("Same-id upsert wins over name dedup")
    func savePresetSameIdKeepsPlaceEvenIfNameMatchesAnother() throws {
        let fixture = try makeStorage()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let storage = fixture.storage

        let idA = UUID()
        let idB = UUID()
        storage.savePreset(FilterPreset(id: idA, name: "Alpha", filters: []))
        storage.savePreset(FilterPreset(id: idB, name: "Beta", filters: []))
        storage.savePreset(FilterPreset(id: idB, name: "Alpha", filters: []))

        let presets = storage.loadAllPresets()
        #expect(presets.count == 2)

        let byId = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0.name) })
        #expect(byId[idA] == "Alpha")
        #expect(byId[idB] == "Alpha")
    }
}
