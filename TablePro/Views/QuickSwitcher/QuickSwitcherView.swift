//
//  QuickSwitcherView.swift
//  TablePro
//
//  Quick switcher sheet for searching and opening database objects.
//  Presented as a native SwiftUI .sheet() via the ActiveSheet pattern.
//

import SwiftUI

// MARK: - Sheet

/// Native SwiftUI sheet for the quick switcher, matching the project's ActiveSheet pattern.
internal struct QuickSwitcherSheet: View {
    @Binding var isPresented: Bool
    @Environment(\.dismiss) private var dismiss

    let schemaProvider: SQLSchemaProvider
    let connectionId: UUID
    let databaseType: DatabaseType
    let onSelect: (QuickSwitcherItem) -> Void

    @State private var viewModel = QuickSwitcherViewModel()

    private enum FocusField {
        case search
        case itemList
    }

    @FocusState private var focus: FocusField?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Text("Quick Switcher")
                .font(.body.weight(.semibold))
                .padding(.vertical, 12)

            Divider()

            // Search toolbar
            searchToolbar

            Divider()

            // Content
            if viewModel.isLoading {
                loadingView
            } else if viewModel.filteredItems.isEmpty {
                emptyState
            } else {
                itemList
            }

            Divider()

            // Footer
            footer
        }
        .frame(width: 460, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await viewModel.loadItems(
                schemaProvider: schemaProvider,
                connectionId: connectionId,
                databaseType: databaseType
            )
        }
        .defaultFocus($focus, .search)
        .onExitCommand { dismiss() }
        .onKeyPress(.return) {
            openSelectedItem()
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "jn"), phases: [.down, .repeat]) { keyPress in
            guard keyPress.modifiers.contains(.control) else { return .ignored }
            viewModel.moveDown()
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "kp"), phases: [.down, .repeat]) { keyPress in
            guard keyPress.modifiers.contains(.control) else { return .ignored }
            viewModel.moveUp()
            return .handled
        }
    }

    // MARK: - Search Toolbar

    private var searchToolbar: some View {
        SearchFieldView(
            placeholder: "Search tables, views, databases...",
            text: $viewModel.searchText
        )
        .focused($focus, equals: .search)
        .onKeyPress(.upArrow) {
            viewModel.moveUp()
            return .handled
        }
        .onKeyPress(.downArrow) {
            viewModel.moveDown()
            return .handled
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Item List

    private var itemList: some View {
        ScrollViewReader { proxy in
            List(selection: $viewModel.selectedItemId) {
                if viewModel.searchText.isEmpty {
                    // Grouped by kind when not searching
                    ForEach(viewModel.groupedItems, id: \.kind) { group in
                        Section {
                            ForEach(group.items) { item in
                                itemRow(item)
                            }
                        } header: {
                            Text(sectionTitle(for: group.kind))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    // Flat ranked list when searching
                    ForEach(viewModel.filteredItems) { item in
                        itemRow(item)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .focused($focus, equals: .itemList)
            .onChange(of: viewModel.selectedItemId) { _, newValue in
                if let itemId = newValue {
                    proxy.scrollTo(itemId, anchor: .center)
                }
            }
        }
    }

    private func itemRow(_ item: QuickSwitcherItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.iconName)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            Text(item.name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)

            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(item.kindLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .quaternaryLabelColor))
                )
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .listRowSeparator(.hidden)
        .id(item.id)
        .tag(item.id)
        .overlay(
            DoubleClickDetector {
                viewModel.selectedItemId = item.id
                openSelectedItem()
            }
        )
    }

    // MARK: - Empty States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading...")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)

            if viewModel.searchText.isEmpty {
                Text("No objects found")
                    .font(.body.weight(.medium))
            } else {
                Text("No matching objects")
                    .font(.body.weight(.medium))

                Text("No objects match \"\(viewModel.searchText)\"")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }

            Spacer()

            Button("Open") {
                openSelectedItem()
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.selectedItem == nil)
        }
        .padding(12)
    }

    // MARK: - Helpers

    private func sectionTitle(for kind: QuickSwitcherItemKind) -> String {
        switch kind {
        case .table: return "TABLES"
        case .view: return "VIEWS"
        case .systemTable: return "SYSTEM TABLES"
        case .database: return "DATABASES"
        case .schema: return "SCHEMAS"
        case .queryHistory: return "RECENT QUERIES"
        }
    }

    private func openSelectedItem() {
        guard let item = viewModel.selectedItem else { return }
        onSelect(item)
        dismiss()
    }
}
