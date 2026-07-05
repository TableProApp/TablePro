//
//  FilterRowView.swift
//  TablePro
//

import SwiftUI

struct FilterRowView: View {
    @Binding var filter: TableFilter
    let columns: [String]
    let completions: [String]
    var enumValuesByColumn: [String: [String]] = [:]
    var rawSQLCompletionProvider: RawSQLFilterCompletionProvider?
    let onAdd: () -> Void
    let onDuplicate: () -> Void
    let onRemove: () -> Void
    let onApply: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    @Binding var focusedFilterId: UUID?

    private let rowButtonGlyphSize: CGFloat = 14

    private var pickerEligibleOperators: Set<FilterOperator> {
        [.equal, .notEqual]
    }

    private var rawSQLCompletionSource: FilterCompletionSource {
        if let rawSQLCompletionProvider {
            return .sqlTokens(rawSQLCompletionProvider)
        }
        return .staticValues(completions)
    }

    private var allowedValuesForCurrentColumn: [String]? {
        guard !filter.isRawSQL,
              let values = enumValuesByColumn[filter.columnName],
              !values.isEmpty else { return nil }
        return values
    }

    var body: some View {
        HStack(spacing: 4) {
            enabledToggle

            Group {
                columnPicker

                if !filter.isRawSQL {
                    operatorPicker
                }

                valueFields
            }
            .opacity(filter.isEnabled ? 1 : 0.5)

            rowButtons
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .contextMenu { rowContextMenu }
    }

    private var enabledToggle: some View {
        Toggle("", isOn: $filter.isEnabled)
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(String(localized: "Enable filter"))
            .accessibilityValue(filter.isEnabled ? String(localized: "Active") : String(localized: "Inactive"))
            .help(String(localized: "Include this filter when applying"))
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
        .accessibilityValue(filter.isRawSQL ? String(localized: "Raw SQL") : filter.columnName)
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
        .accessibilityValue(filter.filterOperator.displayName)
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
                completionSource: rawSQLCompletionSource,
                allowsMultiLine: true,
                onSubmit: onSubmit,
                onCancel: onCancel
            )
            .accessibilityLabel(String(localized: "WHERE clause"))
        } else if filter.filterOperator.requiresValue {
            if let allowedValues = allowedValuesForCurrentColumn,
               pickerEligibleOperators.contains(filter.filterOperator) {
                enumValuePicker(allowedValues: allowedValues)
            } else {
                FilterValueTextField(
                    text: $filter.value,
                    focusedId: $focusedFilterId,
                    identity: filter.id,
                    placeholder: String(localized: "Value"),
                    completionSource: .staticValues(completions),
                    onSubmit: onSubmit,
                    onCancel: onCancel
                )
                .frame(minWidth: 80)
                .accessibilityLabel(String(localized: "Filter value"))
            }

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
            Spacer(minLength: 0)
        }
    }

    private var rowButtons: some View {
        HStack(spacing: 4) {
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .frame(width: rowButtonGlyphSize, height: rowButtonGlyphSize)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(String(localized: "Add filter"))
            .help(String(localized: "Add filter row"))

            Button(action: onRemove) {
                Image(systemName: "minus")
                    .frame(width: rowButtonGlyphSize, height: rowButtonGlyphSize)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(String(localized: "Remove filter"))
            .help(String(localized: "Remove filter row"))
        }
    }

    @ViewBuilder
    private var rowContextMenu: some View {
        Button {
            onApply()
        } label: {
            Label(String(localized: "Apply Only This Filter"), systemImage: "checkmark.circle")
        }
        .disabled(!filter.isValid)

        Divider()

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

    @ViewBuilder
    private func enumValuePicker(allowedValues: [String]) -> some View {
        let isDrift = !filter.value.isEmpty && !allowedValues.contains(filter.value)
        Picker("", selection: $filter.value) {
            ForEach(allowedValues, id: \.self) { value in
                Text(value).tag(value)
            }
            if isDrift {
                Divider()
                Text(filter.value).tag(filter.value)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(minWidth: 100)
        .labelsHidden()
        .accessibilityLabel(String(localized: "Filter value"))
    }

    private struct OperatorMenuLabel: View {
        let op: FilterOperator

        var body: some View {
            Text(op.symbol.isEmpty ? op.displayName : "\(op.symbol)  \(op.displayName)")
                .accessibilityLabel(op.displayName)
        }
    }
}
