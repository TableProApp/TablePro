//
//  ColumnLayoutStateTests.swift
//  TableProTests
//
//  Tests for ColumnLayoutState value type.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("ColumnLayoutState")
struct ColumnLayoutStateTests {
    @Test("Default has empty widths")
    func defaultEmptyWidths() {
        let state = ColumnLayoutState()
        #expect(state.columnWidths.isEmpty)
    }

    @Test("Default has nil column order")
    func defaultNilOrder() {
        let state = ColumnLayoutState()
        #expect(state.columnOrder == nil)
    }

    @Test("Stores column widths")
    func storesWidths() {
        let state = ColumnLayoutState(columnWidths: ["name": 120.0, "email": 200.0])
        #expect(state.columnWidths["name"] == 120.0)
        #expect(state.columnWidths["email"] == 200.0)
    }

    @Test("Stores column order")
    func storesOrder() {
        let state = ColumnLayoutState(columnOrder: ["id", "name", "email"])
        #expect(state.columnOrder == ["id", "name", "email"])
    }

    @Test("Equal states are equal")
    func equalStates() {
        let a = ColumnLayoutState(columnWidths: ["id": 50.0], columnOrder: ["id"])
        let b = ColumnLayoutState(columnWidths: ["id": 50.0], columnOrder: ["id"])
        #expect(a == b)
    }

    @Test("Different widths produces unequal states")
    func differentWidths() {
        let a = ColumnLayoutState(columnWidths: ["id": 50.0])
        let b = ColumnLayoutState(columnWidths: ["id": 100.0])
        #expect(a != b)
    }

    @Test("Different order produces unequal states")
    func differentOrder() {
        let a = ColumnLayoutState(columnOrder: ["id", "name"])
        let b = ColumnLayoutState(columnOrder: ["name", "id"])
        #expect(a != b)
    }

    @Test("nil vs empty order are not equal")
    func nilVsEmptyOrder() {
        let a = ColumnLayoutState(columnOrder: nil)
        let b = ColumnLayoutState(columnOrder: [])
        #expect(a != b)
    }

    // MARK: - hiddenColumns

    @Test("Default hiddenColumns is empty")
    func defaultHiddenColumnsEmpty() {
        let state = ColumnLayoutState()
        #expect(state.hiddenColumns.isEmpty)
    }

    @Test("Same hiddenColumns produces equal states")
    func sameHiddenColumnsEqual() {
        let a = ColumnLayoutState(hiddenColumns: ["name", "email"])
        let b = ColumnLayoutState(hiddenColumns: ["name", "email"])
        #expect(a == b)
    }

    @Test("Different hiddenColumns produces unequal states")
    func differentHiddenColumnsNotEqual() {
        let a = ColumnLayoutState(hiddenColumns: ["name"])
        let b = ColumnLayoutState(hiddenColumns: ["email"])
        #expect(a != b)
    }

    @Test("Same widths with different hiddenColumns are not equal")
    func sameWidthsDifferentHiddenColumnsNotEqual() {
        let a = ColumnLayoutState(columnWidths: ["id": 50.0], hiddenColumns: ["name"])
        let b = ColumnLayoutState(columnWidths: ["id": 50.0], hiddenColumns: ["email"])
        #expect(a != b)
    }

    @Test("Setting hiddenColumns stores and retrieves values")
    func setAndReadHiddenColumns() {
        var state = ColumnLayoutState()
        state.hiddenColumns = ["id", "created_at"]
        #expect(state.hiddenColumns == ["id", "created_at"])
        #expect(state.hiddenColumns.contains("id"))
        #expect(state.hiddenColumns.contains("created_at"))
        #expect(!state.hiddenColumns.contains("name"))
    }

    // MARK: - applyGeometry

    @Test("Applying geometry updates widths and order")
    func applyGeometryUpdatesWidthsAndOrder() {
        var layout = ColumnLayoutState()
        layout.columnWidths = ["id": 60]
        layout.columnOrder = ["id"]

        var incoming = ColumnLayoutState()
        incoming.columnWidths = ["id": 120, "name": 200]
        incoming.columnOrder = ["name", "id"]

        layout.applyGeometry(from: incoming)

        #expect(layout.columnWidths == ["id": 120, "name": 200])
        #expect(layout.columnOrder == ["name", "id"])
    }

    @Test("Applying geometry preserves the existing hidden-column set")
    func applyGeometryPreservesHiddenColumns() {
        var layout = ColumnLayoutState()
        layout.hiddenColumns = ["secret", "internal_id"]

        var incoming = ColumnLayoutState()
        incoming.columnWidths = ["id": 120]
        incoming.columnOrder = ["id"]

        layout.applyGeometry(from: incoming)

        #expect(layout.hiddenColumns == ["secret", "internal_id"])
    }

    @Test("Applying geometry ignores the incoming hidden-column set")
    func applyGeometryIgnoresIncomingHiddenColumns() {
        var layout = ColumnLayoutState()
        layout.hiddenColumns = ["secret"]

        var incoming = ColumnLayoutState()
        incoming.columnWidths = ["id": 120]
        incoming.hiddenColumns = []

        layout.applyGeometry(from: incoming)

        #expect(layout.hiddenColumns == ["secret"])
    }

    // MARK: - mergingWidths

    @Test("Merging live widths overrides saved widths and adds new ones")
    func mergingWidthsOverridesAndAdds() {
        var saved = ColumnLayoutState()
        saved.columnWidths = ["id": 60, "name": 200]
        saved.columnOrder = ["id", "name"]
        saved.hiddenColumns = ["secret"]

        let merged = saved.mergingWidths(["name": 320, "email": 240])

        #expect(merged.columnWidths == ["id": 60, "name": 320, "email": 240])
        #expect(merged.columnOrder == ["id", "name"])
        #expect(merged.hiddenColumns == ["secret"])
    }

    @Test("Merging an empty live width map leaves the layout unchanged")
    func mergingEmptyWidthsIsNoOp() {
        var saved = ColumnLayoutState()
        saved.columnWidths = ["id": 60]

        let merged = saved.mergingWidths([:])

        #expect(merged.columnWidths == ["id": 60])
    }
}
