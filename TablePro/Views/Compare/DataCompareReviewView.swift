//
//  DataCompareReviewView.swift
//  TablePro
//
//  Per-table row counts on the left, the row differences on the right. One grid
//  filtered six ways rather than six separate views.
//

import SwiftUI
import TableProPluginKit

internal enum RowDiffFilter: String, CaseIterable {
    case all
    case difference
    case insert
    case update
    case delete
    case same

    internal var title: String {
        switch self {
        case .all: return String(localized: "All Rows")
        case .difference: return String(localized: "Difference")
        case .insert: return String(localized: "Insert")
        case .update: return String(localized: "Update")
        case .delete: return String(localized: "Delete")
        case .same: return String(localized: "Same")
        }
    }

    internal func matches(_ entry: RowDiffEntry) -> Bool {
        switch self {
        case .all: return true
        case .difference: return entry.kind != .identical
        case .insert: return entry.kind == .insert
        case .update: return entry.kind == .update
        case .delete: return entry.kind == .delete
        case .same: return entry.kind == .identical
        }
    }
}

internal struct DataCompareReviewView: View {
    @Bindable internal var session: CompareSyncSession

    @State private var selection: String?
    @State private var filter: RowDiffFilter = .difference

    internal var body: some View {
        HSplitView {
            planPane
                .frame(minWidth: 320, idealWidth: 380)
            rowPane
                .frame(minWidth: 380)
        }
    }

    private var planPane: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach($session.dataPlans) { $plan in
                    DataComparePlanRow(plan: $plan)
                        .tag(plan.id)
                }
            }
            .listStyle(.inset)

            if !session.truncatedPlanNames.isEmpty {
                Divider()
                Label(
                    String(
                        format: String(localized: "%d tables had more differences than are shown. Counts are still exact."),
                        session.truncatedPlanNames.count
                    ),
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
            }
        }
    }

    private var selectedPlan: DataComparePlan? {
        session.dataPlans.first { $0.id == selection }
    }

    @ViewBuilder
    private var rowPane: some View {
        if let plan = selectedPlan, let summary = plan.summary {
            VStack(spacing: 0) {
                HStack {
                    Picker("", selection: $filter) {
                        ForEach(RowDiffFilter.allCases, id: \.rawValue) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    Spacer()
                    Text(String(format: String(localized: "Key: %@"), plan.keyColumns.joined(separator: ", ")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                let entries = summary.entries.filter { filter.matches($0) }
                if entries.isEmpty {
                    Text("No rows match this filter.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(entries) { entry in
                        RowDiffEntryRow(entry: entry)
                    }
                    .listStyle(.inset)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "tablecells")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("Select a table to see its row differences")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

internal struct DataComparePlanRow: View {
    @Binding internal var plan: DataComparePlan

    internal var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Toggle("", isOn: $plan.isEnabled)
                    .labelsHidden()
                    .disabled(!plan.isComparable)
                Text(plan.id)
                    .font(.callout)
                Spacer()
            }

            if let reason = plan.unavailableReason {
                Label(reason, systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if let summary = plan.summary {
                HStack(spacing: 10) {
                    countLabel(String(localized: "Insert"), summary.insertCount, "plus.circle")
                    countLabel(String(localized: "Update"), summary.updateCount, "pencil.circle")
                    countLabel(String(localized: "Delete"), summary.deleteCount, "minus.circle")
                    countLabel(String(localized: "Same"), summary.identicalCount, "equal.circle")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                Text(String(format: String(localized: "Key: %@"), plan.keyColumns.joined(separator: ", ")))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func countLabel(_ label: String, _ count: Int, _ symbol: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text("\(count)")
        }
        .help(label)
    }
}

internal struct RowDiffEntryRow: View {
    internal let entry: RowDiffEntry

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    internal var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Label {
                    Text(kindLabel)
                        .font(.caption2)
                } icon: {
                    Image(systemName: kindSymbol)
                }
                .foregroundStyle(differentiateWithoutColor ? Color.primary : kindTint)
                .frame(width: 84, alignment: .leading)

                Text(entry.keyDescription)
                    .font(.system(.callout, design: .monospaced))
                Spacer()
            }

            ForEach(entry.cellDifferences, id: \.column) { difference in
                HStack(alignment: .top, spacing: 6) {
                    Text(difference.column)
                        .font(.caption2.weight(.semibold))
                        .frame(width: 100, alignment: .leading)
                    Text(Self.describe(difference.sourceValue))
                        .font(.system(.caption2, design: .monospaced))
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(Self.describe(difference.targetValue))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(difference.rule.displayName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private static func describe(_ value: PluginCellValue) -> String {
        switch value {
        case .null: return "NULL"
        case .text(let text): return text
        case .bytes(let data): return String(format: String(localized: "%d bytes"), data.count)
        }
    }

    private var kindLabel: String {
        switch entry.kind {
        case .insert: return String(localized: "Insert")
        case .update: return String(localized: "Update")
        case .delete: return String(localized: "Delete")
        case .identical: return String(localized: "Same")
        }
    }

    private var kindSymbol: String {
        switch entry.kind {
        case .insert: return "plus.circle.fill"
        case .update: return "circle.lefthalf.filled"
        case .delete: return "minus.circle.fill"
        case .identical: return "equal.circle"
        }
    }

    private var kindTint: Color {
        switch entry.kind {
        case .insert: return .green
        case .update: return .orange
        case .delete: return .red
        case .identical: return .secondary
        }
    }
}
