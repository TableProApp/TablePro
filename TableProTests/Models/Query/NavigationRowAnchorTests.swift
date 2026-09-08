//
//  NavigationRowAnchorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("NavigationRowAnchor")
struct NavigationRowAnchorTests {
    private let columns = ["id", "region", "name"]
    private let values: ContiguousArray<PluginCellValue> = [.text("42"), .text("eu"), .text("Ada")]

    private func anchor(
        keyColumns: [String],
        modified: Set<Int> = []
    ) -> [String: String]? {
        NavigationRowAnchor.build(
            keyColumns: keyColumns,
            columns: columns,
            values: values,
            isModified: { modified.contains($0) }
        )
    }

    @Test("A clean key anchors on its value")
    func cleanKeyAnchors() {
        #expect(anchor(keyColumns: ["id"]) == ["id": "42"])
    }

    @Test("Every column of a composite key is carried")
    func compositeKeyAnchors() {
        #expect(anchor(keyColumns: ["id", "region"]) == ["id": "42", "region": "eu"])
    }

    /// The defect this type exists for. `TableRows` holds the edited value while the change is
    /// staged, and discarding clears the record without restoring the original, so a key taken from
    /// it names a row that was never saved.
    @Test("A staged edit to the key anchors nothing")
    func stagedKeyEditRefusesToAnchor() {
        #expect(anchor(keyColumns: ["id"], modified: [0]) == nil)
    }

    /// One edited column of a composite key poisons the whole anchor, because the restore matches
    /// on all of them together.
    @Test("A staged edit to one column of a composite key anchors nothing")
    func stagedEditToOneKeyColumnRefuses() {
        #expect(anchor(keyColumns: ["id", "region"], modified: [1]) == nil)
    }

    /// An edit somewhere else on the same row is not the key, so it does not disturb the anchor.
    @Test("A staged edit outside the key still anchors")
    func stagedEditOutsideTheKeyAnchors() {
        #expect(anchor(keyColumns: ["id"], modified: [2]) == ["id": "42"])
    }

    @Test("A table with no primary key anchors nothing")
    func noKeyColumnsAnchorsNothing() {
        #expect(anchor(keyColumns: []) == nil)
    }

    @Test("A key column the result does not carry anchors nothing")
    func absentKeyColumnAnchorsNothing() {
        #expect(anchor(keyColumns: ["tenant_id"]) == nil)
    }

    /// A NULL key cannot be matched on the way back, so it is not an anchor either.
    @Test("A key with no text value anchors nothing")
    func nullKeyAnchorsNothing() {
        let result = NavigationRowAnchor.build(
            keyColumns: ["id"],
            columns: columns,
            values: [.null, .text("eu"), .text("Ada")],
            isModified: { _ in false }
        )

        #expect(result == nil)
    }

    /// A row shorter than the column list is malformed rather than anchorable, and indexing it
    /// would trap.
    @Test("A row shorter than its columns anchors nothing")
    func shortRowAnchorsNothing() {
        let result = NavigationRowAnchor.build(
            keyColumns: ["name"],
            columns: columns,
            values: [.text("42")],
            isModified: { _ in false }
        )

        #expect(result == nil)
    }
}
