//
//  QueryPlanNodeSummary.swift
//  TablePro
//
//  Plain-text renderings of a plan node, for copying and for VoiceOver.
//

import Foundation

enum QueryPlanNodeSummary {
    /// The whole node as `Label: value` lines, for Copy Node Details.
    static func text(for node: QueryPlanNode) -> String {
        var lines = [node.operation]

        if let relation = node.relation { lines.append("\(QueryPlanLabels.table): \(relation)") }
        if let cost = node.costRangeText(fractionDigits: 2) { lines.append("\(QueryPlanLabels.cost): \(cost)") }
        if let rows = node.estimatedRows { lines.append("\(QueryPlanLabels.rows): \(rows)") }
        if let width = node.estimatedWidth, width > 0 { lines.append("\(QueryPlanLabels.width): \(width)") }
        if let time = node.actualTotalTime {
            lines.append("\(QueryPlanLabels.actualTime): \(QueryPlanLabels.milliseconds(time))")
        }
        if let rows = node.actualRows { lines.append("\(QueryPlanLabels.actualRows): \(rows)") }
        if let loops = node.actualLoops, loops > 1 { lines.append("\(QueryPlanLabels.loops): \(loops)") }

        for property in QueryPlanLabels.visibleProperties(of: node) {
            lines.append("\(property.key): \(property.value)")
        }

        return lines.joined(separator: "\n")
    }

    /// One spoken sentence: what the node does, on what, how expensive it is.
    static func accessibilityLabel(for node: QueryPlanNode) -> String {
        var parts = [node.operation]

        if let relation = node.relation {
            parts.append(String(format: String(localized: "on %@"), relation))
        }
        parts.append(node.severity.accessibilityLabel)
        if let cost = node.costRangeText(fractionDigits: 2) {
            parts.append("\(QueryPlanLabels.cost) \(cost)")
        }
        if let rows = node.estimatedRows {
            parts.append("\(rows) \(QueryPlanLabels.rows)")
        }
        if let time = node.actualTotalTime {
            parts.append("\(QueryPlanLabels.actualTime) \(QueryPlanLabels.milliseconds(time))")
        }

        return parts.joined(separator: ", ")
    }
}
