//
//  QueryTabFoldPersistenceTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("Query tab fold persistence")
@MainActor
struct QueryTabFoldPersistenceTests {

    private let query = "CREATE TABLE t (\n    id INT,\n    name TEXT\n);\n"

    private func tab(withFolds folds: [Range<Int>]?) -> QueryTab {
        var tab = QueryTab(title: "Query", query: query)
        tab.collapsedFoldRanges = folds
        return tab
    }

    @Test("Collapsed folds survive a save and load round trip")
    func roundTrip() {
        let folds = [16..<43, 20..<30]
        let restored = QueryTab(from: tab(withFolds: folds).toPersistedTab(), defaultPageSize: 100)
        #expect(restored.collapsedFoldRanges == folds)
    }

    @Test("A tab with no folds persists nothing")
    func noFolds() {
        #expect(tab(withFolds: nil).toPersistedTab().collapsedFoldRanges == nil)
        #expect(tab(withFolds: []).toPersistedTab().collapsedFoldRanges == nil)
    }

    @Test("A fold past the end of the query is dropped rather than replayed")
    func dropsOutOfBoundsFold() {
        let persisted = tab(withFolds: [16..<43]).toPersistedTab()
        var shortened = persisted
        shortened.query = "SELECT 1;"

        #expect(QueryTab(from: shortened, defaultPageSize: 100).collapsedFoldRanges == nil)
    }

    @Test("An inverted or empty fold range is dropped")
    func dropsDegenerateRanges() {
        var persisted = tab(withFolds: nil).toPersistedTab()
        persisted.collapsedFoldRanges = [30, 10, 5, 5]

        #expect(QueryTab(from: persisted, defaultPageSize: 100).collapsedFoldRanges == nil)
    }

    @Test("A trailing unpaired bound is ignored, and valid pairs still restore")
    func ignoresUnpairedBound() {
        var persisted = tab(withFolds: nil).toPersistedTab()
        persisted.collapsedFoldRanges = [16, 43, 20]

        #expect(QueryTab(from: persisted, defaultPageSize: 100).collapsedFoldRanges == [16..<43])
    }

    @Test("A tab file written before folding existed still decodes")
    func decodesTabWithoutFoldField() throws {
        let encoded = try JSONEncoder().encode(tab(withFolds: [16..<43]).toPersistedTab())
        var object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "collapsedFoldRanges")

        let legacy = try JSONSerialization.data(withJSONObject: object)
        let persisted = try JSONDecoder().decode(PersistedTab.self, from: legacy)

        #expect(persisted.collapsedFoldRanges == nil)
        #expect(QueryTab(from: persisted, defaultPageSize: 100).collapsedFoldRanges == nil)
    }
}
