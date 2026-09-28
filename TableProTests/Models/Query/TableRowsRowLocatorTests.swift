//
//  TableRowsRowLocatorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct TableRowsRowLocatorTests {
    private func table(_ locators: [String?]?) -> TableRows {
        TableRows.from(
            queryRows: [["a"], ["b"], ["c"]],
            columns: ["_id"],
            columnTypes: [.text(rawType: nil)],
            rowLocators: locators
        )
    }

    @Test("Locators are keyed by row identity, and a row with none has none")
    func keyedByIdentity() {
        let rows = table(["A", nil, "C"])
        #expect(rows.rowLocator(for: .existing(0)) == "A")
        #expect(rows.rowLocator(for: .existing(1)) == nil)
        #expect(rows.rowLocator(for: .existing(2)) == "C")
    }

    @Test("A sort on the host keeps each row's locator with its row")
    func surviveReorder() {
        var rows = table(["A", "B", "C"])
        rows.reorderRows(ContiguousArray(rows.rows.reversed()))
        #expect(rows.rows[0].id == .existing(2))
        #expect(rows.rowLocator(for: rows.rows[0].id) == "C")
        #expect(rows.rowLocator(for: rows.rows[2].id) == "A")
    }

    @Test("Removing a row takes its locator and leaves the others")
    func surviveRemoval() {
        var rows = table(["A", "B", "C"])
        rows.remove(rowIDs: [.existing(0)])
        #expect(rows.rowLocator(for: .existing(0)) == nil)
        #expect(rows.rowLocator(for: .existing(1)) == "B")
        #expect(rows.rowLocator(for: rows.rows[1].id) == "C")
    }

    @Test("Replacing the rows replaces the locators, keyed from the offset")
    func replaceWithOffset() {
        var rows = table(["A", "B", "C"])
        rows.replace(rows: [["x"], ["y"]], offset: 10, rowLocators: ["X", "Y"])
        #expect(rows.rowLocator(for: .existing(10)) == "X")
        #expect(rows.rowLocator(for: .existing(11)) == "Y")
        #expect(rows.rowLocator(for: .existing(0)) == nil)
        rows.replace(rows: [["z"]])
        #expect(rows.rowLocator(for: .existing(0)) == nil)
    }

    @Test("A page appended after the first keeps its own locators")
    func appendPage() {
        var rows = table(["A", "B", "C"])
        rows.appendPage([["d"]], startingAt: 3, rowLocators: ["D"])
        #expect(rows.rowLocator(for: .existing(3)) == "D")
        #expect(rows.rowLocator(for: .existing(0)) == "A")
    }

    @Test("Locators that do not pair one to one with the rows are not kept")
    func countMismatch() {
        let rows = table(["A"])
        #expect(rows.rowLocators.isEmpty)
        #expect(table(nil).rowLocators.isEmpty)
    }

    @Test("Releasing the rows releases their locators")
    func discardClears() {
        var rows = table(["A", "B", "C"])
        rows.discardRowsKeepingMetadata()
        #expect(rows.rowLocators.isEmpty)
    }
}
