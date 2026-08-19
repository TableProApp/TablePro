//
//  ResultChartConfiguration.swift
//  TablePro
//

import Foundation

struct ResultChartConfiguration: Equatable, Hashable, Sendable {
    var chartType: ResultChartType
    var xColumnIndex: Int?
    var yColumnIndex: Int?
    var seriesColumnIndex: Int?

    init(
        chartType: ResultChartType = .bar,
        xColumnIndex: Int? = nil,
        yColumnIndex: Int? = nil,
        seriesColumnIndex: Int? = nil
    ) {
        self.chartType = chartType
        self.xColumnIndex = xColumnIndex
        self.yColumnIndex = yColumnIndex
        self.seriesColumnIndex = seriesColumnIndex
    }

    static func defaultConfiguration(for tableRows: TableRows) -> ResultChartConfiguration {
        let columns = ResultChartColumn.columns(in: tableRows)
        return ResultChartConfiguration(
            yColumnIndex: columns.first(where: \.supportsY)?.index
        )
    }

    func resolved(in columns: [ResultChartColumn]) -> Resolved? {
        guard let yColumnIndex,
              let yColumn = columns.first(where: { $0.index == yColumnIndex && $0.supportsY })
        else {
            return nil
        }

        let xColumn: ResultChartColumn?
        if let xColumnIndex {
            guard let selected = columns.first(where: { $0.index == xColumnIndex && $0.xAxisKind != nil }) else {
                return nil
            }
            xColumn = selected
        } else {
            xColumn = nil
        }

        let seriesColumn: ResultChartColumn?
        if let seriesColumnIndex {
            guard let selected = columns.first(where: { $0.index == seriesColumnIndex && $0.supportsSeries }) else {
                return nil
            }
            seriesColumn = selected
        } else {
            seriesColumn = nil
        }

        return Resolved(chartType: chartType, xColumn: xColumn, yColumn: yColumn, seriesColumn: seriesColumn)
    }

    struct Resolved: Equatable, Sendable {
        let chartType: ResultChartType
        let xColumn: ResultChartColumn?
        let yColumn: ResultChartColumn
        let seriesColumn: ResultChartColumn?

        var xAxisKind: ResultChartColumn.AxisKind {
            xColumn?.xAxisKind ?? .number
        }
    }
}
