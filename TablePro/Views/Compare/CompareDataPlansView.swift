//
//  CompareDataPlansView.swift
//  TablePro
//
//  The tables a data comparison can walk, and the counts it found.
//
//  A plan starts excluded on purpose. A first Compare that opted every table in
//  would stream every row of every table before the user had chosen anything, so
//  the list says why it is empty rather than looking broken.
//
//  Search and grouping are the session's, not this view's: the same toolbar
//  controls drive both modes, so they have to mean the same thing in both.
//

import SwiftUI

internal struct CompareDataPlansView: View {
    @Bindable internal var session: CompareSyncSession
    internal let onCompare: () -> Void

    @State private var sortOrder = [KeyPathComparator(\CompareDataPlanRow.tableName)]

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    internal var body: some View {
        VStack(spacing: 0) {
            CompareMessageBanner(session: session)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
        if session.dataPlans.isEmpty {
            emptyState
        } else {
            planList
        }
    }

    // MARK: - List

    private var planList: some View {
        let visible = CompareDataPlanGrouping.matching(session.dataPlans, searchText: session.searchText)
        return VStack(spacing: 0) {
            selectionHeader
            Divider()
            if visible.isEmpty {
                ContentUnavailableView.search(text: session.searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                plansTable(visible)
            }
        }
    }

    private func plansTable(_ visible: [DataComparePlan]) -> some View {
        let groups = CompareDataPlanGrouping.groups(
            from: visible, grouping: session.grouping, sortedUsing: sortOrder
        )
        let flatRows = CompareDataPlanGrouping.rows(from: visible, sortedUsing: sortOrder)

        return Table(of: CompareDataPlanRow.self, selection: $session.selectedPlanId, sortOrder: $sortOrder) {
            TableColumn("Include") { row in
                includeCell(row)
            }
            .width(min: 56, ideal: 64)

            TableColumn("Table", value: \.tableName) { row in
                Text(row.tableName)
                    .fontWeight(row.isGroup ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.tableName)
            }

            TableColumn("Key") { row in
                keyCell(row)
            }

            TableColumn("Insert") { row in
                countCell(row.insertCount, kind: .insert)
            }

            TableColumn("Update") { row in
                countCell(row.updateCount, kind: .update)
            }

            TableColumn("Delete") { row in
                countCell(row.deleteCount, kind: .delete)
            }

            TableColumn("Same") { row in
                countCell(row.identicalCount, kind: .identical)
            }
        } rows: {
            if session.grouping == .none {
                ForEach(flatRows) { row in
                    SwiftUI.TableRow(row)
                }
            } else {
                ForEach(groups) { group in
                    DisclosureTableRow(group.header) {
                        ForEach(group.rows) { row in
                            SwiftUI.TableRow(row)
                        }
                    }
                }
            }
        }
        .contextMenu(forSelectionType: CompareDataPlanRow.ID.self) { selection in
            planCommands(for: selection, groups: groups)
        }
    }

    @ViewBuilder
    private func planCommands(for selection: Set<String>, groups: [CompareDataPlanGroup]) -> some View {
        let selected = Set(CompareDataPlanGrouping.planIds(in: selection, groups: groups))
        let comparable = session.dataPlans
            .filter { selected.contains($0.id) && $0.isComparable }
            .map { $0.id }
        Button("Include") {
            setEnabled(true, forIds: comparable)
        }
        .disabled(comparable.isEmpty)
        Button("Exclude") {
            setEnabled(false, forIds: comparable)
        }
        .disabled(comparable.isEmpty)
        Divider()
        Button("Include Every Table") {
            session.setAllPlansEnabled(true)
        }
        Button("Exclude Every Table") {
            session.setAllPlansEnabled(false)
        }
    }

    // MARK: - Header

    private var selectionHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(selectionSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Menu(String(localized: "Select")) {
                    Button("All") {
                        session.setAllPlansEnabled(true)
                    }
                    Button("None") {
                        session.setAllPlansEnabled(false)
                    }
                }
                .fixedSize()
                .accessibilityIdentifier("compare.plans.select")
            }
            if enabledPlanCount == 0 {
                Text("Tables start out of the comparison so a first run cannot stream every row.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var enabledPlanCount: Int {
        session.dataPlans.filter { $0.isEnabled }.count
    }

    /// A total of one has to read "of 1 table". The counted noun follows the second argument, which
    /// a plural variation on the format string cannot reach, so the sentence carries its own
    /// singular the way the app's other counted confirmations do.
    private var selectionSummary: String {
        let total = session.dataPlans.count
        guard total != 1 else {
            return String(format: String(localized: "%d of 1 table will be compared."), enabledPlanCount)
        }
        return String(
            format: String(localized: "%1$d of %2$d tables will be compared."),
            enabledPlanCount, total
        )
    }

    // MARK: - Cells

    /// A group is three-valued: some of its tables in, some out. macOS has no mixed state for a
    /// `Toggle`, so a plain `Bool` would render "five of six" exactly like "none".
    @ViewBuilder
    private func includeCell(_ row: CompareDataPlanRow) -> some View {
        switch row.kind {
        case .group(let memberIds):
            if !memberIds.isEmpty {
                TristateCheckbox(
                    state: groupInclusionState(memberIds),
                    accessibilityLabel: String(localized: "Include every table in this group"),
                    accessibilityValue: groupInclusionValue(memberIds)
                ) {
                    setEnabled(groupInclusionState(memberIds) != .checked, forIds: memberIds)
                }
                .accessibilityIdentifier("compare.plans.includeGroup.\(row.id)")
            }
        case .plan(let plan):
            Toggle(String(localized: "Include this table in the comparison"), isOn: enabledBinding(plan))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!plan.isComparable)
                .help(plan.unavailableReason ?? String(localized: "Include this table in the comparison"))
                .accessibilityIdentifier("compare.plans.include.\(plan.id)")
        }
    }

    @ViewBuilder
    private func keyCell(_ row: CompareDataPlanRow) -> some View {
        if let plan = row.plan {
            planKeyCell(plan)
        }
    }

    @ViewBuilder
    private func planKeyCell(_ plan: DataComparePlan) -> some View {
        if let reason = plan.unavailableReason {
            Label {
                Text(reason)
                    .lineLimit(1)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(differentiateWithoutColor ? .primary : CompareStatusStyle.warning)
            .help(reason)
        } else {
            Text(plan.keyColumns.joined(separator: ", "))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(plan.keyColumns.joined(separator: ", "))
        }
    }

    /// A table that has not been compared shows nothing rather than a zero: no difference found
    /// and no comparison run are not the same answer.
    @ViewBuilder
    private func countCell(_ value: Int?, kind: RowDiffKind) -> some View {
        if let value {
            Text(value, format: .number)
                .monospacedDigit()
                .foregroundStyle(countTint(value, kind: kind))
        }
    }

    private func countTint(_ value: Int, kind: RowDiffKind) -> Color {
        guard value > 0 else { return .secondary }
        guard !differentiateWithoutColor else { return .primary }
        return CompareStatusStyle.tint(for: kind)
    }

    // MARK: - Inclusion

    private func enabledBinding(_ plan: DataComparePlan) -> Binding<Bool> {
        Binding(
            get: { plan.isEnabled },
            set: { session.setPlanEnabled($0, for: plan.id) }
        )
    }

    private func setEnabled(_ enabled: Bool, forIds ids: [String]) {
        for id in ids {
            session.setPlanEnabled(enabled, for: id)
        }
    }

    private func enabledMemberCount(_ memberIds: [String]) -> Int {
        let enabled = Set(session.dataPlans.filter { $0.isEnabled }.map { $0.id })
        return memberIds.filter { enabled.contains($0) }.count
    }

    private func groupInclusionState(_ memberIds: [String]) -> TristateCheckbox.State {
        let enabled = enabledMemberCount(memberIds)
        guard enabled > 0 else { return .unchecked }
        return enabled == memberIds.count ? .checked : .mixed
    }

    private func groupInclusionValue(_ memberIds: [String]) -> String {
        String(
            format: String(localized: "%1$d of %2$d included"),
            enabledMemberCount(memberIds), memberIds.count
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Tables Yet", systemImage: "tablecells")
        } description: {
            Text(emptyDescription)
        } actions: {
            Button("Compare", action: onCompare)
                .disabled(!session.canCompare)
                .accessibilityIdentifier("compare.plans.compare")
        }
    }

    /// Why Compare is unavailable beats a generic invitation to press it, which is what the HIG asks
    /// for when a command cannot be carried out.
    private var emptyDescription: String {
        session.compareDisabledReason
            ?? String(
                localized: "Compare lists the tables both sides share. Choose the tables to compare, then press Compare."
            )
    }
}
