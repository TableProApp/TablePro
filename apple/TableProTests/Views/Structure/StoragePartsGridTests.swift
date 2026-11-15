//
//  StoragePartsGridTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct StoragePartsGridTests {
    private let part = PluginStoragePart(
        partition: "202601",
        partitionId: "202601",
        name: "202601_1_4_1",
        rows: 1_234_567,
        bytesOnDisk: 5_242_880,
        modificationTime: "2026-01-05 10:00:00",
        isActive: true
    )

    @Test("Each part fills the six columns the parts list has always shown")
    func rowCarriesEveryColumn() {
        let row = StoragePartsView.gridRow(for: part)

        #expect(StoragePartsView.columnTitles.count == row.values.count)
        #expect(row.id == part.name)
        #expect(row.values[0] == "202601")
        #expect(row.values[1] == "202601_1_4_1")
        #expect(row.values[2] == UInt64(1_234_567).formatted(.number.grouping(.automatic)))
        #expect(row.values[3] == ByteSizeFormatting.string(bytes: UInt64(5_242_880)))
        #expect(row.values[4] == "2026-01-05 10:00:00")
        #expect(row.values[5] == "YES")
    }

    @Test("An inactive part reads NO")
    func inactivePart() {
        let inactive = PluginStoragePart(
            partition: "", partitionId: "", name: "p", rows: 0, bytesOnDisk: 0, modificationTime: "", isActive: false
        )
        #expect(StoragePartsView.gridRow(for: inactive).values.last == "NO")
    }

    @Test("Active reads aloud as Active or Inactive rather than YES or NO")
    func activeIsSpokenByName() {
        let inactive = PluginStoragePart(
            partition: "", partitionId: "", name: "p", rows: 0, bytesOnDisk: 0, modificationTime: "", isActive: false
        )
        let active = StoragePartsView.activeColumn

        #expect(StoragePartsView.columnTitles[active] == String(localized: "Active"))
        #expect(StoragePartsView.gridRow(for: part).spokenValues == [active: String(localized: "Active")])
        #expect(StoragePartsView.gridRow(for: inactive).spokenValues == [active: String(localized: "Inactive")])
    }

    @Test("Each column keeps the minimum width the parts list has always given it")
    func minimumWidths() {
        #expect(StoragePartsView.columnMinimumWidths == [80, 100, 60, 60, 100, 50])
        #expect(StoragePartsView.columnMinimumWidths.count == StoragePartsView.columnTitles.count)
        #expect(zip(StoragePartsView.columnMinimumWidths, StoragePartsView.columnWidths).allSatisfy { $0 <= $1 })
    }

    @Test("Drop and Detach act on the one selected part, and on none while several are selected")
    func selectedPartition() {
        let other = PluginStoragePart(
            partition: "202602", partitionId: "202602", name: "202602_1_1_0", rows: 1, bytesOnDisk: 1,
            modificationTime: "", isActive: true
        )
        let parts = [part, other]

        #expect(StoragePartsView.selectedPart(of: [other.name], in: parts)?.name == other.name)
        #expect(StoragePartsView.selectedPart(of: [part.name, other.name], in: parts) == nil)
        #expect(StoragePartsView.selectedPart(of: [], in: parts) == nil)
        #expect(StoragePartsView.selectedPart(of: ["missing"], in: parts) == nil)
    }

    @Test("A selected grid row names its own part")
    func selectedRowResolvesToItsPart() throws {
        let other = PluginStoragePart(
            partition: "202602", partitionId: "202602", name: "202602_1_1_0", rows: 1, bytesOnDisk: 1,
            modificationTime: "", isActive: true
        )
        let parts = [part, other]
        let grid = StructureListGridModel<String>()
        var selected: Set<String> = []
        grid.onSelect = { selected = $0 }
        grid.load(
            columns: StoragePartsView.columnTitles,
            rows: parts.map(StoragePartsView.gridRow(for:)),
            defaultWidths: StoragePartsView.columnWidths,
            minimumWidths: StoragePartsView.columnMinimumWidths,
            databaseType: .clickhouse,
            sortState: nil
        )
        let second = try #require(grid.model.rowID(at: 1))

        grid.model.selectRows([second])

        #expect(grid.id(for: second) == other.name)
        #expect(selected == [other.name])
        #expect(StoragePartsView.selectedPart(of: selected, in: parts)?.partition == "202602")
        #expect(grid.model.rowID(at: 2) == nil)
    }

    // The pane used to swap the list and its toolbar for the error text until the tab was refreshed.
    @Test("A refused or failed action keeps the parts list and its toolbar on screen")
    func actionFailureKeepsTheList() {
        var pane = StoragePartsPaneState()
        pane.beginLoad()
        pane.finishLoad([part])

        pane.actionEnded(.refused("Safe Mode is read-only"), title: "Couldn't Drop Partition")
        #expect(pane.display == .parts)
        #expect(pane.alert == StoragePartsAlert(title: "Couldn't Drop Partition", message: "Safe Mode is read-only"))

        pane.alert = nil
        pane.actionEnded(.failed("Wrong partition value"), title: "Couldn't Detach Partition")
        #expect(pane.display == .parts)
        #expect(pane.alert == StoragePartsAlert(title: "Couldn't Detach Partition", message: "Wrong partition value"))
    }

    @Test("A Cancel at the gate's confirmation shows nothing")
    func cancelIsQuiet() {
        var pane = StoragePartsPaneState()
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
        var pane = StoragePartsPaneState()
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
