//
//  ColumnVisibilityPopover.swift
//  TablePro
//

import SwiftUI

struct ColumnVisibilityPopover: View {
    let columns: [String]
    let hiddenColumns: Set<String>
    let onToggleColumn: (String) -> Void
    let onShowAll: () -> Void
    let onHideAll: ([String]) -> Void
    let onReset: () -> Void

    @State private var searchText = ""

    private var filteredColumns: [String] {
        if searchText.isEmpty {
            return columns
        }
        return columns.filter { $0.localizedCaseInsensitiveContains(searchText) }
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
        .frame(width: 260)
    }

    private var footer: some View {
        HStack {
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

            Button("Hide All") { onHideAll(columns) }
                .buttonStyle(.link)
                .controlSize(.small)
                .disabled(hiddenColumns.count == columns.count)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var searchField: some View {
        NativeSearchField(text: $searchText, placeholder: String(localized: "Search columns..."), controlSize: .small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    private var columnList: some View {
        List {
            ForEach(filteredColumns, id: \.self) { column in
                columnRow(column)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 12))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(minHeight: 120, maxHeight: 320)
    }

    private func columnRow(_ column: String) -> some View {
        Toggle(isOn: Binding(
            get: { !hiddenColumns.contains(column) },
            set: { _ in onToggleColumn(column) }
        )) {
            Text(column)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .toggleStyle(.checkbox)
    }
}
