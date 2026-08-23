//
//  QueryPlanComparisonView.swift
//  TablePro
//
//  The plan pane's Compare mode: this run against an earlier one.
//
//  A mode inside the pane rather than a sheet or a window. The HIG routes a prolonged, revisitable
//  task away from modality ("For complex or prolonged user flows, consider alternatives to
//  sheets"), and the whole point of comparing a plan is to change the query or the schema and run
//  it again, which a modal sheet structurally forbids. Xcode's own comparison editor is the same
//  shape: a mode, a revision picker, and next/previous change.
//

import SwiftUI

struct QueryPlanComparisonView: View {
    let model: QueryPlanComparisonModel

    var body: some View {
        switch model.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty(let reason):
            ContentUnavailableView(
                reason.title,
                systemImage: reason.systemImage,
                description: Text(reason.message)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("query-plan-comparison-empty")

        case .unavailable(let message):
            ContentUnavailableView(
                String(localized: "Comparison Unavailable"),
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .content(.diff(let diff)):
            QueryPlanDiffView(diff: diff)

        case .content(.rawText(let baseline, let current)):
            QueryPlanRawComparisonView(baselineLines: baseline, currentLines: current)
        }
    }
}

private struct QueryPlanDiffView: View {
    let diff: QueryPlanDiff

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                QueryPlanVerdictBanner(verdict: diff.verdict)
                QueryPlanSummaryGrid(changes: diff.summary)
                Divider()
                nodeChanges
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var nodeChanges: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Node Changes"))
                .font(.headline)

            if diff.nodeChanges.isEmpty {
                Text(String(localized: "No node changes."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(diff.nodeChanges) { change in
                        QueryPlanNodeChangeRow(change: change)
                        Divider()
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("query-plan-comparison-changes")
    }
}

private struct QueryPlanVerdictBanner: View {
    let verdict: QueryPlanVerdict

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: verdict.symbolName)
                .foregroundStyle(verdict.tint)
                .accessibilityHidden(true)
            Text(verdict.headline)
                .font(.headline)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("query-plan-comparison-verdict")
    }
}

private struct QueryPlanSummaryGrid: View {
    let changes: [QueryPlanFieldChange]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
            GridRow {
                Text(String(localized: "Metric"))
                Text(String(localized: "Baseline"))
                Text(String(localized: "Current"))
                Text(String(localized: "Change"))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            Divider().gridCellColumns(4)

            ForEach(changes) { change in
                GridRow {
                    Text(change.field.title)
                        .font(.callout)
                    Text(QueryPlanValueFormatter.string(change.before, unit: change.field.unit))
                        .foregroundStyle(.secondary)
                    Text(QueryPlanValueFormatter.string(change.after, unit: change.field.unit))
                    Text(QueryPlanValueFormatter.change(change) ?? QueryPlanValueFormatter.absent)
                        .foregroundStyle(change.hasChange ? Color.primary : Color.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .monospacedDigit()
        .accessibilityIdentifier("query-plan-comparison-summary")
    }
}

private struct QueryPlanNodeChangeRow: View {
    let change: QueryPlanNodeChange

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    private var style: QueryPlanChangeStyle { QueryPlanChangeStyle(change.kind) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: style.symbolName)
                .foregroundStyle(differentiateWithoutColor ? Color.primary : style.tint)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(style.glyph)
                        .font(.caption.monospaced().weight(.bold))
                        .accessibilityHidden(true)
                    Text(style.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(differentiateWithoutColor ? Color.secondary : style.tint)
                    Text(change.title)
                        .font(.callout.weight(.medium))
                }

                ForEach(change.fieldChanges) { field in
                    Text(fieldText(field))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(style.label): \(change.title)")
        .accessibilityValue(change.fieldChanges.map(Self.fieldText).joined(separator: ", "))
        .accessibilityIdentifier("query-plan-comparison-change-\(change.kind.rawValue)")
    }

    private func fieldText(_ field: QueryPlanFieldChange) -> String {
        Self.fieldText(field)
    }

    static func fieldText(_ field: QueryPlanFieldChange) -> String {
        let before = QueryPlanValueFormatter.string(field.before, unit: field.field.unit)
        let after = QueryPlanValueFormatter.string(field.after, unit: field.field.unit)
        return "\(field.field.title): \(before) \u{2192} \(after)"
    }
}

/// Used when either plan could not be parsed. It goes through the same line diff the Compare & Sync
/// window uses for a definition, so a plan the app cannot read as a tree is still shown as a
/// difference rather than as two blobs the reader has to align by eye.
private struct QueryPlanRawComparisonView: View {
    let baselineLines: [String]
    let currentLines: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(String(localized: "This plan could not be read as a tree, so the two runs are compared as text."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)

                StructureDefinitionDiffView(
                    title: String(localized: "Plan"),
                    sourceLabel: String(localized: "Current"),
                    targetLabel: String(localized: "Baseline"),
                    sourceLines: currentLines,
                    targetLines: baselineLines
                )
            }
            .padding(16)
        }
        .accessibilityIdentifier("query-plan-comparison-raw")
    }
}
