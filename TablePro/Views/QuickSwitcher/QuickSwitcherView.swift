//
//  QuickSwitcherView.swift
//  TablePro
//
//  SwiftUI content for the quick switcher. Hosted inside an NSPanel
//  by `QuickSwitcherPanelController` for the Spotlight presentation pattern.
//

import SwiftUI

internal struct QuickSwitcherContentView: View {
    let schemaProvider: SQLSchemaProvider
    let connectionId: UUID
    let databaseType: DatabaseType
    let onSelect: (QuickSwitcherItem) -> Void
    let onDismiss: () -> Void

    @State private var viewModel = QuickSwitcherViewModel()

    private enum FocusField {
        case itemList
    }

    @FocusState private var focus: FocusField?

    var body: some View {
        VStack(spacing: 0) {
            Text("Quick Switcher")
                .font(.body.weight(.semibold))
                .padding(.vertical, 12)

            Divider()

            searchToolbar

            Divider()

            if viewModel.isLoading {
                loadingView
            } else if viewModel.filteredItems.isEmpty {
                emptyState
            } else {
                itemList
            }

            Divider()

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
        .onExitCommand { onDismiss() }
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
        NativeSearchField(
            text: $viewModel.searchText,
            placeholder: String(localized: "Search tables, views, databases..."),
            onMoveUp: { viewModel.moveUp() },
            onMoveDown: { viewModel.moveDown() },
            focusOnAppear: true
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Item List

    private var itemList: some View {
        ScrollViewReader { proxy in
            List(selection: $viewModel.selectedItemId) {
                if viewModel.searchText.isEmpty {
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
                .font(.body)
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
            Text(String(localized: "Loading..."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)

            if viewModel.searchText.isEmpty {
                Text(String(localized: "No objects found"))
                    .font(.body.weight(.medium))
            } else {
                Text(String(localized: "No matching objects"))
                    .font(.body.weight(.medium))

                Text(String(format: String(localized: "No objects match \"%@\""), viewModel.searchText))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button(String(localized: "Cancel")) {
                onDismiss()
            }

            Spacer()

            Button(String(localized: "Open")) {
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
        case .table: return String(localized: "TABLES")
        case .view: return String(localized: "VIEWS")
        case .systemTable: return String(localized: "SYSTEM TABLES")
        case .database: return String(localized: "DATABASES")
        case .schema: return String(localized: "SCHEMAS")
        case .queryHistory: return String(localized: "RECENT QUERIES")
        }
    }

    private func openSelectedItem() {
        guard let item = viewModel.selectedItem else { return }
        onSelect(item)
        onDismiss()
    }
}
