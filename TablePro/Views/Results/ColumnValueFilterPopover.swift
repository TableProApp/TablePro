//
//  ColumnValueFilterPopover.swift
//  TablePro
//

import SwiftUI

struct ColumnValueFilterPopover: View {
    let columnName: String
    let values: [ColumnDistinctValue]
    let loadedRowCount: Int
    let onApply: (ColumnValueFilter?) -> Void
    let onCancel: () -> Void

    @State private var checkedValues: Set<String>
    @State private var nullChecked: Bool
    @State private var searchText: String = ""

    private static let nullLabel = String(localized: "(NULL)")
    private static let emptyLabel = String(localized: "(Empty)")

    init(
        columnName: String,
        values: [ColumnDistinctValue],
        loadedRowCount: Int,
        initialFilter: ColumnValueFilter?,
        onApply: @escaping (ColumnValueFilter?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.columnName = columnName
        self.values = values
        self.loadedRowCount = loadedRowCount
        self.onApply = onApply
        self.onCancel = onCancel
        if let initialFilter {
            _checkedValues = State(initialValue: initialFilter.selectedValues)
            _nullChecked = State(initialValue: initialFilter.includesNull)
        } else {
            _checkedValues = State(initialValue: Set(values.filter { !$0.isNull }.map(\.display)))
            _nullChecked = State(initialValue: values.contains { $0.isNull })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            controls
            Divider()
            valueList
            Divider()
            footer
        }
        .frame(width: 260)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(columnName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(loadedRowsCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var loadedRowsCaption: String {
        String(format: String(localized: "Values from %d loaded rows"), loadedRowCount)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            NativeSearchField(
                text: $searchText,
                placeholder: String(localized: "Search values"),
                onSubmit: { apply() },
                focusOnAppear: true,
                accessibilityIdentifier: "value-filter-search"
            )
            HStack(spacing: 6) {
                TristateCheckbox(state: selectAllState) { toggleSelectAll() }
                Text("Select All")
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var valueList: some View {
        List {
            ForEach(filteredValues) { value in
                Toggle(isOn: binding(for: value)) {
                    HStack(spacing: 8) {
                        Text(label(for: value))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(value.isNull ? Color.secondary : Color.primary)
                        Spacer(minLength: 8)
                        Text("\(value.count)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(height: 200)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(role: .cancel) {
                onCancel()
            } label: {
                Text("Cancel")
            }
            .keyboardShortcut(.cancelAction)
            Button {
                apply()
            } label: {
                Text("Apply")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(nothingSelected)
        }
        .padding(14)
    }

    private var filteredValues: [ColumnDistinctValue] {
        guard !searchText.isEmpty else { return values }
        return values.filter { label(for: $0).localizedCaseInsensitiveContains(searchText) }
    }

    private var selectAllState: TristateCheckbox.State {
        let selected = values.filter { $0.isNull ? nullChecked : checkedValues.contains($0.display) }.count
        if selected == 0 { return .unchecked }
        if selected == values.count { return .checked }
        return .mixed
    }

    private var nothingSelected: Bool {
        checkedValues.isEmpty && !nullChecked
    }

    private func label(for value: ColumnDistinctValue) -> String {
        if value.isNull { return Self.nullLabel }
        return value.display.isEmpty ? Self.emptyLabel : value.display
    }

    private func binding(for value: ColumnDistinctValue) -> Binding<Bool> {
        if value.isNull {
            return Binding(get: { nullChecked }, set: { nullChecked = $0 })
        }
        return Binding(
            get: { checkedValues.contains(value.display) },
            set: { isOn in
                if isOn {
                    checkedValues.insert(value.display)
                } else {
                    checkedValues.remove(value.display)
                }
            }
        )
    }

    private func toggleSelectAll() {
        setAll(selectAllState != .checked)
    }

    private func setAll(_ selected: Bool) {
        if selected {
            checkedValues = Set(values.filter { !$0.isNull }.map(\.display))
            nullChecked = values.contains { $0.isNull }
        } else {
            checkedValues = []
            nullChecked = false
        }
    }

    private func apply() {
        if selectAllState == .checked {
            onApply(nil)
        } else {
            onApply(ColumnValueFilter(selectedValues: checkedValues, includesNull: nullChecked))
        }
    }
}
