//
//  ColumnVisibilityManagerTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("ColumnVisibilityManager")
@MainActor
struct ColumnVisibilityManagerTests {
    @Test("Initial state has no hidden columns")
    func initialState() {
        let manager = ColumnVisibilityManager()
        #expect(manager.hiddenColumns.isEmpty)
        #expect(!manager.hasHiddenColumns)
        #expect(manager.hiddenCount == 0)
    }

    @Test("hideColumn adds column to hidden set")
    func hideColumn() {
        let manager = ColumnVisibilityManager()
        manager.hideColumn("name")
        #expect(manager.hiddenColumns.contains("name"))
        #expect(manager.hiddenCount == 1)
    }

    @Test("showColumn removes column from hidden set")
    func showColumn() {
        let manager = ColumnVisibilityManager()
        manager.hideColumn("name")
        manager.showColumn("name")
        #expect(!manager.hiddenColumns.contains("name"))
        #expect(manager.hiddenCount == 0)
    }

    @Test("toggleColumn hides visible column and shows hidden column")
    func toggleColumn() {
        let manager = ColumnVisibilityManager()

        manager.toggleColumn("name")
        #expect(manager.hiddenColumns.contains("name"))

        manager.toggleColumn("name")
        #expect(!manager.hiddenColumns.contains("name"))
    }

    @Test("showAll clears all hidden columns")
    func showAll() {
        let manager = ColumnVisibilityManager()
        manager.hideColumn("a")
        manager.hideColumn("b")
        manager.hideColumn("c")

        manager.showAll()
        #expect(manager.hiddenColumns.isEmpty)
        #expect(manager.hiddenCount == 0)
    }

    @Test("hideAll hides all given columns")
    func hideAll() {
        let manager = ColumnVisibilityManager()
        manager.hideAll(["a", "b", "c"])
        #expect(manager.hiddenColumns == Set(["a", "b", "c"]))
        #expect(manager.hiddenCount == 3)
    }

    @Test("hideAll then showAll round-trip")
    func hideAllThenShowAll() {
        let manager = ColumnVisibilityManager()
        manager.hideAll(["x", "y", "z"])
        #expect(manager.hasHiddenColumns)

        manager.showAll()
        #expect(!manager.hasHiddenColumns)
        #expect(manager.hiddenColumns.isEmpty)
    }

    @Test("hasHiddenColumns reflects state correctly")
    func hasHiddenColumns() {
        let manager = ColumnVisibilityManager()
        #expect(!manager.hasHiddenColumns)

        manager.hideColumn("id")
        #expect(manager.hasHiddenColumns)

        manager.showColumn("id")
        #expect(!manager.hasHiddenColumns)
    }

    @Test("hiddenCount returns correct count")
    func hiddenCount() {
        let manager = ColumnVisibilityManager()
        #expect(manager.hiddenCount == 0)

        manager.hideColumn("a")
        #expect(manager.hiddenCount == 1)

        manager.hideColumn("b")
        #expect(manager.hiddenCount == 2)

        manager.showColumn("a")
        #expect(manager.hiddenCount == 1)
    }

    @Test("saveToColumnLayout and restoreFromColumnLayout round-trip")
    func columnLayoutRoundTrip() {
        let manager = ColumnVisibilityManager()
        manager.hideColumn("col1")
        manager.hideColumn("col2")

        let saved = manager.saveToColumnLayout()

        let other = ColumnVisibilityManager()
        other.restoreFromColumnLayout(saved)
        #expect(other.hiddenColumns == Set(["col1", "col2"]))
    }

    @Test("restoreFromColumnLayout replaces state instead of merging")
    func restoreReplacesState() {
        let manager = ColumnVisibilityManager()
        manager.hideColumn("existing")

        manager.restoreFromColumnLayout(Set(["new1", "new2"]))
        #expect(manager.hiddenColumns == Set(["new1", "new2"]))
        #expect(!manager.hiddenColumns.contains("existing"))
    }

    @Test("pruneStaleColumns removes columns not in current set")
    func pruneStaleColumns() {
        let manager = ColumnVisibilityManager()
        manager.hideAll(["a", "b", "c", "d"])

        manager.pruneStaleColumns(["b", "d", "e"])
        #expect(manager.hiddenColumns == Set(["b", "d"]))
    }

    @Test("pruneStaleColumns with empty current columns clears all hidden")
    func pruneStaleColumnsEmptyCurrent() {
        let manager = ColumnVisibilityManager()
        manager.hideAll(["a", "b", "c"])

        manager.pruneStaleColumns([])
        #expect(manager.hiddenColumns.isEmpty)
    }

    @Test("pruneStaleColumns with no stale columns keeps all hidden")
    func pruneStaleColumnsNoStale() {
        let manager = ColumnVisibilityManager()
        manager.hideAll(["a", "b"])

        manager.pruneStaleColumns(["a", "b", "c"])
        #expect(manager.hiddenColumns == Set(["a", "b"]))
    }

    @Test("UserDefaults round-trip for saveLastHiddenColumns and restoreLastHiddenColumns")
    func userDefaultsRoundTrip() {
        let tableName = "test_table_\(UUID().uuidString)"
        let connectionId = UUID()
        let key = "com.TablePro.columns.hiddenColumns.\(connectionId.uuidString).\(tableName)"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let manager = ColumnVisibilityManager()
        manager.hideAll(["col1", "col2", "col3"])
        manager.saveLastHiddenColumns(for: tableName, connectionId: connectionId)

        let other = ColumnVisibilityManager()
        other.restoreLastHiddenColumns(for: tableName, connectionId: connectionId)
        #expect(other.hiddenColumns == Set(["col1", "col2", "col3"]))
    }

    @Test("restoreLastHiddenColumns with no saved data resets to empty")
    func restoreWithNoSavedData() {
        let tableName = "nonexistent_table_\(UUID().uuidString)"
        let connectionId = UUID()
        let key = "com.TablePro.columns.hiddenColumns.\(connectionId.uuidString).\(tableName)"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let manager = ColumnVisibilityManager()
        manager.hideColumn("leftover")

        manager.restoreLastHiddenColumns(for: tableName, connectionId: connectionId)
        #expect(manager.hiddenColumns.isEmpty)
    }

    @Test("hideColumn is idempotent when hiding same column twice")
    func hideColumnIdempotent() {
        let manager = ColumnVisibilityManager()
        manager.hideColumn("name")
        manager.hideColumn("name")
        #expect(manager.hiddenCount == 1)
        #expect(manager.hiddenColumns.contains("name"))
    }

    @Test("showColumn on non-hidden column is a no-op")
    func showColumnNonHidden() {
        let manager = ColumnVisibilityManager()
        manager.showColumn("nonexistent")
        #expect(manager.hiddenColumns.isEmpty)
        #expect(manager.hiddenCount == 0)
    }
}
