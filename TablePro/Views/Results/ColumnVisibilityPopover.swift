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

    @State private var searchText = ""

    private var hasHiddenColumns: Bool { !hiddenColumns.isEmpty }
    private var hiddenCount: Int { hiddenColumns.count }

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
        }
        .frame(width: 260)
        .frame(maxHeight: 420)
    }

    private var headerTitle: String {
        let visible = columns.count - hiddenCount
        if hasHiddenColumns {
            return "\(visible) of \(columns.count)"
        }
        return String(localized: "Columns")
    }

    private var header: some View {
        HStack {
            Text(headerTitle)
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            Button("Show All") {
                onShowAll()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .controlSize(.small)
            .disabled(!hasHiddenColumns)

            Button("Hide All") {
                onHideAll(columns)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .controlSize(.small)
            .disabled(hiddenCount == columns.count)
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
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(filteredColumns, id: \.self) { column in
                    columnRow(column)
                }
            }
        }
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
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}
