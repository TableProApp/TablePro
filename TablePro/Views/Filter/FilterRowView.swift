//
//  FilterRowView.swift
//  TablePro
//

import SwiftUI

struct FilterRowView: View {
    @Binding var filter: TableFilter
    let columns: [String]
    let completions: [String]
    let onAdd: () -> Void
    let onDuplicate: () -> Void
    let onRemove: () -> Void
    let onSubmit: () -> Void
    @Binding var focusedFilterId: UUID?

    var body: some View {
        HStack(spacing: 4) {
            columnPicker

            if !filter.isRawSQL {
                operatorPicker
            }

            valueFields

            rowButtons
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .contextMenu { rowContextMenu }
    }

    private var columnPicker: some View {
        Picker("", selection: $filter.columnName) {
            Text("Raw SQL").tag(TableFilter.rawSQLColumn)
            Divider()
            ForEach(columns, id: \.self) { column in
                Text(column).tag(column)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
        .labelsHidden()
        .accessibilityLabel(String(localized: "Filter column"))
        .help(String(localized: "Select filter column"))
    }

    private var operatorPicker: some View {
        Picker("", selection: $filter.filterOperator) {
            ForEach(FilterOperator.allCases) { op in
                OperatorMenuLabel(op: op).tag(op)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
        .labelsHidden()
        .accessibilityLabel(String(localized: "Filter operator"))
        .help(String(localized: "Select filter operator"))
    }

    @ViewBuilder
    private var valueFields: some View {
        if filter.isRawSQL {
            FilterValueTextField(
                text: Binding(
                    get: { filter.rawSQL ?? "" },
                    set: { filter.rawSQL = $0 }
                ),
                focusedId: $focusedFilterId,
                identity: filter.id,
                placeholder: "e.g. id = 1",
                completions: completions,
                allowsMultiLine: true,
                onSubmit: onSubmit
            )
            .accessibilityLabel(String(localized: "WHERE clause"))
        } else if filter.filterOperator.requiresValue {
            FilterValueTextField(
                text: $filter.value,
                focusedId: $focusedFilterId,
                identity: filter.id,
                placeholder: String(localized: "Value"),
                completions: completions,
                onSubmit: onSubmit
            )
            .frame(minWidth: 80)
            .accessibilityLabel(String(localized: "Filter value"))

            if filter.filterOperator.requiresSecondValue {
                Text("and")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("Value", text: Binding(
                    get: { filter.secondValue ?? "" },
                    set: { filter.secondValue = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.callout)
                .autocorrectionDisabled(true)
                .frame(minWidth: 80)
                .accessibilityLabel(String(localized: "Second filter value"))
                .onSubmit { onSubmit() }
            }
        } else {
            Text("—")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rowButtons: some View {
        HStack(spacing: 4) {
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel(String(localized: "Add filter"))
            .help(String(localized: "Add filter row"))

            Button(action: onRemove) {
                Image(systemName: "minus")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel(String(localized: "Remove filter"))
            .help(String(localized: "Remove filter row"))
        }
    }

    @ViewBuilder
    private var rowContextMenu: some View {
        Button {
            onAdd()
        } label: {
            Label(String(localized: "Add Filter"), systemImage: "plus")
        }

        Button {
            onDuplicate()
        } label: {
            Label(String(localized: "Duplicate Filter"), systemImage: "doc.on.doc")
        }

        Divider()

        Button(role: .destructive) {
            onRemove()
        } label: {
            Label(String(localized: "Remove Filter"), systemImage: "trash")
        }
    }

    private struct OperatorMenuLabel: View {
        let op: FilterOperator

        var body: some View {
            Text(op.symbol.isEmpty ? op.displayName : "\(op.symbol)  \(op.displayName)")
                .accessibilityLabel(op.displayName)
        }
    }
}
