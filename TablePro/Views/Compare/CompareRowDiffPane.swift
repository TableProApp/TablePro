//
//  CompareRowDiffPane.swift
//  TablePro
//
//  The row differences of one table, and the two column sets that decide them.
//
//  The entry list is a capped preview, never the whole difference: the script is
//  built from a fresh streamed pass. Anywhere the cap is in play the pane says
//  so, because a list that silently stops looks like a smaller difference.
//

import SwiftUI
import TableProPluginKit

internal enum RowDiffFilter: String, CaseIterable, Hashable {
    case all
    case difference
    case insert
    case update
    case delete
    case same

    internal var title: String {
        switch self {
        case .all:
            return String(localized: "All Rows")
        case .difference:
            return String(localized: "Difference")
        case .insert:
            return String(localized: "Insert")
        case .update:
            return String(localized: "Update")
        case .delete:
            return String(localized: "Delete")
        case .same:
            return String(localized: "Same")
        }
    }

    internal func matches(_ entry: RowDiffEntry) -> Bool {
        switch self {
        case .all:
            return true
        case .difference:
            return entry.kind != .identical
        case .insert:
            return entry.kind == .insert
        case .update:
            return entry.kind == .update
        case .delete:
            return entry.kind == .delete
        case .same:
            return entry.kind == .identical
        }
    }
}

internal struct CompareRowDiffPane: View {
    @Bindable internal var session: CompareSyncSession
    internal let onCompare: () -> Void

    @State private var filter: RowDiffFilter = .difference

    internal var body: some View {
        if let plan = session.selectedPlan {
            planBody(plan)
        } else if session.mode == .structure {
            ContentUnavailableView {
                Label("Rows Compare Data", systemImage: "tablecells")
            } description: {
                Text("Switch the comparison to Data to see row differences.")
            }
        } else {
            ContentUnavailableView {
                Label("No Table Selected", systemImage: "tablecells")
            } description: {
                Text("Select a table to see its row differences.")
            }
        }
    }

    private func planBody(_ plan: DataComparePlan) -> some View {
        VStack(spacing: 0) {
            columnEditors(plan)
            Divider()
            filterBar
            if plan.summary?.truncatedEntries == true {
                notice(String(
                    localized: "This list is a capped preview. Apply covers every difference, not only the rows listed here."
                ))
            }
            if let skipped = plan.summary?.skippedNullKeyCount, skipped > 0 {
                notice(String(
                    format: String(
                        localized: "%d rows hold NULL in a key column and were left out. Choose a key with no NULLs to compare them."
                    ),
                    skipped
                ))
            }
            if filter == .same, plan.summary?.identicalCount ?? 0 > 0 {
                notice(String(
                    format: String(
                        localized: "%d rows match. Matching rows are counted, not listed, so a difference is never crowded out of this list."
                    ),
                    plan.summary?.identicalCount ?? 0
                ))
            }
            Divider()
            entryList(plan)
        }
    }

    // MARK: - Column editors

    private func columnEditors(_ plan: DataComparePlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 16) {
                columnMenu(
                    title: String(localized: "Key columns"),
                    summary: keySummary(plan),
                    systemImage: "key",
                    identifier: "compare.rows.keyColumns"
                ) {
                    ForEach(plan.columns, id: \.self) { column in
                        Toggle(column, isOn: keyBinding(column, plan: plan))
                    }
                }

                columnMenu(
                    title: String(localized: "Compared columns"),
                    summary: comparedSummary(plan),
                    systemImage: "text.magnifyingglass",
                    identifier: "compare.rows.comparedColumns"
                ) {
                    ForEach(nonKeyColumns(plan), id: \.self) { column in
                        Toggle(column, isOn: comparedBinding(column))
                    }
                }

                Spacer(minLength: 0)
            }

