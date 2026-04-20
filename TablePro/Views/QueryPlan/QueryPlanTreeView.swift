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
            // Tree list
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

            // Detail panel for selected node
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

    let node: QueryPlanNode

    var body: some View {
        HStack(spacing: 8) {
            // Cost indicator
            Circle()
                .fill(costColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            // Operation + table
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

            // Cost
            if let startup = node.estimatedStartupCost, let total = node.estimatedTotalCost {
                Text(String(format: "%.2f..%.2f", startup, total))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .trailing)
            }

            // Rows
            if let rows = node.estimatedRows {
                Text("\(rows.formatted(.number.grouping(.automatic))) rows")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)
            }

            // Actual time (EXPLAIN ANALYZE)
            if let time = node.actualTotalTime {
                Text(String(format: "%.3fms", time))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 80, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }

    private var costColor: Color {
        if node.costFraction > 0.5 { return Color(nsColor: .systemRed) }
        if node.costFraction > 0.2 { return Color(nsColor: .systemOrange) }
        if node.costFraction > 0.05 { return Color(nsColor: .systemYellow) }
        return Color(nsColor: .systemGreen)
    }
}

// MARK: - Detail View

private struct QueryPlanDetailView: View {
    let node: QueryPlanNode

    /// Properties to hide (boolean flags and zero-value noise from PostgreSQL EXPLAIN).
    private static let hiddenKeys: Set<String> = [
        "Parallel Aware", "Async Capable", "Disabled", "Inner Unique",
    ]

    private var filteredProperties: [(key: String, value: String)] {
        node.properties
            .filter { !Self.hiddenKeys.contains($0.key) }
            .filter { $0.value != "false" && $0.value != "0" }
            .sorted { $0.key < $1.key }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 24) {
                    // Estimates
                    VStack(alignment: .leading, spacing: 4) {
                        Text(node.operation)
                            .font(.caption.weight(.semibold))
                        if let relation = node.relation { detailRow("Table", relation) }
                        if let s = node.estimatedStartupCost, let t = node.estimatedTotalCost {
                            detailRow("Cost", String(format: "%.2f..%.2f", s, t))
                        }
                        if let rows = node.estimatedRows { detailRow("Rows", "\(rows)") }
                        if let width = node.estimatedWidth, width > 0 { detailRow("Width", "\(width)") }
                    }

                    // Actuals (EXPLAIN ANALYZE)
                    if node.actualTotalTime != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Actual")
                                .font(.caption.weight(.semibold))
                            if let time = node.actualTotalTime {
                                detailRow("Time", String(format: "%.3fms", time))
                            }
                            if let rows = node.actualRows { detailRow("Rows", "\(rows)") }
                            if let loops = node.actualLoops, loops > 1 { detailRow("Loops", "\(loops)") }
                        }
                    }

                    // Extra properties
                    if !filteredProperties.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Details")
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
