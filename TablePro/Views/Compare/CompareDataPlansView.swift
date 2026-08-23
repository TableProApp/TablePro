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

import SwiftUI

internal struct CompareDataPlansView: View {
    @Bindable internal var session: CompareSyncSession
    internal let onCompare: () -> Void

    @State private var sortOrder = [KeyPathComparator(\DataComparePlan.id)]

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    internal var body: some View {
        if session.dataPlans.isEmpty {
            emptyState
        } else {
            plansTable
        }
    }

    // MARK: - Table

    private var plansTable: some View {
        Table(
            session.dataPlans.sorted(using: sortOrder),
            selection: $session.selectedPlanId,
            sortOrder: $sortOrder
        ) {
            TableColumn("Include") { plan in
                Toggle(String(localized: "Include this table in the comparison"), isOn: enabledBinding(plan))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(!plan.isComparable)
                    .help(plan.unavailableReason ?? String(localized: "Include this table in the comparison"))
                    .accessibilityIdentifier("compare.plans.include.\(plan.id)")
            }
            .width(min: 56, ideal: 64)

            TableColumn("Table", value: \.id) { plan in
                Text(plan.id)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(plan.id)
            }

            TableColumn("Key") { plan in
                keyCell(plan)
            }

            TableColumn("Insert") { plan in
                countCell(plan.summary?.insertCount, kind: .insert)
            }

            TableColumn("Update") { plan in
                countCell(plan.summary?.updateCount, kind: .update)
            }

            TableColumn("Delete") { plan in
                countCell(plan.summary?.deleteCount, kind: .delete)
            }

            TableColumn("Same") { plan in
                countCell(plan.summary?.identicalCount, kind: .identical)
            }
        }
        .contextMenu(forSelectionType: DataComparePlan.ID.self) { selection in
            planCommands(for: selection)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            selectionHeader
        }
    }

    @ViewBuilder
    private func planCommands(for selection: Set<String>) -> some View {
        let comparable = session.dataPlans
            .filter { selection.contains($0.id) && $0.isComparable }
            .map { $0.id }
        Button("Include") {
            for id in comparable {
                session.setPlanEnabled(true, for: id)
            }
        }
        .disabled(comparable.isEmpty)
        Button("Exclude") {
            for id in comparable {
                session.setPlanEnabled(false, for: id)
            }
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

    private var selectionSummary: String {
        String(
            format: String(localized: "%1$d of %2$d tables will be compared."),
            enabledPlanCount, session.dataPlans.count
        )
    }

    // MARK: - Cells

    @ViewBuilder
    private func keyCell(_ plan: DataComparePlan) -> some View {
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

    private func enabledBinding(_ plan: DataComparePlan) -> Binding<Bool> {
        Binding(
            get: { plan.isEnabled },
            set: { session.setPlanEnabled($0, for: plan.id) }
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Tables Yet", systemImage: "tablecells")
        } description: {
            Text("Compare lists the tables both sides share. Choose the tables to compare, then press Compare.")
        } actions: {
            Button("Compare", action: onCompare)
                .disabled(!session.canCompare)
                .accessibilityIdentifier("compare.plans.compare")
        }
    }
}
