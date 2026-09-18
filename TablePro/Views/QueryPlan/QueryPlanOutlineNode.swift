//
//  QueryPlanOutlineNode.swift
//  TablePro
//
//  NSOutlineView tracks items by reference identity, so the value-typed plan tree is wrapped
//  once per parse into objects the outline can hold on to.
//

import Foundation

@MainActor
final class QueryPlanOutlineNode: NSObject {
    let source: QueryPlanNode
    let children: [QueryPlanOutlineNode]

    init(_ source: QueryPlanNode) {
        self.source = source
        children = source.children.map(QueryPlanOutlineNode.init)
    }

    var isExpandable: Bool { !children.isEmpty }

    /// Reorders siblings at every level. A plan tree cannot be flattened and sorted, because a
    /// join's inputs are not interchangeable with a subtree at another depth, so the shape is
    /// preserved and only the order within each parent changes.
    func sorted(by comparator: (QueryPlanNode, QueryPlanNode) -> Bool) -> QueryPlanOutlineNode {
        QueryPlanOutlineNode(sortedSource(by: comparator))
    }

    private func sortedSource(by comparator: (QueryPlanNode, QueryPlanNode) -> Bool) -> QueryPlanNode {
        var copy = source
        copy.children = source.children
            .map { child in QueryPlanOutlineNode(child).sortedSource(by: comparator) }
            .sorted(by: comparator)
        return copy
    }
}

enum QueryPlanOutlineSort {
    static func comparator(
        key: QueryPlanOutlineColumn,
        ascending: Bool,
        metrics: QueryPlanMetricIndex? = nil
    ) -> (QueryPlanNode, QueryPlanNode) -> Bool {
        { lhs, rhs in
            let result: Bool
            switch key {
            case .operation:
                result = lhs.operation.localizedStandardCompare(rhs.operation) == .orderedAscending
            case .cost:
                result = (lhs.estimatedTotalCost ?? -1) < (rhs.estimatedTotalCost ?? -1)
            case .rows:
                result = (lhs.estimatedRows ?? -1) < (rhs.estimatedRows ?? -1)
            case .actualTime:
                result = (lhs.actualTotalTime ?? -1) < (rhs.actualTotalTime ?? -1)
            case .magnitude:
                result = (metrics?.value(for: lhs) ?? -1) < (metrics?.value(for: rhs) ?? -1)
            }
            return ascending ? result : !result
        }
    }

    /// Numbers read worst-first, names read A to Z.
    static func defaultAscending(for column: QueryPlanOutlineColumn) -> Bool {
        column == .operation
    }
}

enum QueryPlanOutlineColumn: String, CaseIterable {
    case operation
    case magnitude
    case cost
    case rows
    case actualTime

    /// The magnitude column is titled by whichever metric it is charting, so the header says what
    /// the bars mean without the reader having to look back at the toolbar.
    func title(metric: QueryPlanBarMetric?) -> String {
        switch self {
        case .operation: return QueryPlanLabels.operation
        case .magnitude: return metric?.title ?? QueryPlanLabels.magnitude
        case .cost: return QueryPlanLabels.cost
        case .rows: return QueryPlanLabels.rows
        case .actualTime: return QueryPlanLabels.actualTime
        }
    }

    var width: CGFloat {
        switch self {
        case .operation: return 320
        case .magnitude: return 180
        case .cost: return 110
        case .rows: return 90
        case .actualTime: return 100
        }
    }

    var minimumWidth: CGFloat {
        switch self {
        case .operation: return 160
        case .magnitude: return 120
        case .cost: return 80
        case .rows: return 70
        case .actualTime: return 80
        }
    }

    /// Which values have to be present for the column to say anything. A plan that reports none of
    /// them shows no column rather than a blank one, and four of the seven formats the app parses
    /// report none at all.
    func hasContent(in plan: QueryPlan, metrics: QueryPlanMetricIndex?) -> Bool {
        switch self {
        case .operation: return true
        case .magnitude: return metrics != nil
        case .cost: return plan.contains { $0.estimatedTotalCost != nil }
        case .rows: return plan.contains { $0.estimatedRows != nil }
        case .actualTime: return plan.contains { $0.actualTotalTime != nil }
        }
    }
}
