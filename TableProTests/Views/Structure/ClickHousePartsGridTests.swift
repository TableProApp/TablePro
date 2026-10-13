//
//  ClickHousePartsGridTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct ClickHousePartsGridTests {
    private let part = ClickHousePartInfo(
        partition: "202601",
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
            partition: "", name: "p", rows: 0, bytesOnDisk: 0, modificationTime: "", active: false
        )
        #expect(ClickHousePartsView.gridRow(for: inactive).values.last == "NO")
    }

    @Test("A selected grid row names its own part")
    func selectedRowResolvesToItsPart() {
        let other = ClickHousePartInfo(
            partition: "202602", name: "202602_1_1_0", rows: 1, bytesOnDisk: 1, modificationTime: "", active: true
        )
        let parts = [part, other]
        let grid = StructureListGridModel<UUID>()
        _ = grid.ensureLoaded(key: 1, columns: ClickHousePartsView.columnTitles) {
            parts.map(ClickHousePartsView.gridRow(for:))
        }

        #expect(grid.id(atDisplayRow: 1) == other.id)
        #expect(grid.id(atDisplayRow: 2) == nil)
    }
}
