//
//  QueryPlanDetailPane.swift
//  TablePro
//
//  Everything a plan node reports. Shared by the diagram's popover and the tree's detail pane.
//

import SwiftUI
import TableProTheme

struct QueryPlanDetailPane: View {
    let node: QueryPlanNode?

    var body: some View {
        if let node {
            content(for: node)
        } else {
            UnavailableStateView {
                Label(String(localized: "No Node Selected"), systemImage: "square.dashed")
            } description: {
                Text(String(localized: "Select a step in the plan to see what it does."))
            }
            .themeBackground(.gridBackground, native: Color(nsColor: .controlBackgroundColor))
        }
    }

    private func content(for node: QueryPlanNode) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(node.operation)
                        .font(.headline)
                        .themeForeground(.gridText, native: .primary)
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
                warnings(for: node)
                missingIndexes(for: node)
                properties(for: node)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .themeBackground(.gridBackground, native: Color(nsColor: .controlBackgroundColor))
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
    private func warnings(for node: QueryPlanNode) -> some View {
        if !node.warnings.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(QueryPlanLabels.warnings)
                } icon: {
                    Image(systemName: QueryPlanWarningBadge.symbolName)
                        .foregroundStyle(.orange)
                }
                .font(.caption.weight(.semibold))
                ForEach(Array(node.warnings.enumerated()), id: \.offset) { _, warning in
                    Text(warning)
                        .font(.system(.caption, design: .monospaced))
                        .themeForeground(.gridText, native: .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func missingIndexes(for node: QueryPlanNode) -> some View {
        if !node.missingIndexes.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(QueryPlanLabels.missingIndexes)
                    .font(.caption.weight(.semibold))
                ForEach(node.missingIndexes, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if let impact = index.impact {
                                Text(QueryPlanLabels.impact(impact))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button {
                                ClipboardService.shared.writeText(index.createStatement)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(QueryPlanLabels.copyCreateIndex)
                            .help(QueryPlanLabels.copyCreateIndex)
                        }
                        Text(index.createStatement)
                            .font(.system(.caption, design: .monospaced))
                            .themeForeground(.gridText, native: .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
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
                .themeForeground(.gridText, native: .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
