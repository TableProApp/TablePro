//
//  SidebarPartitionRowTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("What a partition row and its parent say")
struct SidebarPartitionRowTests {
    @Test("A table the engine says nothing about shows no count, and an empty parent shows zero")
    func countLabelSeparatesUnknownFromEmpty() {
        #expect(SidebarPartitionRow.countLabel(partitionCount: nil) == nil)
        #expect(SidebarPartitionRow.countLabel(partitionCount: 0) == "0")
        #expect(SidebarPartitionRow.countLabel(partitionCount: 12) == "12")
    }

    @Test("The bound is the caption where there is one")
    func captionPrefersBound() {
        #expect(
            SidebarPartitionRow.caption(bound: "FROM ('2024-01-01') TO ('2024-02-01')", ordinalPosition: 3)
                == "FROM ('2024-01-01') TO ('2024-02-01')"
        )
    }

    @Test("An engine that states no bound falls back to the position that orders its partitions")
    func captionFallsBackToPosition() {
        #expect(SidebarPartitionRow.caption(bound: nil, ordinalPosition: 3) == "Partition 3")
        #expect(SidebarPartitionRow.caption(bound: "   ", ordinalPosition: 1) == "Partition 1")
    }

    @Test("A partition with neither a bound nor a position says nothing beside its name")
    func captionCanBeAbsent() {
        #expect(SidebarPartitionRow.caption(bound: nil, ordinalPosition: nil) == nil)
    }

    @Test("VoiceOver hears the partition, then what distinguishes it")
    func accessibilityLabelComposes() {
        #expect(
            SidebarPartitionRow.accessibilityLabel(name: "events_2024_01", bound: "DEFAULT", ordinalPosition: nil)
                == "Partition: events_2024_01, DEFAULT"
        )
        #expect(
            SidebarPartitionRow.accessibilityLabel(name: "p0", bound: nil, ordinalPosition: nil)
                == "Partition: p0"
        )
    }

    @Test("A partitioned table's own label carries how many it holds")
    func tableLabelCarriesCount() {
        let table = TableInfo(
            name: "events",
            type: .partitionedTable,
            rowCount: nil,
            schema: "public",
            comment: nil,
            partitionCount: 3
        )
        let label = TableRowLogic.accessibilityLabel(
            table: table,
            isPendingDelete: false,
            isPendingTruncate: false
        )

        #expect(label.contains("events"))
        #expect(label.contains("3 partitions"))
    }

    @Test("A table the engine reports no count for gains no partition clause")
    func tableLabelOmitsAbsentCount() {
        let table = TableInfo(name: "orders", type: .table, rowCount: nil, schema: "public")
        let label = TableRowLogic.accessibilityLabel(
            table: table,
            isPendingDelete: false,
            isPendingTruncate: false
        )

        #expect(!label.contains("partitions"))
    }
}

@Suite("A refresh notices a partition count that moved on its own")
struct PartitionCountRefreshTests {
    private func table(_ name: String, partitionCount: Int?) -> TableInfo {
        TableInfo(
            name: name,
            type: .partitionedTable,
            rowCount: nil,
            schema: "public",
            comment: nil,
            partitionCount: partitionCount
        )
    }

    /// `TableInfo` identity deliberately ignores the count, so the equality guard on the refresh
    /// commit cannot see one change on its own. Another client adding a partition moves nothing
    /// else about the table.
    @Test("The same tables with a different count count as changed")
    func countAloneIsAChange() {
        let before: MetadataLoadState<[TableInfo]> = .loaded([table("events", partitionCount: 3)])
        let after: MetadataLoadState<[TableInfo]> = .loaded([table("events", partitionCount: 4)])

        #expect(before == after)
        #expect(DatabaseTreeMetadataService.partitionCountsChanged(from: before, to: after))
    }

    @Test("An unchanged count is not a change")
    func identicalCountsAreNotAChange() {
        let before: MetadataLoadState<[TableInfo]> = .loaded([table("events", partitionCount: 3)])
        let after: MetadataLoadState<[TableInfo]> = .loaded([table("events", partitionCount: 3)])

        #expect(!DatabaseTreeMetadataService.partitionCountsChanged(from: before, to: after))
    }

    @Test("A first load is a change, and a failed refresh is not")
    func absentAndFailedStates() {
        let loaded: MetadataLoadState<[TableInfo]> = .loaded([table("events", partitionCount: 1)])

        #expect(DatabaseTreeMetadataService.partitionCountsChanged(from: nil, to: loaded))
        #expect(!DatabaseTreeMetadataService.partitionCountsChanged(from: loaded, to: .failed("boom")))
    }
}
