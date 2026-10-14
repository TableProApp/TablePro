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

struct ColumnLayoutStateTests {
    // MARK: - applyGeometry

    @Test("Applying geometry updates widths and order")
    func applyGeometryUpdatesWidthsAndOrder() {
        var layout = ColumnLayoutState()
        layout.columnWidths = ["id": 60]
        layout.columnOrder = ["id"]

        var incoming = ColumnLayoutState()
        incoming.columnWidths = ["id": 120, "name": 200]
        incoming.columnContentWidths = ["id": 112, "name": 192]
        incoming.columnOrder = ["name", "id"]

        layout.applyGeometry(from: incoming)

        #expect(layout.columnWidths == ["id": 120, "name": 200])
        #expect(layout.columnContentWidths == ["id": 112, "name": 192])
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
