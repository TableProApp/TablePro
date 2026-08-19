//
//  ResultChartProjection.swift
//  TablePro
//

import Foundation

enum ResultChartDataScope {
    static func hasUnloadedRows(
        tabType: TabType,
        pagination: PaginationState,
        loadedRowCount: Int
    ) -> Bool {
        if tabType == .query {
            return pagination.hasMoreRows
        }
        if tabType == .table {
            return pagination.canGoToNextPage(loadedRowCount: loadedRowCount)
        }
        return false
    }
}

struct ResultChartProjection: Equatable, Sendable {
    enum XValue: Equatable, Sendable {
        case category(String)
        case number(Decimal)
    }

    enum SeriesValue: Equatable, Hashable, Sendable {
        case value(String)
        case missing
    }

    enum Issue: Equatable, Sendable {
        case noChartableRows
        case tooManyPoints(limit: Int)
        case tooManySeries(limit: Int)
        case tooManyRows(limit: Int)
    }

    struct Point: Identifiable, Equatable, Sendable {
        let sourceIndex: Int
        let x: XValue
        let y: Decimal
        let rawX: String
        let rawY: String
        let series: SeriesValue?
        let barGroup: Int
        let lineGroup: Int

        var id: Int { sourceIndex }
    }

    let points: [Point]
    let issue: Issue?
    let loadedRowCount: Int
    let skippedRowCount: Int
    let xAxisLabel: String
    let yAxisLabel: String
    let seriesLabel: String?
}
