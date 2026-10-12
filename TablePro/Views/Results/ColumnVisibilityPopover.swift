//
//  ColumnVisibilityPopover.swift
//  TablePro
//

import SwiftUI

struct ColumnVisibilityPopover: View {
    @ObservedObject private var settingsManager = AppSettingsManager.shared
    let columns: [GridColumnEntry]
    let hiddenColumns: Set<String>
    let onToggleColumn: (String) -> Void
    let onShowAll: () -> Void
    let onHideAll: ([String]) -> Void
    let onReset: () -> Void
    let onJumpToColumn: ((String) -> Void)?

    @State private var searchText = ""

    private var columnNames: [String] {
        columns.map(\.name)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

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
                    .help(settingsManager.keyboard.shortcutHint(
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

    private var columnList: some View {
        ColumnCheckList(
            items: columns.map { ColumnCheckListItem(name: $0.name, typeName: $0.typeName) },
            searchText: $searchText,
            searchPlaceholder: String(localized: "Search columns…"),
            searchAccessibilityIdentifier: "column-visibility-search",
            rowAccessibilityIdentifierPrefix: "column-visibility-column-",
            listMinHeight: 120,
            listMaxHeight: 320,
            isChecked: { !hiddenColumns.contains($0) },
            onToggle: onToggleColumn
        )
    }
}
