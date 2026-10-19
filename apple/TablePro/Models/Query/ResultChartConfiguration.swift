//
//  ResultChartConfiguration.swift
//  TablePro
//

import Foundation

/// The user's chart choices for a tab. Columns are named rather than indexed, so paging, sorting and
/// re-running keep the axes while an edited SELECT list cannot silently chart a different column that
/// happens to land on the same position. A choice that no longer resolves is kept, not erased, so it
/// comes back when the column does.
struct ResultChartConfiguration: Equatable, Hashable, Sendable {
    var chartType: ResultChartType
    var xColumn: ResultChartColumnID?
    var yColumn: ResultChartColumnID?
    var seriesColumn: ResultChartColumnID?
    var facetColumn: ResultChartColumnID?

    init(
        chartType: ResultChartType = .bar,
        xColumn: ResultChartColumnID? = nil,
        yColumn: ResultChartColumnID? = nil,
        seriesColumn: ResultChartColumnID? = nil,
        facetColumn: ResultChartColumnID? = nil
    ) {
        self.chartType = chartType
        self.xColumn = xColumn
        self.yColumn = yColumn
        self.seriesColumn = seriesColumn
        self.facetColumn = facetColumn
    }

    /// The first numeric column that is not part of the primary key. A leading auto-increment key
    /// plots as a straight diagonal, which tells the reader nothing about their data.
    static func defaultYColumn(in columns: [ResultChartColumn]) -> ResultChartColumn? {
        columns.first { $0.supportsY && !$0.isPrimaryKey } ?? columns.first(where: \.supportsY)
    }

    func resolved(in columns: [ResultChartColumn]) -> Resolved? {
        let resolvedY = columns.first { $0.id == yColumn && $0.supportsY }
            ?? Self.defaultYColumn(in: columns)
        guard let resolvedY else { return nil }

        return Resolved(
            chartType: chartType,
            xColumn: columns.first { $0.id == xColumn && $0.xAxisKind != nil },
            yColumn: resolvedY,
            seriesColumn: columns.first { $0.id == seriesColumn && $0.supportsSeries },
            facetColumn: columns.first { $0.id == facetColumn && $0.supportsSeries }
        )
    }

    struct Resolved: Equatable, Sendable {
        let chartType: ResultChartType
        let xColumn: ResultChartColumn?
        let yColumn: ResultChartColumn
        let seriesColumn: ResultChartColumn?
        let facetColumn: ResultChartColumn?

        /// No X column means the row number, which is a numeric axis.
        var xAxisKind: ResultChartColumn.AxisKind {
            xColumn?.xAxisKind ?? .number
        }

        /// Every column the projection reads, and nothing else. The projection key holds this
        /// rather than its own list, so a new axis cannot be left out of the key and leave a stale
        /// projection on screen.
        var columnIDs: ColumnIDs {
            ColumnIDs(x: xColumn?.id, y: yColumn.id, series: seriesColumn?.id, facet: facetColumn?.id)
        }
    }

    struct ColumnIDs: Hashable, Sendable {
        let x: ResultChartColumnID?
        let y: ResultChartColumnID
        let series: ResultChartColumnID?
        let facet: ResultChartColumnID?
    }
}
