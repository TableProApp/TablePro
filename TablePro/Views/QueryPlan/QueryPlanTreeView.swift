//
//  QueryPlanTreeView.swift
//  TablePro
//
//  The plan as an outline over a resizable detail pane, matching the list-and-detail shape the
//  rest of the app uses.
//

import SwiftUI

struct QueryPlanTreeView: View {
    let plan: QueryPlan
    @Binding var selectedNodeId: UUID?

    var body: some View {
        AutosavingSplitView(
            autosaveName: "com.TablePro.queryPlanTreeSplit",
            isVertical: false,
            primaryMinimum: 160,
            secondaryMinimum: 120
        ) {
            QueryPlanOutlineView(plan: plan, selectedNodeId: $selectedNodeId)
        } secondary: {
            QueryPlanDetailPane(node: selectedNode)
        }
    }

    private var selectedNode: QueryPlanNode? {
        guard let selectedNodeId else { return nil }
        return QueryPlanTreeView.find(selectedNodeId, in: plan.rootNode)
    }

    static func find(_ id: UUID, in node: QueryPlanNode) -> QueryPlanNode? {
        if node.id == id { return node }
        for child in node.children {
            if let found = find(id, in: child) { return found }
        }
        return nil
    }
}

extension QueryPlanNode {
    var childrenOrNil: [QueryPlanNode]? {
        children.isEmpty ? nil : children
    }
}
