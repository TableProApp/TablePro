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

    /// Boolean flags and zero-value noise a driver reports that add nothing to the display.
    static let hiddenPropertyKeys: Set<String> = [
        "Parallel Aware", "Async Capable", "Disabled", "Inner Unique",
    ]

    static func visibleProperties(of node: QueryPlanNode) -> [(key: String, value: String)] {
        node.properties
            .filter { !hiddenPropertyKeys.contains($0.key) }
            .filter { $0.value != "false" && $0.value != "0" }
            .sorted { $0.key < $1.key }
    }

    static func milliseconds(_ value: Double) -> String {
        String(format: String(localized: "%.3fms"), value)
    }
}
