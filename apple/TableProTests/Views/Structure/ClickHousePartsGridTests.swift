//
//  ClickHousePartsGridTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct ClickHousePartsGridTests {
    private let part = ClickHousePartInfo(
        partition: "202601",
        partitionId: "202601",
        name: "202601_1_4_1",
        rows: 1_234_567,
        bytesOnDisk: 5_242_880,
        modificationTime: "2026-01-05 10:00:00",
        active: true
    )

    @Test("Each part fills the six columns the parts list has always shown")
    func rowCarriesEveryColumn() {
        let row = ClickHousePartsView.gridRow(for: part)

        #expect(ClickHousePartsView.columnTitles.count == row.values.count)
        #expect(row.id == part.id)
        #expect(row.values[0] == "202601")
        #expect(row.values[1] == "202601_1_4_1")
        #expect(row.values[2] == UInt64(1_234_567).formatted(.number.grouping(.automatic)))
        #expect(row.values[3] == ByteSizeFormatting.string(bytes: UInt64(5_242_880)))
        #expect(row.values[4] == "2026-01-05 10:00:00")
        #expect(row.values[5] == "YES")
    }

    @Test("An inactive part reads NO")
    func inactivePart() {
        let inactive = ClickHousePartInfo(
            partition: "", partitionId: "", name: "p", rows: 0, bytesOnDisk: 0, modificationTime: "", active: false
        )
        #expect(ClickHousePartsView.gridRow(for: inactive).values.last == "NO")
    }

    @Test("Active reads aloud as Active or Inactive rather than YES or NO")
    func activeIsSpokenByName() {
        let inactive = ClickHousePartInfo(
            partition: "", partitionId: "", name: "p", rows: 0, bytesOnDisk: 0, modificationTime: "", active: false
        )
        let active = ClickHousePartsView.activeColumn

        #expect(ClickHousePartsView.columnTitles[active] == String(localized: "Active"))
        #expect(ClickHousePartsView.gridRow(for: part).spokenValues == [active: String(localized: "Active")])
        #expect(ClickHousePartsView.gridRow(for: inactive).spokenValues == [active: String(localized: "Inactive")])
    }

    @Test("Each column keeps the minimum width the parts list has always given it")
    func minimumWidths() {
        #expect(ClickHousePartsView.columnMinimumWidths == [80, 100, 60, 60, 100, 50])
        #expect(ClickHousePartsView.columnMinimumWidths.count == ClickHousePartsView.columnTitles.count)
        #expect(zip(ClickHousePartsView.columnMinimumWidths, ClickHousePartsView.columnWidths).allSatisfy { $0 <= $1 })
    }

    @Test("Drop and Detach act on the one selected part, and on none while several are selected")
    func selectedPartition() {
        let other = ClickHousePartInfo(
            partition: "202602", partitionId: "202602", name: "202602_1_1_0", rows: 1, bytesOnDisk: 1,
            modificationTime: "", active: true
        )
        let parts = [part, other]

        #expect(ClickHousePartsView.selectedPart(of: [other.id], in: parts)?.id == other.id)
        #expect(ClickHousePartsView.selectedPart(of: [part.id, other.id], in: parts)?.id == nil)
        #expect(ClickHousePartsView.selectedPart(of: [], in: parts)?.id == nil)
        #expect(ClickHousePartsView.selectedPart(of: [UUID()], in: parts)?.id == nil)
    }

    @Test("A selected grid row names its own part")
    func selectedRowResolvesToItsPart() throws {
        let other = ClickHousePartInfo(
            partition: "202602", partitionId: "202602", name: "202602_1_1_0", rows: 1, bytesOnDisk: 1,
            modificationTime: "", active: true
        )
        let parts = [part, other]
        let grid = StructureListGridModel<UUID>()
        var selected: Set<UUID> = []
        grid.onSelect = { selected = $0 }
        grid.load(
            columns: ClickHousePartsView.columnTitles,
            rows: parts.map(ClickHousePartsView.gridRow(for:)),
            defaultWidths: ClickHousePartsView.columnWidths,
            minimumWidths: ClickHousePartsView.columnMinimumWidths,
            databaseType: .clickhouse,
            sortState: nil
        )
        let second = try #require(grid.model.rowID(at: 1))

        grid.model.selectRows([second])

        #expect(grid.id(for: second) == other.id)
        #expect(selected == [other.id])
        #expect(ClickHousePartsView.selectedPart(of: selected, in: parts)?.partition == "202602")
        #expect(grid.model.rowID(at: 2) == nil)
    }

    @Test("A parts row keeps the partition ID a statement names beside the value the grid shows")
    func rowCarriesThePartitionId() throws {
        let row: [PluginCellValue] = [
            "(202401,'eu')",
            "c1f8e6e2a7b04d4c9e1f0a2b3c4d5e6f",
            "c1f8e6e2a7b04d4c9e1f0a2b3c4d5e6f_1_1_0",
            "12",
            "4096",
            "2026-01-05 10:00:00",
            "1",
        ]

        let parsed = try #require(ClickHousePartsView.part(from: row))

        #expect(parsed.partition == "(202401,'eu')")
        #expect(parsed.partitionId == "c1f8e6e2a7b04d4c9e1f0a2b3c4d5e6f")
        #expect(parsed.name == "c1f8e6e2a7b04d4c9e1f0a2b3c4d5e6f_1_1_0")
        #expect(parsed.rows == 12)
        #expect(parsed.bytesOnDisk == 4096)
        #expect(parsed.modificationTime == "2026-01-05 10:00:00")
        #expect(parsed.active)
        #expect(ClickHousePartsView.gridRow(for: parsed).values[0] == "(202401,'eu')")
    }

    // The pane used to swap the list and its toolbar for the error text until the tab was refreshed.
    @Test("A refused or failed action keeps the parts list and its toolbar on screen")
    func actionFailureKeepsTheList() {
        var pane = ClickHousePartsPaneState()
        pane.beginLoad()
        pane.finishLoad([part])

        pane.actionEnded(.refused("Safe Mode is read-only"), title: "Couldn't Drop Partition")
        #expect(pane.display == .parts)
        #expect(pane.alert == ClickHousePartsAlert(title: "Couldn't Drop Partition", message: "Safe Mode is read-only"))

        pane.alert = nil
        pane.actionEnded(.failed("Wrong partition value"), title: "Couldn't Detach Partition")
        #expect(pane.display == .parts)
        #expect(pane.alert == ClickHousePartsAlert(title: "Couldn't Detach Partition", message: "Wrong partition value"))
    }

    @Test("A Cancel at the gate's confirmation shows nothing")
    func cancelIsQuiet() {
        var pane = ClickHousePartsPaneState()
        pane.finishLoad([part])

        pane.actionEnded(
            GatedOperationFailure(ExecutionGateError.cancelledByUser("Operation cancelled by user")),
            title: "Couldn't Drop Partition"
        )

        #expect(pane.alert == nil)
        #expect(pane.display == .parts)
    }

    @Test("A load that fails with nothing shown offers Try Again, and a reload that fails keeps the list")
    func loadFailure() {
        var pane = ClickHousePartsPaneState()
        #expect(pane.display == .loading)

        pane.failLoad("Connection refused")
        #expect(pane.display == .loadFailed("Connection refused"))
        #expect(pane.alert == nil)

        pane.beginLoad()
        #expect(pane.display == .loading)
        pane.finishLoad([])
        #expect(pane.display == .empty)

        pane.finishLoad([part])
        pane.beginLoad()
        #expect(pane.display == .parts)
        pane.failLoad("Timeout exceeded")
        #expect(pane.display == .parts)
        #expect(pane.alert?.message == "Timeout exceeded")
    }
}
