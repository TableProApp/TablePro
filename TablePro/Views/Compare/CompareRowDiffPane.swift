//
//  CompareRowDiffPane.swift
//  TablePro
//
//  The selected table's scope, and the rows its comparison found.
//
//  The row list is a capped preview, never the whole difference: the script is
//  built from a fresh streamed pass. Anywhere the cap, the row limit or a filter
//  is in play the pane says so, because a list that silently stops looks like a
//  smaller difference.
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
    case conflict

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
        case .conflict:
            return String(localized: "Outside Filter")
        }
    }

    internal func matches(_ entry: RowDiffEntry) -> Bool {
        switch self {
        case .all:
            return true
        case .difference:
            return entry.kind.isDifference
        case .insert:
            return entry.kind == .insert
        case .update:
            return entry.kind == .update
        case .delete:
            return entry.kind == .delete
        case .same:
            return entry.kind == .identical
        case .conflict:
            return entry.kind == .conflict
        }
    }

    /// Matching rows are retained apart from differences, so a table of mostly identical rows can
    /// never crowd a difference out of the preview, and Same and All Rows still list rows.
    internal func entries(in summary: DataDiffSummary) -> [RowDiffEntry] {
        switch self {
        case .all:
            return summary.entries + summary.identicalEntries
        case .same:
            return summary.identicalEntries
        case .difference, .insert, .update, .delete, .conflict:
            return summary.entries.filter(matches)
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
            CompareTableScopeEditor(session: session, plan: plan)
            if session.needsRecompare {
                recompareNotice
            }
            Divider()
            reviewBar(plan)
            notices(for: plan)
            Divider()
            rows(for: plan)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Review bar

    private func reviewBar(_ plan: DataComparePlan) -> some View {
        let listed = plan.summary.map { filter.entries(in: $0) } ?? []
        return HStack(spacing: 8) {
            Picker(String(localized: "Show"), selection: $filter) {
                ForEach(availableFilters(for: plan), id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .fixedSize()
            .accessibilityIdentifier("compare.rows.show")

            Spacer(minLength: 0)

            if let summary = plan.summary {
                Text(inclusionSummary(plan: plan, summary: summary))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Menu(String(localized: "Include")) {
                Button("Include Every Listed Row") {
                    session.setRowsIncluded(true, entries: listed, planId: plan.id)
                }
                Button("Exclude Every Listed Row") {
                    session.setRowsIncluded(false, entries: listed, planId: plan.id)
                }
            }
            .fixedSize()
            .disabled(!listed.contains { $0.kind.isDifference } || !session.canChangeSetup)
            .accessibilityIdentifier("compare.rows.includeMenu")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func availableFilters(for plan: DataComparePlan) -> [RowDiffFilter] {
        let showsConflicts = (plan.summary?.conflictCount ?? 0) > 0 || filter == .conflict
        return RowDiffFilter.allCases.filter { $0 != .conflict || showsConflicts }
    }

    private func inclusionSummary(plan: DataComparePlan, summary: DataDiffSummary) -> String {
        let listed = summary.entries.filter { $0.kind.isDifference }
        let included = listed.filter { !plan.excludedRowKeys.contains($0.keyIdentity) }.count
        return String(
            format: String(localized: "%1$d of %2$d listed differences included"),
            included, listed.count
        )
    }

    private var recompareNotice: some View {
        HStack(spacing: 8) {
            Label {
                Text("Some included tables have not been compared with their current settings.")
            } icon: {
                Image(systemName: "exclamationmark.arrow.circlepath")
            }
            .font(.callout)
            .foregroundStyle(CompareStatusStyle.warning)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Compare", action: onCompare)
                .disabled(!session.canCompare)
                .accessibilityIdentifier("compare.rows.recompare")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Notices

    /// Names the last key both sides were read past, because that value is what the user puts in
    /// the table's filter to read the next stretch. Without it a row limit is a dead end: the pane
    /// says the answer is partial and gives no way to continue it.
    private func rowLimitNotice(for summary: DataDiffSummary) -> String {
        guard let resumeKey = summary.resumeKey else {
            return String(
                format: String(
                    localized: "Compared %@ keys in key order. Rows past the limit were not read on either side, and rows with NULL in a key column are not read under a limit."
                ),
                summary.comparedKeyCount.formatted()
            )
        }
        return String(
            format: String(
                localized: "Compared %1$@ keys in key order, up to %2$@. Filter both sides past that key for the next rows. NULL keys are not read under a limit."
            ),
            summary.comparedKeyCount.formatted(),
            KeyOrdering.description(of: resumeKey)
        )
    }

    @ViewBuilder
    private func notices(for plan: DataComparePlan) -> some View {
        if let failure = plan.comparisonFailure {
            notice(failure, systemImage: "exclamationmark.octagon.fill")
        }
        if let summary = plan.summary {
            if summary.stoppedAtRowLimit {
                notice(rowLimitNotice(for: summary), systemImage: "info.circle.fill")
            }
            if summary.truncatedEntries {
                notice(
                    String(localized: "This list is a capped preview. Apply covers every difference, not only the rows listed here."),
                    systemImage: "info.circle.fill"
                )
            }
            if summary.skippedNullKeyCount > 0 {
                notice(
                    String(
                        format: String(
                            localized: "%d rows hold NULL in a key column and were left out. Choose a key with no NULLs to compare them."
                        ),
                        summary.skippedNullKeyCount
                    ),
                    systemImage: "info.circle.fill"
                )
            }
            if summary.conflictCount > 0 {
                notice(
                    String(
                        format: String(
                            localized: "%d rows exist on the other side outside its filter. They are never written. Widen the filter to sync them."
                        ),
                        summary.conflictCount
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
            }
            if filter == .same || filter == .all, summary.identicalCount > summary.identicalEntries.count {
                notice(
                    String(
                        format: String(localized: "%1$d rows match. The first %2$d are listed."),
                        summary.identicalCount, summary.identicalEntries.count
                    ),
                    systemImage: "info.circle.fill"
                )
            }
        }
    }

    private func notice(_ text: String, systemImage: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.callout)
        .foregroundStyle(CompareStatusStyle.warning)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    // MARK: - Rows

    @ViewBuilder
    private func rows(for plan: DataComparePlan) -> some View {
        if let summary = plan.summary {
            let entries = filter.entries(in: summary)
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("No Rows Match", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("Change the filter to see the other rows.")
                }
            } else {
                CompareRowGrid(session: session, plan: plan, filter: filter, entries: entries)
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
    /// then the generic invitation.
    private func notComparedDescription(for plan: DataComparePlan) -> String {
        plan.unavailableReason
            ?? plan.comparisonFailure
            ?? session.compareDisabledReason
            ?? String(localized: "Include this table and compare again to see its rows.")
    }
}
