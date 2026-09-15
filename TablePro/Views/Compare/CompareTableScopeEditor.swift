//
//  CompareTableScopeEditor.swift
//  TablePro
//
//  The selected table's scope: which columns identify a row, which take part in
//  the comparison, which rows are read, and how many.
//
//  It follows the selection the way an inspector does. A filter commits on
//  Return or when its field loses focus, so typing half a condition does not
//  throw the table's answer away one keystroke at a time.
//

import SwiftUI

internal struct CompareTableScopeEditor: View {
    @ObservedObject internal var session: CompareSyncSession
    internal let plan: DataComparePlan

    private enum RowLimitMode: Hashable {
        case all
        case first
    }

    private static let defaultRowLimit = 1_000

    @State private var sourceFilterDraft = ""
    @State private var targetFilterDraft = ""
    /// Which table the drafts were typed for. Selecting another table changes the plan and resigns
    /// the field in one update, so a commit that did not name its own table wrote one table's
    /// half-typed filter onto another.
    @State private var draftPlanId = ""
    @State private var focusedField: UUID?
    @State private var sourceFieldIdentity = UUID()
    @State private var targetFieldIdentity = UUID()
    @State private var sourceCompletion: RawSQLFilterCompletionProvider?
    @State private var targetCompletion: RawSQLFilterCompletionProvider?

