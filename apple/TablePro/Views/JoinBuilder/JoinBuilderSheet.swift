//
//  JoinBuilderSheet.swift
//  TablePro
//

import SwiftUI

internal struct JoinBuilderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject internal var model: JoinBuilderViewModel
    internal let onOpen: (String) -> Void

    internal var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 860, height: 620)
        .task { await model.loadIfNeeded() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Build Join Query"))
                .font(.title3.weight(.semibold))
            Text(model.scopeDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .loading:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(String(localized: "Reading the tables…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            UnavailableStateView {
                Label(String(localized: "Cannot Read the Tables"), systemImage: "exclamationmark.triangle")
            } description: {
                RevealedTextView(message)
            } actions: {
                Button(String(localized: "Try Again")) { Task { await model.load() } }
            }
        case .loaded:
            if model.graph.columnsByTable.isEmpty {
                UnavailableStateView {
                    Label(String(localized: "No Tables"), systemImage: "tray")
                } description: {
                    Text(String(localized: "This database reports no tables to join."))
                }
            } else {
                HStack(spacing: 0) {
                    JoinBuilderTableList(model: model)
                        .frame(width: 260)
                    Divider()
                    JoinBuilderDetails(model: model)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var footer: some View {
        DialogFooter {
            statusText
        } actions: {
            Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Open in Query Tab")) {
                guard let sql = model.sql else { return }
                onOpen(sql)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.sql == nil)
            .accessibilityIdentifier("join-builder-open")
        }
        .padding(20)
    }

    @ViewBuilder
    private var statusText: some View {
        let crossJoined = model.crossJoinedTables
        if model.loadState == .loaded, model.draft.isEmpty {
            Text(String(localized: "Pick the tables to join. Their foreign keys become the join conditions."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } else if !crossJoined.isEmpty {
            Text(String(
                format: String(localized: "No foreign key links %@ to the tables before it, so it is cross joined."),
                ListFormatter.localizedString(byJoining: crossJoined)
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
    }
}

private struct JoinBuilderTableList: View {
    @ObservedObject var model: JoinBuilderViewModel

    var body: some View {
        VStack(spacing: 0) {
            NativeSearchField(
                text: $model.tableFilter,
                placeholder: String(localized: "Filter Tables"),
                controlSize: .small,
                accessibilityIdentifier: "join-builder-table-filter"
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            List {
                ForEach(model.filteredTables, id: \.self) { table in
                    tableRow(table)
                    if model.isIncluded(table) {
                        ForEach(model.graph.columns(of: table), id: \.self) { column in
                            columnRow(JoinColumnRef(table: table, column: column))
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func tableRow(_ table: String) -> some View {
        Toggle(isOn: Binding(
            get: { model.isIncluded(table) },
            set: { model.setIncluded($0, table: table) }
        )) {
            Label(table, systemImage: "tablecells")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("join-builder-table-\(table)")
    }

    private func columnRow(_ column: JoinColumnRef) -> some View {
        Toggle(isOn: Binding(
            get: { model.isSelected(column) },
            set: { model.setSelected($0, column: column) }
        )) {
            Text(column.column)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .toggleStyle(.checkbox)
        .padding(.leading, 22)
        .accessibilityLabel(String(format: String(localized: "%1$@ column of %2$@"), column.column, column.table))
    }
}

private struct JoinBuilderDetails: View {
    @ObservedObject var model: JoinBuilderViewModel

    var body: some View {
        Form {
            Section(String(localized: "Joins")) {
                if model.draft.isEmpty {
                    Text(String(localized: "No tables picked"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.draft.tables.enumerated()), id: \.element.id) { index, table in
                        joinRow(index: index, table: table)
                    }
                }
            }
            Section(String(localized: "Filters")) {
                ForEach(model.draft.filters) { filter in
                    filterRow(filter)
                }
                Button(String(localized: "Add Filter")) { model.addFilter() }
                    .disabled(model.draft.isEmpty)
            }
            Section(String(localized: "SQL Preview")) {
                HighlightedSQLTextView(
                    sql: model.sql ?? "",
                    databaseType: model.connection.type,
                    accessibilityIdentifier: "join-builder-sql",
                    lineLayout: .fitted(maxLines: 10)
                )
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func joinRow(index: Int, table: JoinQueryDraft.Table) -> some View {
        if index == 0 {
            LabeledContent(String(localized: "From"), value: table.name)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Picker(table.name, selection: Binding(
                    get: { table.kind },
                    set: { model.setKind($0, forTableAt: index) }
                )) {
                    ForEach(JoinKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .disabled(table.condition == nil)
                Picker(String(localized: "On"), selection: Binding(
                    get: { table.condition },
                    set: { model.setCondition($0, forTableAt: index) }
                )) {
                    ForEach(model.candidates(forTableAt: index)) { relationship in
                        Text(model.conditionTitle(relationship)).tag(Optional(relationship))
                    }
                    Text(String(localized: "None (Cross Join)")).tag(JoinRelationship?.none)
                }
            }
        }
    }

    private func filterRow(_ filter: JoinFilter) -> some View {
        HStack(spacing: 8) {
            Picker(String(localized: "Column"), selection: Binding(
                get: { filter.column },
                set: { column in model.updateFilter(filter.id) { $0.column = column } }
            )) {
                ForEach(model.filterableColumns, id: \.self) { column in
                    Text(verbatim: "\(column.table).\(column.column)").tag(column)
                }
            }
            .labelsHidden()
            Picker(String(localized: "Filter operator"), selection: Binding(
                get: { filter.filterOperator },
                set: { op in model.updateFilter(filter.id) { $0.filterOperator = op } }
            )) {
                ForEach(FilterOperator.allCases) { op in
                    Text(op.displayName).tag(op)
                }
            }
            .labelsHidden()
            .fixedSize()
            if filter.filterOperator.requiresValue {
                TextField(String(localized: "Value"), text: Binding(
                    get: { filter.value },
                    set: { value in model.updateFilter(filter.id) { $0.value = value } }
                ))
                .labelsHidden()
            }
            if filter.filterOperator.requiresSecondValue {
                TextField(String(localized: "Second value"), text: Binding(
                    get: { filter.secondValue },
                    set: { value in model.updateFilter(filter.id) { $0.secondValue = value } }
                ))
                .labelsHidden()
            }
            Button {
                model.removeFilter(filter.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Remove Filter"))
            .accessibilityLabel(String(localized: "Remove Filter"))
        }
    }
}
