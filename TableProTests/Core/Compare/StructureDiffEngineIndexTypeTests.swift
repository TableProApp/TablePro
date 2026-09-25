//
//  StructureDiffEngineIndexTypeTests.swift
//  TableProTests
//
//  Compare & Sync over two indexes that differ only in their access method.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct StructureDiffEngineIndexTypeTests {
    private static let table = PluginTableInfo(name: "items", schema: "public", comment: nil)

    private static func snapshot(indexType: String) -> TableStructureSnapshot {
        TableStructureSnapshot.from(
            table: table,
            columns: [PluginColumnInfo(name: "a", dataType: "integer")],
            indexes: [PluginIndexInfo(name: "items_a", columns: ["a"], type: indexType)],
            foreignKeys: []
        )
    }

    /// Both used to be read as BTREE, so a bloom index on one side and a b-tree on the other compared
    /// as the same index and the sync script never rebuilt it.
    @Test("A bloom index and a b-tree over the same column are different indexes")
    func accessMethodIsADifference() {
        let result = StructureDiffEngine().compareTable(
            source: Self.snapshot(indexType: "bloom"),
            target: Self.snapshot(indexType: "btree")
        )
        #expect(result.changes.count == 2)
    }

    @Test("The same access method spelled in two cases is the same index")
    func caseIsNotADifference() {
        let result = StructureDiffEngine().compareTable(
            source: Self.snapshot(indexType: "spgist"),
            target: Self.snapshot(indexType: "SPGIST")
        )
        #expect(result.changes.isEmpty)
    }
}