    internal var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                keyColumnsMenu
                comparedColumnsMenu
                rowLimitControl
                Spacer(minLength: 0)
            }

            filterField(
                title: plan.scope.usesSameFilterForTarget
                    ? String(localized: "Filter")
                    : String(localized: "Source filter"),
                text: $sourceFilterDraft,
                identity: sourceFieldIdentity,
                completion: sourceCompletion,
                commit: commitSourceFilter
            )

            Toggle("Use the same filter for the target", isOn: sameFilterBinding)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("compare.rows.sameFilter")

            if !plan.scope.usesSameFilterForTarget {
                filterField(
                    title: String(localized: "Target filter"),
                    text: $targetFilterDraft,
                    identity: targetFieldIdentity,
                    completion: targetCompletion,
                    commit: commitTargetFilter
                )
            }

            if let error = plan.scope.filterValidationError {
                Label {
                    Text(error)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.callout)
                .foregroundStyle(CompareStatusStyle.warning)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text("A column left out of the comparison is still written on insert and update. A filter and a row limit read only the rows they select, on both sides.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .disabled(!session.canChangeSetup)
        .onAppear(perform: prepare)
        .onChange(of: plan.id) { _ in
            commitSourceFilter()
            commitTargetFilter()
            prepare()
        }
        .onChange(of: plan.scope.sourceFilter) { _ in syncDraftsFromScope() }
        .onChange(of: plan.scope.targetFilter) { _ in syncDraftsFromScope() }
        .onValueChange(of: focusedField) { previous, current in
            if previous == sourceFieldIdentity, current != sourceFieldIdentity {
                commitSourceFilter()
            }
            if previous == targetFieldIdentity, current != targetFieldIdentity {
                commitTargetFilter()
            }
        }
    }

    // MARK: - Columns

    private var keyColumnsMenu: some View {
        columnMenu(
            title: String(localized: "Key columns"),
            summary: plan.keyColumns.isEmpty
                ? String(localized: "None chosen")
                : plan.keyColumns.joined(separator: ", "),
            systemImage: "key",
            identifier: "compare.rows.keyColumns"
        ) {
            ForEach(plan.columnNames, id: \.self) { column in
                Toggle(column, isOn: Binding(
                    get: { plan.isKeyColumn(column) },
                    set: { _ in session.toggleKeyColumn(column, for: plan.id) }
                ))
            }
        }
    }

    private var comparedColumnsMenu: some View {
        let candidates = plan.columnNames.filter { !plan.isKeyColumn($0) }
        let leftOut = candidates.filter { plan.scope.isExcluded($0) }.count
        return columnMenu(
            title: String(localized: "Compared columns"),
            summary: leftOut == 0
                ? String(localized: "All")
                : String(format: String(localized: "%d left out"), leftOut),
            systemImage: "text.magnifyingglass",
            identifier: "compare.rows.comparedColumns"
        ) {
            ForEach(candidates, id: \.self) { column in
                Toggle(column, isOn: Binding(
                    get: { session.isColumnCompared(column, in: plan.id) },
                    set: { _ in session.toggleComparedColumn(column, for: plan.id) }
                ))
            }
        }
    }

    /// The label is the joined column list, so the menu truncates rather than fixing its size: a
    /// composite key pushed the next control past the pane's minimum width and out of reach.
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

    // MARK: - Row limit

    private var rowLimitControl: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Rows")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Picker(String(localized: "Rows"), selection: limitModeBinding) {
                    Text("All").tag(RowLimitMode.all)
                    Text("First").tag(RowLimitMode.first)
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("compare.rows.limitMode")

                if plan.scope.rowLimit != nil {
                    TextField(String(localized: "Row limit"), value: limitBinding, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 84)
                        .accessibilityIdentifier("compare.rows.limit")
                    Stepper(
                        String(localized: "Row limit"),
                        value: limitBinding,
                        in: 1 ... 1_000_000_000,
                        step: Self.defaultRowLimit
                    )
                    .labelsHidden()
                    Text("in key order")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
    }

    private var limitModeBinding: Binding<RowLimitMode> {
        Binding(
            get: { plan.scope.rowLimit == nil ? .all : .first },
            set: { mode in
                session.setRowLimit(mode == .all ? nil : Self.defaultRowLimit, for: plan.id)
            }
        )
    }

    private var limitBinding: Binding<Int> {
        Binding(
            get: { plan.scope.rowLimit ?? Self.defaultRowLimit },
            set: { session.setRowLimit($0, for: plan.id) }
        )
    }

    // MARK: - Filter

    private func filterField(
        title: String,
        text: Binding<String>,
        identity: UUID,
        completion: RawSQLFilterCompletionProvider?,
        commit: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            FilterValueTextField(
                text: text,
                focusedId: $focusedField,
                identity: identity,
                placeholder: String(localized: "A SQL condition, such as status = 'active'"),
                completionSource: completion.map { .sqlTokens($0) } ?? .staticValues([]),
                onSubmit: commit
            )
        }
    }

    private var sameFilterBinding: Binding<Bool> {
        Binding(
            get: { plan.scope.usesSameFilterForTarget },
            set: { same in
                commitSourceFilter()
                session.setUsesSameFilterForTarget(same, for: plan.id)
                targetFilterDraft = same ? "" : sourceFilterDraft
            }
        )
    }

    /// Committed against the table the draft was typed for, not the one now selected: selecting
    /// another table resigns the field in the same update that changes the plan.
    private func commitSourceFilter() {
        guard !draftPlanId.isEmpty else { return }
        session.setSourceFilter(sourceFilterDraft, for: draftPlanId)
    }

    private func commitTargetFilter() {
        guard !draftPlanId.isEmpty,
              session.dataPlans.first(where: { $0.id == draftPlanId })?.scope.usesSameFilterForTarget == false
        else { return }
        session.setTargetFilter(targetFilterDraft, for: draftPlanId)
    }

    private func prepare() {
        draftPlanId = plan.id
        sourceFilterDraft = plan.scope.sourceFilter
        targetFilterDraft = plan.scope.targetFilter ?? ""
        sourceCompletion = completionProvider(for: session.source)
        targetCompletion = completionProvider(for: session.target)
    }

    private func syncDraftsFromScope() {
        if focusedField != sourceFieldIdentity {
            sourceFilterDraft = plan.scope.sourceFilter
        }
        if focusedField != targetFieldIdentity {
            targetFilterDraft = plan.scope.targetFilter ?? ""
        }
    }

    private func completionProvider(for endpoint: DatabaseEndpoint?) -> RawSQLFilterCompletionProvider? {
        guard let endpoint else { return nil }
        return RawSQLFilterCompletionProvider(
            schemaProvider: SchemaProviderRegistry.shared.getOrCreate(for: endpoint.scope),
            databaseType: endpoint.databaseType,
            tableName: plan.table
        )
    }
}
