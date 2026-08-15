//
//  QueryPlanTreeView.swift
//  TablePro
//
//  Native SwiftUI tree view for EXPLAIN query plan visualization.
//  Uses OutlineGroup for hierarchical display following macOS HIG.
//

import SwiftUI

struct QueryPlanTreeView: View {
    let plan: QueryPlan

    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                OutlineGroup(
                    [plan.rootNode],
                    id: \.id,
                    children: \.childrenOrNil
                ) { node in
                    QueryPlanRowView(node: node)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            if let selectedNode = findNode(selection, in: plan.rootNode) {
                Divider()
                QueryPlanDetailView(node: selectedNode)
                    .frame(height: 180)
            }
        }
    }

    // MARK: - Find Node

    private func findNode(_ id: UUID?, in node: QueryPlanNode) -> QueryPlanNode? {
        guard let id else { return nil }
        if node.id == id { return node }
        for child in node.children {
            if let found = findNode(id, in: child) { return found }
        }
        return nil
    }
}

// MARK: - Row View

private struct QueryPlanRowView: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    let node: QueryPlanNode

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.severity.symbolName)
                .font(.system(size: 8))
                .foregroundStyle(node.severity.tint(differentiateWithoutColor: differentiateWithoutColor))
                .frame(width: 10)
                .accessibilityLabel(node.severity.accessibilityLabel)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(node.operation)
                        .font(.system(.body, weight: .medium))
                    if let joinType = node.properties["Join Type"] {
                        Text("(\(joinType))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let relation = node.relation {
                    HStack(spacing: 4) {
                        Text(relation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let index = node.properties["Index Name"] {
                            Text("using \(index)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Spacer(minLength: 16)

            if let cost = node.costRangeText(fractionDigits: 2) {
                Text(cost)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .trailing)
            }

            if let rows = node.estimatedRows {
                Text("\(rows.formatted(.number.grouping(.automatic))) ^[rows](inflect: true)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)
            }

            // Actual time (EXPLAIN ANALYZE)
            if let time = node.actualTotalTime {
                Text(QueryPlanLabels.milliseconds(time))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 80, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail View

private struct QueryPlanDetailView: View {
    let node: QueryPlanNode

    private var filteredProperties: [(key: String, value: String)] {
        QueryPlanLabels.visibleProperties(of: node)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(node.operation)
                            .font(.caption.weight(.semibold))
                        if let relation = node.relation { detailRow(QueryPlanLabels.table, relation) }
                        if let cost = node.costRangeText(fractionDigits: 2) {
                            detailRow(QueryPlanLabels.cost, cost)
                        }
                        if let rows = node.estimatedRows { detailRow(QueryPlanLabels.rows, "\(rows)") }
                        if let width = node.estimatedWidth, width > 0 {
                            detailRow(QueryPlanLabels.width, "\(width)")
                        }
                    }

                    // Actuals (EXPLAIN ANALYZE)
                    if node.actualTotalTime != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(QueryPlanLabels.actual)
                                .font(.caption.weight(.semibold))
                            if let time = node.actualTotalTime {
                                detailRow(QueryPlanLabels.actualTime, QueryPlanLabels.milliseconds(time))
                            }
                            if let rows = node.actualRows { detailRow(QueryPlanLabels.rows, "\(rows)") }
                            if let loops = node.actualLoops, loops > 1 {
                                detailRow(QueryPlanLabels.loops, "\(loops)")
                            }
                        }
                    }

                    if !filteredProperties.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(QueryPlanLabels.details)
                                .font(.caption.weight(.semibold))
                            ForEach(filteredProperties, id: \.key) { key, value in
                                detailRow(key, value)
                            }
                        }
                    }

                    Spacer()
                }
                .padding(12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

// MARK: - Children Helper

extension QueryPlanNode {
    var childrenOrNil: [QueryPlanNode]? {
        children.isEmpty ? nil : children
    }
}
