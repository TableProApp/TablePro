//
//  QueryPlanDetailPane.swift
//  TablePro
//
//  Everything a plan node reports. Shared by the diagram's popover and the tree's detail pane.
//

import SwiftUI

struct QueryPlanDetailPane: View {
    let node: QueryPlanNode?

    var body: some View {
        if let node {
            content(for: node)
        } else {
            ContentUnavailableView {
                Label(String(localized: "No Node Selected"), systemImage: "square.dashed")
            } description: {
                Text(String(localized: "Select a step in the plan to see what it does."))
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private func content(for node: QueryPlanNode) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(node.operation)
                        .font(.headline)
                    Spacer(minLength: 8)
                    Button {
                        ClipboardService.shared.writeText(QueryPlanNodeSummary.text(for: node))
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(String(localized: "Copy Node Details"))
                    .help(String(localized: "Copy Node Details"))
                }

                estimates(for: node)
                actuals(for: node)
                properties(for: node)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityIdentifier("query-plan-detail-pane")
    }

    @ViewBuilder
    private func estimates(for node: QueryPlanNode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let relation = node.relation { detailRow(QueryPlanLabels.table, relation) }
            if let cost = node.costRangeText(fractionDigits: 2) { detailRow(QueryPlanLabels.cost, cost) }
            if let rows = node.estimatedRows { detailRow(QueryPlanLabels.rows, "\(rows)") }
            if let width = node.estimatedWidth, width > 0 { detailRow(QueryPlanLabels.width, "\(width)") }
        }
    }

    @ViewBuilder
    private func actuals(for node: QueryPlanNode) -> some View {
        if let time = node.actualTotalTime {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(QueryPlanLabels.actual)
                    .font(.caption.weight(.semibold))
                detailRow(QueryPlanLabels.actualTime, QueryPlanLabels.milliseconds(time))
                if let rows = node.actualRows { detailRow(QueryPlanLabels.actualRows, "\(rows)") }
                if let loops = node.actualLoops, loops > 1 { detailRow(QueryPlanLabels.loops, "\(loops)") }
            }
        }
    }

    @ViewBuilder
    private func properties(for node: QueryPlanNode) -> some View {
        let visible = QueryPlanLabels.visibleProperties(of: node)
        if !visible.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(QueryPlanLabels.details)
                    .font(.caption.weight(.semibold))
                ForEach(visible, id: \.key) { key, value in
                    detailRow(key, value)
                }
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
