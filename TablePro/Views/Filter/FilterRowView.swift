//
//  FilterRowView.swift
//  TablePro
//
//  Single filter row with native macOS controls.
//

import SwiftUI

struct FilterRowView: View {
    @Binding var filter: TableFilter
    let columns: [String]
    let databaseType: DatabaseType
    let onAdd: () -> Void
    let onDuplicate: () -> Void
    let onRemove: () -> Void
    let onSubmit: () -> Void
    var shouldFocus: Bool = false

    private static let sqlKeywords = [
        "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN",
        "IS NULL", "IS NOT NULL", "EXISTS",
        "CASE", "WHEN", "THEN", "ELSE", "END",
    ]

    private var rawSQLCompletions: [String] {
        let langName = PluginManager.shared.queryLanguageName(for: databaseType)
        if langName == "SQL" || langName == "CQL" || langName == "PartiQL" {
            return columns + Self.sqlKeywords
        }
        return columns
    }

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

    // MARK: - Column Picker

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

    // MARK: - Operator Picker

    private var operatorPicker: some View {
        Picker("", selection: $filter.filterOperator) {
            ForEach(FilterOperator.allCases) { op in
                Text(op.displayName).tag(op)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
        .labelsHidden()
        .accessibilityLabel(String(localized: "Filter operator"))
        .help(String(localized: "Select filter operator"))
    }

    // MARK: - Value Fields

    @ViewBuilder
    private var valueFields: some View {
        if filter.isRawSQL {
            CompletionTextField(
                text: Binding(
                    get: { filter.rawSQL ?? "" },
                    set: { filter.rawSQL = $0 }
                ),
                placeholder: "e.g. id = 1",
                completions: rawSQLCompletions,
                shouldFocus: shouldFocus,
                allowsMultiLine: true,
                onSubmit: onSubmit
            )
            .accessibilityLabel(String(localized: "WHERE clause"))
        } else if filter.filterOperator.requiresValue {
            CompletionTextField(
                text: $filter.value,
                placeholder: String(localized: "Value"),
                completions: columns,
                shouldFocus: shouldFocus,
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
                .frame(minWidth: 80)
                .accessibilityLabel(String(localized: "Second filter value"))
                .onSubmit { onSubmit() }
            }
        } else {
            Text("—")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(minWidth: 80, alignment: .leading)
        }
    }

    // MARK: - Row Buttons (+/-)

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

    // MARK: - Context Menu

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
}
