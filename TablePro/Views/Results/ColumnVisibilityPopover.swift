//
//  ColumnVisibilityPopover.swift
//  TablePro
//

import SwiftUI

struct ColumnVisibilityPopover: View {
    let columns: [String]
    let columnVisibilityManager: ColumnVisibilityManager

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

            if columns.count > 10 {
                searchField
                Divider()
            }

            columnList
        }
        .frame(width: 220)
        .frame(maxHeight: 350)
    }

    private var header: some View {
        HStack {
            Text("Columns")
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            Button("Show All") {
                columnVisibilityManager.showAll()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .controlSize(.small)
            .disabled(!columnVisibilityManager.hasHiddenColumns)

            Button("Hide All") {
                columnVisibilityManager.hideAll(columns)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .controlSize(.small)
            .disabled(columnVisibilityManager.hiddenCount == columns.count)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var searchField: some View {
        TextField(String(localized: "Search columns..."), text: $searchText)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    private var columnList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredColumns, id: \.self) { column in
                    columnRow(column)
                }
            }
        }
    }

    private func columnRow(_ column: String) -> some View {
        Toggle(isOn: Binding(
            get: { !columnVisibilityManager.hiddenColumns.contains(column) },
            set: { _ in columnVisibilityManager.toggleColumn(column) }
        )) {
            Text(column)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}