            Text("A column left out of the comparison is still written on insert and update. Changing either list needs another comparison.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if session.needsRecompare {
                recompareNotice
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The label is the joined key column list, so `.fixedSize()` on the menu overrode both the
    /// truncation and the width the pane proposed. A composite key pushed the second menu past the
    /// detail pane's minimum width, where it was clipped and could not be opened at all. The label
    /// truncates instead and the full list stays reachable through the tooltip.
    private func columnMenu(
        title: String,
        summary: String,
        systemImage: String,
        identifier: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Menu {
                content()
            } label: {
                Label(summary, systemImage: systemImage)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(summary)
            .accessibilityIdentifier(identifier)
        }
    }

    private var recompareNotice: some View {
        HStack(spacing: 8) {
            Label {
                Text("Some tables have not been compared with the columns now chosen.")
            } icon: {
                Image(systemName: "exclamationmark.arrow.circlepath")
            }
            .font(.callout)
            .foregroundStyle(CompareStatusStyle.warning)
            .fixedSize(horizontal: false, vertical: true)
            Button("Compare", action: onCompare)
                .disabled(!session.canCompare)
                .accessibilityIdentifier("compare.rows.recompare")
        }
    }

    // MARK: - Filter

    private var filterBar: some View {
        HStack(spacing: 8) {
            Picker(String(localized: "Show"), selection: $filter) {
                ForEach(RowDiffFilter.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .fixedSize()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// A row whose key holds NULL has no identity a merge join can use, so it is left out of the
    /// comparison and out of the sync. That used to be counted and never shown, so the pane
    /// reported no differences and the user concluded the two tables matched.
    private func notice(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "info.circle.fill")
        }
        .font(.callout)
        .foregroundStyle(CompareStatusStyle.warning)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    // MARK: - Entries

    @ViewBuilder
    private func entryList(_ plan: DataComparePlan) -> some View {
        if let summary = plan.summary {
            let entries = summary.entries.filter { filter.matches($0) }
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("No Rows Match", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("Change the filter to see the other rows.")
                }
            } else {
                List(entries) { entry in
                    CompareRowDiffEntryView(
                        entry: entry,
                        isIncluded: rowBinding(entry, plan: plan)
                    )
                }
                .listStyle(.inset)
            }
        } else {
            ContentUnavailableView {
                Label("Not Compared Yet", systemImage: "arrow.clockwise")
            } description: {
                Text(notComparedDescription(for: plan))
            }
        }
    }

    /// The plan's own refusal first, then whatever is keeping Compare itself unavailable, and only
    /// then the generic invitation. A dimmed action with no reason is what the HIG asks an app not
    /// to leave a user holding.
    private func notComparedDescription(for plan: DataComparePlan) -> String {
        plan.unavailableReason
            ?? session.compareDisabledReason
            ?? String(localized: "Include this table and compare again to see its rows.")
    }

    // MARK: - Bindings

    private func keyBinding(_ column: String, plan: DataComparePlan) -> Binding<Bool> {
        Binding(
            get: { plan.isKeyColumn(column) },
            set: { _ in session.toggleKeyColumn(column, for: plan.id) }
        )
    }

    private func comparedBinding(_ column: String) -> Binding<Bool> {
        Binding(
            get: { session.isColumnCompared(column) },
            set: { _ in session.toggleComparedColumn(column) }
        )
    }

    private func rowBinding(_ entry: RowDiffEntry, plan: DataComparePlan) -> Binding<Bool> {
        Binding(
            get: { session.isRowIncluded(entry, in: plan) },
            set: { session.setRowIncluded($0, entry: entry, planId: plan.id) }
        )
    }

    // MARK: - Summaries

    private func nonKeyColumns(_ plan: DataComparePlan) -> [String] {
        plan.columns.filter { !plan.isKeyColumn($0) }
    }

    private func keySummary(_ plan: DataComparePlan) -> String {
        guard !plan.keyColumns.isEmpty else { return String(localized: "None chosen") }
        return plan.keyColumns.joined(separator: ", ")
    }

    private func comparedSummary(_ plan: DataComparePlan) -> String {
        let excluded = nonKeyColumns(plan).filter { !session.isColumnCompared($0) }
        guard !excluded.isEmpty else { return String(localized: "All") }
        return String(format: String(localized: "%d left out"), excluded.count)
    }
}

internal struct CompareRowDiffEntryView: View {
    internal let entry: RowDiffEntry
    @Binding internal var isIncluded: Bool

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    internal var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Toggle(String(localized: "Include this row"), isOn: $isIncluded)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(entry.kind == .identical)
                    .accessibilityIdentifier("compare.rows.include.\(entry.id.uuidString)")

                Label {
                    Text(CompareStatusStyle.title(for: entry.kind))
                } icon: {
                    Image(systemName: CompareStatusStyle.symbolName(for: entry.kind))
                }
                .font(.caption)
                .foregroundStyle(kindTint)

                Text(entry.keyDescription)
                    .font(ThemeEngine.shared.valueFontSwiftUI)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }

            ForEach(entry.cellDifferences, id: \.column) { difference in
                cellDifferenceRow(difference)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(rowBackground)
    }

    private func cellDifferenceRow(_ difference: CellDifference) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(difference.column)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(Self.describe(difference.sourceValue))
                .font(ThemeEngine.shared.valueFontSwiftUI)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(Self.describe(difference.targetValue))
                .font(ThemeEngine.shared.valueFontSwiftUI)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text(difference.rule.displayName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var kindTint: Color {
        guard !differentiateWithoutColor else { return .primary }
        return CompareStatusStyle.tint(for: entry.kind)
    }

    private var rowBackground: Color {
        guard !differentiateWithoutColor else { return .clear }
        return CompareStatusStyle.rowTint(for: entry.kind)
    }

    private static func describe(_ value: PluginCellValue) -> String {
        switch value {
        case .null:
            return "NULL"
        case .text(let text):
            return text
        case .bytes(let data):
            return String(format: String(localized: "%d bytes"), data.count)
        }
    }
}
