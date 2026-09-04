//
//  QueryPlanLabels.swift
//  TablePro
//
//  Every label the plan views draw. They reach the views as String parameters rather than as
//  SwiftUI view literals, so they need String(localized:) explicitly to be translated.
//

import Foundation

enum QueryPlanLabels {
    static var table: String { String(localized: "Table") }
    static var cost: String { String(localized: "Cost") }
    static var rows: String { String(localized: "Rows") }
    static var width: String { String(localized: "Width") }
    static var actual: String { String(localized: "Actual") }
    static var actualTime: String { String(localized: "Actual Time") }
    static var actualRows: String { String(localized: "Actual Rows") }
    static var loops: String { String(localized: "Loops") }
    static var details: String { String(localized: "Details") }
    static var operation: String { String(localized: "Operation") }
    static var metric: String { String(localized: "Metric") }
    static var magnitude: String { String(localized: "Chart") }

    /// Boolean flags and zero-value noise a driver reports that add nothing to the display.
    static let hiddenPropertyKeys: Set<String> = [
        "Parallel Aware", "Async Capable", "Disabled", "Inner Unique",
    ]

    /// Properties whose zero is the answer rather than the absence of one. PostgreSQL reports
    /// `Workers Planned: 2, Workers Launched: 0` when the planner asked for parallelism and the
    /// server had no worker slots left, which is why the query was slow. Dropping the zero left
    /// the planned count on screen with nothing to contradict it, so the plan read as parallel.
    static let significantZeroKeys: Set<String> = [
        "Workers Launched", "Actual Rows", "Actual Loops", "Heap Fetches",
    ]

    static func visibleProperties(of node: QueryPlanNode) -> [(key: String, value: String)] {
        node.properties
            .filter { isVisible(key: $0.key, value: $0.value) }
            .sorted { $0.key < $1.key }
    }

    private static func isVisible(key: String, value: String) -> Bool {
        guard !hiddenPropertyKeys.contains(key) else { return false }
        guard !significantZeroKeys.contains(key) else { return true }
        return value != "false" && value != "0"
    }

    static func milliseconds(_ value: Double) -> String {
        String(format: String(localized: "%.3fms"), value)
    }
}
