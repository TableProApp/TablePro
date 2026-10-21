//
//  DashboardTileDisplayTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct DashboardTileDisplayTests {
    private func columns(_ types: [(String, ColumnType)]) -> [ResultChartColumn] {
        ResultChartColumn.columns(in: TableRows(columns: types.map(\.0), columnTypes: types.map(\.1)))
    }

    @Test("One row of one column is a single value")
    func singleValue() {
        let shape = DashboardTileShape.of(
            columns: columns([("count", .integer(rawType: nil))]),
            rowCount: 1,
            chartsAvailable: true
        )
        #expect(shape == .value)
    }

    @Test("A time column followed by a number is a line chart of that number")
    func seriesOverTime() throws {
        let shape = DashboardTileShape.of(
            columns: columns([
                ("hour", .timestamp(rawType: nil)), ("queue", .text(rawType: nil)), ("lag", .decimal(rawType: nil)),
            ]),
            rowCount: 24,
            chartsAvailable: true
        )
        guard case .lineChart(let configuration) = shape else {
            Issue.record("Expected a line chart, got \(shape)")
            return
        }
        #expect(configuration.chartType == .line)
        #expect(configuration.xColumn?.name == "hour")
        #expect(configuration.yColumn.name == "lag")
    }

    @Test("Anything else is a table", arguments: [
        ([("id", ColumnType.integer(rawType: nil)), ("count", .integer(rawType: nil))], 5),
        ([("hour", ColumnType.timestamp(rawType: nil)), ("count", .integer(rawType: nil))], 1),
        ([("hour", ColumnType.timestamp(rawType: nil)), ("name", .text(rawType: nil))], 5),
        ([("count", ColumnType.integer(rawType: nil))], 0),
    ])
    func otherShapesAreTables(types: [(String, ColumnType)], rowCount: Int) {
        #expect(DashboardTileShape.of(columns: columns(types), rowCount: rowCount, chartsAvailable: true) == .table)
    }

    @Test("Without the chart license a series over time is a table")
    func chartNeedsLicense() {
        let shape = DashboardTileShape.of(
            columns: columns([("hour", .timestamp(rawType: nil)), ("count", .integer(rawType: nil))]),
            rowCount: 24,
            chartsAvailable: false
        )
        #expect(shape == .table)
    }

    @Test("A table keeps the first rows, counts the rest, and spells out NULL and bytes")
    func tableCells() {
        let rows: [[PluginCellValue]] = (0 ..< 8).map { index in [.text("row \(index)"), .null, .bytes(Data(count: 2_048))] }
        let table = DashboardTileTable(columns: ["name", "note", "payload"], rows: rows, nullDisplay: "NULL")

        #expect(table.rows.count == DashboardTileTable.maximumRowCount)
        #expect(table.hiddenRowCount == 3)
        #expect(table.rows[0][0] == "row 0")
        #expect(table.rows[0][1] == "NULL")
        #expect(table.rows[0][2] == ByteCountFormatter.string(fromByteCount: 2_048, countStyle: .binary))
    }

    @Test("A long or multi-line cell is cut to one line")
    func longCell() {
        let text = DashboardTileTable.text(.text("a\nb" + String(repeating: "x", count: 500)), nullDisplay: "NULL")
        #expect(!text.contains("\n"))
        #expect(text.count == DashboardTileTable.maximumCellLength + 1)
    }

    @Test("A saved interval from a newer build falls back to the dashboard's")
    func unknownIntervalDecodes() throws {
        let json = #"{"tiles":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","favoriteId":"6F9619FF-8B86-D011-B42D-00C04FC964FE","interval":42}]}"#
        let layout = try JSONDecoder().decode(ServerDashboardTileLayout.self, from: Data(json.utf8))
        #expect(layout.tiles.first?.interval == .dashboard)
    }

    @Test("A tile slower than the dashboard is due once its interval has passed")
    func intervalDue() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(DashboardTileInterval.dashboard.isDue(lastRun: start, now: start))
        #expect(DashboardTileInterval.oneMinute.isDue(lastRun: nil, now: start))
        #expect(!DashboardTileInterval.oneMinute.isDue(lastRun: start, now: start.addingTimeInterval(30)))
        #expect(DashboardTileInterval.oneMinute.isDue(lastRun: start, now: start.addingTimeInterval(59.5)))
    }

    // MARK: - Add menu

    @Test("Folders nest, empty folders are left out, and a query in an unknown folder sits at the top")
    func catalogArrangement() {
        let reports = SQLFavoriteFolder(name: "Reports")
        let daily = SQLFavoriteFolder(name: "Daily", parentId: reports.id)
        let empty = SQLFavoriteFolder(name: "Empty")
        let queued = SQLFavorite(name: "Queued", query: "SELECT 1", folderId: daily.id)
        let orphan = SQLFavorite(name: "Orphan", query: "SELECT 2", folderId: UUID())
        let loose = SQLFavorite(name: "Loose", query: "SELECT 3")

        let catalog = DashboardSavedQueryCatalog(favorites: [queued, orphan, loose], folders: [reports, daily, empty])

        #expect(catalog.folders(in: nil).map { $0.name } == ["Reports"])
        #expect(catalog.folders(in: reports.id).map { $0.name } == ["Daily"])
        #expect(catalog.favorites(in: daily.id).map { $0.name } == ["Queued"])
        #expect(catalog.favorites(in: nil).map { $0.name } == ["Loose", "Orphan"])
        #expect(catalog.favorite(id: queued.id) == queued)
    }
}
