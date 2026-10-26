import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct TabSessionRegistryTableRowsTests {
    @Test("tableRows(for:) returns empty TableRows on first access without creating a session")
    func tableRowsCreatesAndReturnsSameValue() {
        let store = TabSessionRegistry()
        let tabId = UUID()

        let first = store.tableRows(for: tabId)
        #expect(first.rows.isEmpty)
        #expect(first.columns.isEmpty)

        let second = store.tableRows(for: tabId)
        #expect(second.rows.count == first.rows.count)
        #expect(second.columns == first.columns)
    }

    @Test("setTableRows(_:for:) replaces stored value")
    func setTableRowsReplacesEntry() {
        let store = TabSessionRegistry()
        let tabId = UUID()

        _ = store.tableRows(for: tabId)
        let replacement = TableRows.from(
            queryRows: [["a"]],
            columns: ["c"],
            columnTypes: [.text(rawType: nil)]
        )
        store.setTableRows(replacement, for: tabId)

        let resolved = store.tableRows(for: tabId)
        #expect(resolved.rows.count == 1)
        #expect(resolved.columns == ["c"])
    }

    @Test("existingTableRows(for:) returns nil before set and value after")
    func existingTableRowsReflectsState() {
        let store = TabSessionRegistry()
        let tabId = UUID()

        #expect(store.existingTableRows(for: tabId) == nil)

        let rows = TableRows.from(
            queryRows: [["x"]],
            columns: ["c"],
            columnTypes: [.text(rawType: nil)]
        )
        store.setTableRows(rows, for: tabId)

        let resolved = store.existingTableRows(for: tabId)
        #expect(resolved != nil)
        #expect(resolved?.rows.count == 1)
    }

    @Test("removeTableRows(for:) deletes the entry")
    func removeTableRowsDeletes() {
        let store = TabSessionRegistry()
        let tabId = UUID()

        store.setTableRows(
            TableRows.from(queryRows: [["x"]], columns: ["c"], columnTypes: [.text(rawType: nil)]),
            for: tabId
        )

        store.removeTableRows(for: tabId)
        #expect(store.existingTableRows(for: tabId) == nil)
    }

    @Test("updateTableRows applies mutation in place")
    func updateTableRowsAppliesMutation() {
        let store = TabSessionRegistry()
        let tabId = UUID()
        store.setTableRows(
            TableRows.from(queryRows: [["a"]], columns: ["c"], columnTypes: [.text(rawType: nil)]),
            for: tabId
        )

        store.updateTableRows(for: tabId) { rows in
            rows.edit(row: 0, column: 0, value: "z")
        }

        let resolved = store.existingTableRows(for: tabId)
        #expect(resolved?.value(at: 0, column: 0) == "z")
    }

    @Test("removing one tab leaves siblings intact")
    func closingTabRemovesOnlyThatEntry() {
        let store = TabSessionRegistry()
        let tabId1 = UUID()
        let tabId2 = UUID()

        store.setTableRows(
            TableRows.from(queryRows: [["a"]], columns: ["c"], columnTypes: [.text(rawType: nil)]),
            for: tabId1
        )
        store.setTableRows(
            TableRows.from(queryRows: [["b"]], columns: ["c"], columnTypes: [.text(rawType: nil)]),
            for: tabId2
        )

        store.removeTableRows(for: tabId1)

        #expect(store.existingTableRows(for: tabId1) == nil)
        #expect(store.existingTableRows(for: tabId2)?.rows.count == 1)
    }

    @Test("removeAll() clears the registry")
    func removeAllClearsAll() {
        let store = TabSessionRegistry()
        let id1 = UUID()
        let id2 = UUID()
        store.setTableRows(
            TableRows.from(queryRows: [["a"]], columns: ["c"], columnTypes: [.text(rawType: nil)]),
            for: id1
        )
        store.setTableRows(
            TableRows.from(queryRows: [["b"]], columns: ["c"], columnTypes: [.text(rawType: nil)]),
            for: id2
        )

        store.removeAll()

        #expect(store.existingTableRows(for: id1) == nil)
        #expect(store.existingTableRows(for: id2) == nil)
    }
}
