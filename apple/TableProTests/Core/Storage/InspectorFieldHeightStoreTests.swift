//
//  InspectorFieldHeightStoreTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct InspectorFieldHeightStoreTests {
    private let scratch: EphemeralDefaults

    init() throws {
        scratch = try EphemeralDefaults()
    }

    @Test("A height belongs to its column, and other columns keep their default")
    func heightIsPerColumn() {
        let store = InspectorFieldHeightStore(defaults: scratch.defaults)

        store.setHeight(300, for: "payload")

        #expect(store.height(for: "payload") == 300)
        #expect(store.height(for: "metadata") == nil)
    }

    @Test("A height survives a relaunch")
    func heightSurvivesRelaunch() {
        InspectorFieldHeightStore(defaults: scratch.defaults).setHeight(300, for: "payload")

        #expect(InspectorFieldHeightStore(defaults: scratch.defaults).height(for: "payload") == 300)
    }

    @Test("Setting a column again replaces its height")
    func heightIsReplaced() {
        let store = InspectorFieldHeightStore(defaults: scratch.defaults)

        store.setHeight(300, for: "payload")
        store.setHeight(180, for: "payload")

        #expect(store.height(for: "payload") == 180)
        #expect(InspectorFieldHeightStore(defaults: scratch.defaults).heights == ["payload": 180])
    }

    @Test("Past capacity the least recently set column is dropped")
    func evictsLeastRecentlySet() {
        let store = InspectorFieldHeightStore(defaults: scratch.defaults)
        for index in 0..<InspectorFieldHeightStore.capacity {
            store.setHeight(200, for: "column\(index)")
        }

        store.setHeight(250, for: "column0")
        store.setHeight(300, for: "newest")

        #expect(store.heights.count == InspectorFieldHeightStore.capacity)
        #expect(store.height(for: "column0") == 250)
        #expect(store.height(for: "column1") == nil)
        #expect(store.height(for: "newest") == 300)
        #expect(InspectorFieldHeightStore(defaults: scratch.defaults).heights == store.heights)
    }

    @Test("Unreadable saved heights load as none")
    func unreadableDataLoadsEmpty() {
        scratch.defaults.set(Data("not json".utf8), forKey: PreferenceKeys.rowInspectorFieldHeights.name)

        #expect(InspectorFieldHeightStore(defaults: scratch.defaults).heights.isEmpty)
    }

    @Test("After a settings reset, a reload drops every height")
    func reloadAfterReset() {
        let store = InspectorFieldHeightStore(defaults: scratch.defaults)
        store.setHeight(300, for: "payload")

        AppSettingsStorage(userDefaults: scratch.defaults).resetToDefaults()
        store.reload()

        #expect(store.heights.isEmpty)
    }
}
