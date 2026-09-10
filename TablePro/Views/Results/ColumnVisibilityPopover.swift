//
//  ColumnVisibilityPopover.swift
//  TablePro
//

import SwiftUI

struct ColumnVisibilityPopover: View {
    let columns: [GridColumnEntry]
    let hiddenColumns: Set<String>
    let onToggleColumn: (String) -> Void
    let onShowAll: () -> Void
    let onHideAll: ([String]) -> Void
    let onReset: () -> Void
    let onJumpToColumn: ((String) -> Void)?

    @State private var searchText = ""

    private var filteredColumns: [GridColumnEntry] {
        if searchText.isEmpty {
            return columns
        }
        return columns.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var columnNames: [String] {
        columns.map(\.name)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if columns.count > 5 {
                searchField
                Divider()
            }

            columnList

            Divider()

            footer
        }
        .frame(width: 300)
    }

    private var footer: some View {
        HStack {
            if let onJumpToColumn {
                Button("Jump to Column…") { onJumpToColumn(searchText) }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    .help(AppSettingsManager.shared.keyboard.shortcutHint(
                        String(localized: "Scroll to a column and put the cell cursor in it"),
                        for: .jumpToColumn
                    ))
                    .accessibilityIdentifier("column-visibility-jump")
            }
            Spacer()
            Button("Reset Columns") { onReset() }
                .buttonStyle(.link)
                .controlSize(.small)
                .help(String(localized: "Reset column widths, order, and visibility to defaults"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var headerTitle: String {
        guard !hiddenColumns.isEmpty else {
            return String(localized: "Columns")
        }
        let visible = columns.count - hiddenColumns.count
        return String(format: String(localized: "%d of %d"), visible, columns.count)
    }

    private var header: some View {
        HStack {
            Text(headerTitle)
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            Button("Show All") { onShowAll() }
                .buttonStyle(.link)
                .controlSize(.small)
                .disabled(hiddenColumns.isEmpty)

            Button("Hide All") { onHideAll(columnNames) }
                .buttonStyle(.link)
                .controlSize(.small)
                .disabled(hiddenColumns.count == columns.count)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var searchField: some View {
        NativeSearchField(
            text: $searchText,
            placeholder: String(localized: "Search columns…"),
            controlSize: .small,
            accessibilityIdentifier: "column-visibility-search"
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var columnList: some View {
        List {
            ForEach(filteredColumns) { column in
                columnRow(column)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 12))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(minHeight: 120, maxHeight: 320)
    }

    private func columnRow(_ column: GridColumnEntry) -> some View {
        Toggle(isOn: Binding(
            get: { !hiddenColumns.contains(column.name) },
            set: { _ in onToggleColumn(column.name) }
        )) {
            HStack(spacing: 8) {
                Text(column.name)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                if let typeName = column.typeName {
                    Text(typeName)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)
                }
            }
        }
        .toggleStyle(.checkbox)
    }
}
