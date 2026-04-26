//
//  FilterPresetStorageTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("FilterPresetStorage - savePreset", .serialized)
struct FilterPresetStorageTests {
    private let storage = FilterPresetStorage.shared

    private func cleanup() {
        storage.deleteAllPresets()
    }

    @Test("Saving a uniquely named preset stores it as typed")
    func savePresetUniqueNameStoresAsTyped() {
        cleanup()
        defer { cleanup() }

        let preset = FilterPreset(name: "Alpha", filters: [])
        storage.savePreset(preset)

        let presets = storage.loadAllPresets()
        #expect(presets.count == 1)
        #expect(presets.first?.name == "Alpha")
    }

    @Test("Saving a duplicate name with a different id appends suffix (2)")
    func savePresetDuplicateNameDifferentIdAppendsSuffix2() {
        cleanup()
        defer { cleanup() }

        storage.savePreset(FilterPreset(name: "Alpha", filters: []))
        storage.savePreset(FilterPreset(id: UUID(), name: "Alpha", filters: []))

        let presets = storage.loadAllPresets()
        #expect(presets.count == 2)
        #expect(Set(presets.map(\.name)) == ["Alpha", "Alpha (2)"])
    }

    @Test("Repeated duplicates increment the counter")
    func savePresetRepeatedDuplicatesIncrementsCounter() {
        cleanup()
        defer { cleanup() }

        storage.savePreset(FilterPreset(name: "Alpha", filters: []))
        storage.savePreset(FilterPreset(id: UUID(), name: "Alpha", filters: []))
        storage.savePreset(FilterPreset(id: UUID(), name: "Alpha", filters: []))

        let presets = storage.loadAllPresets()
        #expect(presets.count == 3)
        #expect(Set(presets.map(\.name)) == ["Alpha", "Alpha (2)", "Alpha (3)"])
    }

    @Test("Saving with the same id replaces the preset in place")
    func savePresetSameIdReplacesInPlace() {
        cleanup()
        defer { cleanup() }

        let id = UUID()
        storage.savePreset(FilterPreset(id: id, name: "Alpha", filters: []))
        storage.savePreset(FilterPreset(id: id, name: "Beta", filters: []))

        let presets = storage.loadAllPresets()
        #expect(presets.count == 1)
        #expect(presets.first?.id == id)
        #expect(presets.first?.name == "Beta")
    }

    @Test("Same-id upsert wins over name dedup")
    func savePresetSameIdKeepsPlaceEvenIfNameMatchesAnother() {
        cleanup()
        defer { cleanup() }

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
