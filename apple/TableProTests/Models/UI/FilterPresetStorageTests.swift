//
//  FilterPresetStorageTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@MainActor
struct FilterPresetStorageTests {
    private let storage = FilterPresetStorage.shared

    private func cleanup() {
        storage.deleteAllPresets()
    }

    @Test("Saving a uniquely named preset stores it as typed")
    func savePresetUniqueNameStoresAsTyped() throws {
        cleanup()
        defer { cleanup() }

        let preset = FilterPreset(name: "Alpha", filters: [])
        try storage.savePreset(preset)

        let presets = storage.loadAllPresets()
        #expect(presets.count == 1)
        #expect(presets.first?.name == "Alpha")
    }

    @Test("Saving a duplicate name with a different id appends suffix (2)")
    func savePresetDuplicateNameDifferentIdAppendsSuffix2() throws {
        cleanup()
        defer { cleanup() }

        try storage.savePreset(FilterPreset(name: "Alpha", filters: []))
        try storage.savePreset(FilterPreset(id: UUID(), name: "Alpha", filters: []))

        let presets = storage.loadAllPresets()
        #expect(presets.count == 2)
        #expect(Set(presets.map(\.name)) == ["Alpha", "Alpha (2)"])
    }

    @Test("Repeated duplicates increment the counter")
    func savePresetRepeatedDuplicatesIncrementsCounter() throws {
        cleanup()
        defer { cleanup() }

        try storage.savePreset(FilterPreset(name: "Alpha", filters: []))
        try storage.savePreset(FilterPreset(id: UUID(), name: "Alpha", filters: []))
        try storage.savePreset(FilterPreset(id: UUID(), name: "Alpha", filters: []))

        let presets = storage.loadAllPresets()
        #expect(presets.count == 3)
        #expect(Set(presets.map(\.name)) == ["Alpha", "Alpha (2)", "Alpha (3)"])
    }

    @Test("Saving with the same id replaces the preset in place")
    func savePresetSameIdReplacesInPlace() throws {
        cleanup()
        defer { cleanup() }

        let id = UUID()
        try storage.savePreset(FilterPreset(id: id, name: "Alpha", filters: []))
        try storage.savePreset(FilterPreset(id: id, name: "Beta", filters: []))

        let presets = storage.loadAllPresets()
        #expect(presets.count == 1)
        #expect(presets.first?.id == id)
        #expect(presets.first?.name == "Beta")
    }

    @Test("Same-id upsert wins over name dedup")
    func savePresetSameIdKeepsPlaceEvenIfNameMatchesAnother() throws {
        cleanup()
        defer { cleanup() }

        let idA = UUID()
        let idB = UUID()
        try storage.savePreset(FilterPreset(id: idA, name: "Alpha", filters: []))
        try storage.savePreset(FilterPreset(id: idB, name: "Beta", filters: []))
        try storage.savePreset(FilterPreset(id: idB, name: "Alpha", filters: []))

        let presets = storage.loadAllPresets()
        #expect(presets.count == 2)

        let byId = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0.name) })
        #expect(byId[idA] == "Alpha")
        #expect(byId[idB] == "Alpha")
    }

    @Test("A preset keeps its logic mode through encoding")
    func presetLogicModeRoundTrips() throws {
        let preset = FilterPreset(
            name: "Any",
            filters: [TestFixtures.makeTableFilter(column: "id")],
            logicMode: .or,
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        )

        let decoded = try JSONDecoder().decode(FilterPreset.self, from: JSONEncoder().encode(preset))

        #expect(decoded == preset)
        #expect(decoded.logicMode == .or)
    }

    @Test("A preset saved before logic modes were kept decodes with none")
    func presetWithoutLogicModeDecodesNil() throws {
        let json = Data("""
        {"id":"\(UUID().uuidString)","name":"Old","filters":[],"createdAt":0}
        """.utf8)

        let decoded = try JSONDecoder().decode(FilterPreset.self, from: json)

        #expect(decoded.name == "Old")
        #expect(decoded.logicMode == nil)
    }

    @Test("Loading a preset with no logic mode keeps the tab's, one with a mode sets it")
    func loadPresetLogicMode() {
        let row = TestFixtures.makeTableFilter(column: "name")
        var state = TabFilterState()

        state.filterLogicMode = .or
        state.loadPreset(FilterPreset(name: "Old", filters: [row]))
        #expect(state.filterLogicMode == .or)

        state.filterLogicMode = .and
        state.loadPreset(FilterPreset(name: "Any", filters: [row], logicMode: .or))
        #expect(state.filterLogicMode == .or)
    }
}
