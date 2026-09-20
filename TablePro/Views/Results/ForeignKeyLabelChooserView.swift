//
//  ForeignKeyLabelChooserView.swift
//  TablePro
//
//  Which columns of the referenced table read as a row's name, chosen inside the picker that
//  shows them.
//

import SwiftUI

/// The foreign key picker drills in to this rather than opening a second popover or a sheet: the
/// HIG rules out both over a popover, and no macOS menu can stay open for more than one tick, so a
/// menu of checkmarks would cost one reopen per column.
struct ForeignKeyLabelChooserView: View {
    let columns: [ForeignKeyLookupColumn]
    let selectedNames: [String]
    /// Fixed rather than bounded, and the same height the row list it replaces stands at, so
    /// drilling in and back out moves the popover as little as the two panes' chrome differs by.
    let listHeight: CGFloat
    let onToggle: (String) -> Void
    let onClear: () -> Void
    let onDone: () -> Void

    @State private var searchText = ""

    private var selection: Set<String> {
        Set(selectedNames)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
    }

    private var headerTitle: String {
        guard !selection.isEmpty else {
            return String(localized: "Label Columns")
        }
        return String(format: String(localized: "%d of %d"), selection.count, columns.count)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(headerTitle)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button("None") { onClear() }
                .buttonStyle(.link)
                .controlSize(.small)
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("fk-picker-label-none")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var list: some View {
        ColumnCheckList(
            items: columns.map { ColumnCheckListItem(name: $0.name, typeName: $0.displayTypeName) },
            searchText: $searchText,
            searchPlaceholder: String(localized: "Search columns…"),
            searchAccessibilityIdentifier: "fk-picker-label-search",
            rowAccessibilityIdentifierPrefix: "fk-picker-label-column-",
            listMinHeight: listHeight,
            listMaxHeight: listHeight,
            isChecked: selection.contains,
            onToggle: onToggle
        )
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Shown beside each key")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button("Done") { onDone() }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("fk-picker-label-done")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
