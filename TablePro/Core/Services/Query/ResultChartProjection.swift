//
//  ResultChartProjection.swift
//  TablePro
//

import Foundation

struct ResultChartProjection: Equatable, Sendable {
    enum XValue: Hashable, Sendable {
        case category(String)
        case number(Double)
        case date(Date)
    }

    enum SeriesValue: Equatable, Hashable, Sendable {
        case value(String)
        case missing

        /// The legend entry and the hover callout name the same series, so they read it from here.
        var displayName: String {
            switch self {
            case .value(let raw): return raw
            case .missing: return String(localized: "No value")
            }
        }
    }

    /// A bound the projection ran into. The points already gathered are kept and drawn: a result one
    /// row over a cap is a chart with a note, not an error card.
    enum Limit: Equatable, Sendable {
        case points(limit: Int)
        case series(limit: Int)
        case inspectedRows(limit: Int)
    }

    struct Point: Identifiable, Equatable, Sendable {
        let sourceIndex: Int
        let x: XValue
        let y: Double
        let rawX: String
        let rawY: String
        let series: SeriesValue?
        let barGroup: Int
        let lineGroup: Int

        var id: Int { sourceIndex }
    }

    let points: [Point]
    let xAxisKind: ResultChartColumn.AxisKind
    let limits: [Limit]
    let loadedRowCount: Int
    let skippedRowCount: Int
    let xAxisLabel: String
    let yAxisLabel: String
    let seriesLabel: String?
}
