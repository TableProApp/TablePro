import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("TabSessionRegistry+TableRows")
@MainActor
struct TabSessionRegistryTableRowsTests {
    @Test("tableRows(for:) returns empty TableRows on first access without creating a session")
    func tableRowsCreatesAndReturnsSameValue() {
        let store = TabSessionRegistry()
        let tabId = UUID()

        let first = store.tableRows(for: tabId)
        #expect(first.rows.isEmpty)
        #expect(first.columns.isEmpty)
        #expect(store.isEvicted(tabId) == false)

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

    @Test("removeTableRows(for:) deletes the entry and clears evicted state")
    func removeTableRowsDeletes() {
        let store = TabSessionRegistry()
        let tabId = UUID()

        store.setTableRows(
            TableRows.from(queryRows: [["x"]], columns: ["c"], columnTypes: [.text(rawType: nil)]),
            for: tabId
        )
        store.evict(for: tabId)
        #expect(store.isEvicted(tabId) == true)

        store.removeTableRows(for: tabId)
        #expect(store.existingTableRows(for: tabId) == nil)
        #expect(store.isEvicted(tabId) == false)
    }

    @Test("evict(for:) clears rows and marks evicted while preserving columns")
    func evictMarksEvicted() {
        let store = TabSessionRegistry()
        let tabId = UUID()
        let rows = TableRows.from(
            queryRows: [["a"], ["b"]],
            columns: ["c"],
            columnTypes: [.text(rawType: nil)]
        )
        store.setTableRows(rows, for: tabId)

        #expect(store.isEvicted(tabId) == false)
        store.evict(for: tabId)

        #expect(store.isEvicted(tabId) == true)
        let evicted = store.existingTableRows(for: tabId)
        #expect(evicted?.rows.isEmpty == true)
        #expect(evicted?.columns == ["c"])
    }

    @Test("evict(for:) is no-op for unknown tab")
    func evictUnknownTabIsNoOp() {
        let store = TabSessionRegistry()
        store.evict(for: UUID())
    }

    @Test("evictAll(except:) evicts other tabs and spares the active one")
    func evictAllSparesActive() {
        let store = TabSessionRegistry()
        let activeId = UUID()
        let otherId1 = UUID()
        let otherId2 = UUID()

        let active = TableRows.from(queryRows: [["a"]], columns: ["c"], columnTypes: [.text(rawType: nil)])
        let other1 = TableRows.from(queryRows: [["b"]], columns: ["c"], columnTypes: [.text(rawType: nil)])
        let other2 = TableRows.from(queryRows: [["d"]], columns: ["c"], columnTypes: [.text(rawType: nil)])

        store.setTableRows(active, for: activeId)
        store.setTableRows(other1, for: otherId1)
        store.setTableRows(other2, for: otherId2)

        store.evictAll(except: activeId)

        #expect(store.isEvicted(activeId) == false)
        #expect(store.existingTableRows(for: activeId)?.rows.count == 1)
        #expect(store.isEvicted(otherId1) == true)
        #expect(store.existingTableRows(for: otherId1)?.rows.isEmpty == true)
        #expect(store.isEvicted(otherId2) == true)
    }

    @Test("evictAll(except: nil) evicts every loaded tab")
    func evictAllNoActiveEvictsAll() {
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

        store.evictAll(except: nil)

        #expect(store.isEvicted(id1) == true)
        #expect(store.isEvicted(id2) == true)
    }

    @Test("evictAll(except:) skips empty tables")
    func evictAllSkipsEmpty() {
        let store = TabSessionRegistry()
        let tabId = UUID()
        store.setTableRows(TableRows(), for: tabId)

        store.evictAll(except: nil)
        #expect(store.isEvicted(tabId) == false)
    }

    @Test("setTableRows clears evicted flag")
    func setClearsEvicted() {
        let store = TabSessionRegistry()
        let tabId = UUID()
        store.setTableRows(
            TableRows.from(queryRows: [["a"]], columns: ["c"], columnTypes: [.text(rawType: nil)]),
            for: tabId
        )
        store.evict(for: tabId)
        #expect(store.isEvicted(tabId) == true)

        store.setTableRows(
            TableRows.from(queryRows: [["b"]], columns: ["c"], columnTypes: [.text(rawType: nil)]),
            for: tabId
        )
        #expect(store.isEvicted(tabId) == false)
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
            _ = rows.edit(row: 0, column: 0, value: "z")
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
