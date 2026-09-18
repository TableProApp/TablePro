//
//  ResultChartType.swift
//  TablePro
//

import Foundation

enum ResultChartType: String, CaseIterable, Hashable, Identifiable, Sendable {
    case bar
    case line
    case area
    case scatter

    var id: Self { self }

    var displayName: String {
        switch self {
        case .bar: return String(localized: "Bar")
        case .line: return String(localized: "Line")
        case .area: return String(localized: "Area")
        case .scatter: return String(localized: "Scatter")
        }
    }

    var systemImage: String {
        switch self {
        case .bar: return "chart.bar.xaxis"
        case .line: return "chart.xyaxis.line"
        case .area: return "chart.xyaxis.line"
        case .scatter: return "chart.dots.scatter"
        }
    }
}
