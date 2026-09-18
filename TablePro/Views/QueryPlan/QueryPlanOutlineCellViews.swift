//
//  QueryPlanOutlineCellViews.swift
//  TablePro
//
//  Cell contents for the plan outline. Each cell carries its own column-scoped accessibility
//  label, which is what VoiceOver expects from a real multi-column table.
//

import SwiftUI

struct QueryPlanOperationCellView: View {
    let node: QueryPlanNode
    let differentiateWithoutColor: Bool

    var body: some View {
        HStack(spacing: 6) {
            // Hidden rather than absent when the plan reported no cost for this node, so the
            // operation text keeps one left edge down the column. A plan can report a cost for
            // some nodes and not others: MySQL prices a "never executed" branch at nothing.
            Image(systemName: node.severity?.symbolName ?? QueryPlanSeverity.low.symbolName)
                .font(.system(size: 8))
                .foregroundStyle(tint)
                .opacity(node.severity == nil ? 0 : 1)
                .accessibilityHidden(true)

            Text(node.operation)
                .font(.system(.body, weight: .medium))
                .lineLimit(1)

            if let joinType = node.properties["Join Type"] {
                Text("(\(joinType))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let relation = node.relation {
                Text(relation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let index = node.properties["Index Name"] {
                    Text("using \(index)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(QueryPlanNodeSummary.accessibilityLabel(for: node))
    }

    private var tint: Color {
        node.severity?.tint(differentiateWithoutColor: differentiateWithoutColor) ?? .secondary
    }
}

struct QueryPlanMetricCellView: View {
    let text: String?
    let label: String

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Text(text ?? "")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.map { "\(label) \($0)" } ?? label)
    }
}
