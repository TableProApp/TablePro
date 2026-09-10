//
//  JSONRowInspectorView.swift
//  TablePro
//
//  The JSON tab of the right panel: the selected row as a filterable JSON tree
//  whose foreign keys expand into the rows they reference.
//

import SwiftUI

struct JSONRowInspectorView: View {
    @Bindable var viewModel: JSONRowInspectorViewModel

    let snapshot: JSONRowSnapshot?
    let onOpenReferencedTable: (JSONForeignKeyRef, String) -> Void

    @State private var colors = JSONRowColors.current()

    var body: some View {
        VStack(spacing: 0) {
            if snapshot != nil {
                toolbar
                Divider()
                tree
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(AppEvents.shared.themeChanged) { _ in colors = JSONRowColors.current() }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView(
            String(localized: "No Row Selected"),
            systemImage: "curlybraces",
            description: Text(String(localized: "Select a row to view it as JSON"))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            filterField
            optionsMenu
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// The same `NSSearchField` the Details tab beside it uses.
    ///
    /// A plain `TextField` implements none of what a search field is: `Escape` clears the term and
    /// only then falls through to the window, the cancel button and the magnifier are drawn by
    /// AppKit, and assistive software reads the control as a search field rather than as text.
    private var filterField: some View {
        NativeSearchField(
            text: $viewModel.filterText,
            placeholder: String(localized: "Filter by text or /regex/"),
            controlSize: .small,
            accessibilityIdentifier: "json-row-filter"
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.red.opacity(0.6))
                .opacity(viewModel.isFilterInvalid ? 1 : 0)
        )
        .help(viewModel.isFilterInvalid
            ? String(localized: "Not a valid regular expression")
            : String(localized: "Filter keys and values. Wrap in slashes for a regular expression."))
    }

    private var optionsMenu: some View {
        Menu {
            Button(String(localized: "Copy Visible")) { viewModel.copyVisible() }
            Divider()
            Button(String(localized: "Collapse All")) { viewModel.collapseAll() }
            Button(String(localized: "Expand All")) { viewModel.expandAll() }
            Divider()
            Toggle(
                String(localized: "Always Expand Foreign Keys"),
                isOn: Binding(
                    get: { viewModel.alwaysExpandForeignKeys },
                    set: { viewModel.setAlwaysExpandForeignKeys($0) }
                )
            )
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "JSON view options"))
    }

    // MARK: - Tree

    @ViewBuilder
    private var tree: some View {
        let rows = viewModel.displayRows
        if rows.isEmpty {
            /// Only a filter can empty a row that has columns, so anything else that empties the
            /// tree is the absence of a row, not the absence of a match.
            if viewModel.isFiltering { noMatches } else { emptyState }
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        JSONNodeRowView(
                            row: row,
                            colors: colors,
                            onToggle: { viewModel.toggle(row: row) },
                            onOpenReferencedTable: onOpenReferencedTable
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: ThemeEngine.shared.colors.editor.background))
            .accessibilityLabel(String(localized: "Row as JSON"))
        }
    }

    private var noMatches: some View {
        ContentUnavailableView(
            String(localized: "No Matches"),
            systemImage: "magnifyingglass",
            description: Text(String(localized: "No key or value matches this filter"))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
