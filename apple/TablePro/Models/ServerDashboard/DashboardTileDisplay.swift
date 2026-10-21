//
//  DashboardTileDisplay.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum DashboardTileShape: Equatable, Sendable {
    case value
    case table
    case lineChart(ResultChartConfiguration.Resolved)

    /// A line only for a series over time: a numeric first column would chart an id against a count.
    static func of(columns: [ResultChartColumn], rowCount: Int, chartsAvailable: Bool) -> DashboardTileShape {
        if rowCount == 1, columns.count == 1 {
            return .value
        }
        guard chartsAvailable, rowCount >= 2, let xColumn = columns.first, xColumn.xAxisKind == .date,
              let yColumn = columns.dropFirst().first(where: \.supportsY)
        else {
            return .table
        }
        let configuration = ResultChartConfiguration(chartType: .line, xColumn: xColumn.id, yColumn: yColumn.id)
        guard let resolved = configuration.resolved(in: columns) else { return .table }
        return .lineChart(resolved)
    }
}

struct DashboardTileTable: Equatable, Sendable {
    static let maximumRowCount = 5
    static let maximumCellLength = 200
    /// The most a tile fetches: as many rows as a chart draws.
    static let rowCap = ResultChartProjector.maximumPointCount

    let columns: [String]
    let rows: [[String]]
    let totalRowCount: Int
    /// The fetch stopped at `rowCap`, so `totalRowCount` is a floor.
    let isTruncated: Bool

    var hiddenRowCount: Int { max(0, totalRowCount - rows.count) }

    init(columns: [String], rows: [[PluginCellValue]], isTruncated: Bool = false, nullDisplay: String) {
        self.columns = columns
        self.rows = rows.prefix(Self.maximumRowCount).map { row in
            columns.indices.map { index in
                Self.text(index < row.count ? row[index] : .null, nullDisplay: nullDisplay)
            }
        }
        totalRowCount = rows.count
        self.isTruncated = isTruncated
    }

    static func text(_ cell: PluginCellValue, nullDisplay: String) -> String {
        switch cell {
        case .null:
            return nullDisplay
        case .text(let value):
            let line = value.replacingOccurrences(of: "\n", with: " ")
            guard line.count > maximumCellLength else { return line }
            return String(line.prefix(maximumCellLength)) + "…"
        case .bytes(let data):
            return ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .binary)
        }
    }
}

enum DashboardTileDisplay: Equatable, Sendable {
    case value(String)
    case table(DashboardTileTable)
    /// `isTruncated`: the fetch stopped at `DashboardTileTable.rowCap`, so later rows are not drawn.
    case lineChart(ResultChartProjection, isTruncated: Bool)
}
