//
//  ColumnValueFilterPopover.swift
//  TablePro
//

import SwiftUI

struct ColumnValueFilterPopover: View {
    let columnName: String
    let loadedRowCount: Int
    let onApply: (ColumnValueFilter?) -> Void
    let onCancel: () -> Void

    @State private var selection: ColumnValueFilterSelection

    init(
        columnName: String,
        values: [ColumnDistinctValue],
        loadedRowCount: Int,
        initialFilter: ColumnValueFilter?,
        onApply: @escaping (ColumnValueFilter?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.columnName = columnName
        self.loadedRowCount = loadedRowCount
        self.onApply = onApply
        self.onCancel = onCancel
        _selection = State(initialValue: ColumnValueFilterSelection(values: values, initialFilter: initialFilter))
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
            Text("Values from ^[\(loadedRowCount) loaded row](inflect: true)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            NativeSearchField(
                text: searchText,
                placeholder: String(localized: "Search values"),
                onSubmit: { apply() },
                focusOnAppear: true,
                accessibilityIdentifier: "value-filter-search"
            )
            HStack {
                TristateCheckbox(
                    state: TristateCheckbox.State(allEnabled: selection.allVisibleSelectedState),
                    title: selection.isSearching
                        ? String(localized: "Select All Results")
                        : String(localized: "Select All")
                ) {
                    selection.toggleAllVisible()
                }
                .disabled(selection.visibleValues.isEmpty)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var valueList: some View {
        if selection.isSearching, selection.visibleValues.isEmpty {
            UnavailableStateView.search(text: selection.searchText)
                .frame(height: 200)
        } else {
            matchingValueList
        }
    }

    private var matchingValueList: some View {
        List {
            ForEach(selection.visibleValues) { value in
                Toggle(isOn: binding(for: value)) {
                    HStack(spacing: 8) {
                        Text(value.label)
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
                .accessibilityIdentifier("value-filter-value")
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
            .disabled(!selection.canApply)
        }
        .padding(14)
    }

    private var searchText: Binding<String> {
        Binding(get: { selection.searchText }, set: { selection.setSearchText($0) })
    }

    private func binding(for value: ColumnDistinctValue) -> Binding<Bool> {
        Binding(get: { selection.isSelected(value) }, set: { selection.setSelected($0, for: value) })
    }

    /// Return in the search field arrives here directly, not through the Apply button, so it has to
    /// obey the same rule that disables the button.
    private func apply() {
        guard selection.canApply else { return }
        onApply(selection.appliedFilter)
    }
}
