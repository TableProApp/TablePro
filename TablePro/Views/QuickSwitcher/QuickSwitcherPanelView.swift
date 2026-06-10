//
//  QuickSwitcherPanelView.swift
//  TablePro
//

import SwiftUI

struct QuickSwitcherPanelView: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let schemaProvider: SQLSchemaProvider
    let connectionId: UUID
    let databaseType: DatabaseType
    let onSelect: (QuickSwitcherItem) -> Void
    let onDismiss: () -> Void

    private let panelWidth: CGFloat = 640
    private let cornerRadius: CGFloat = 16
    private let rowHeight: CGFloat = 30
    private let sectionHeaderHeight: CGFloat = 28
    private let maxVisibleRows = 12

    @State private var viewModel: QuickSwitcherViewModel

    init(
        schemaProvider: SQLSchemaProvider,
        connectionId: UUID,
        databaseType: DatabaseType,
        onSelect: @escaping (QuickSwitcherItem) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.schemaProvider = schemaProvider
        self.connectionId = connectionId
        self.databaseType = databaseType
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        self._viewModel = State(wrappedValue: QuickSwitcherViewModel(connectionId: connectionId))
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            Divider()

            if viewModel.isLoading {
                loadingView
            } else if viewModel.flatItems.isEmpty {
                emptyState
            } else {
                itemList
                    .frame(height: viewModel.listHeight(
                        rowHeight: rowHeight,
                        headerHeight: sectionHeaderHeight,
                        maxVisibleRows: maxVisibleRows
                    ))
            }

            Divider()

            footer
        }
        .frame(width: panelWidth)
        .background(QuickSwitcherPanelBackground(cornerRadius: cornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    colorSchemeContrast == .increased ? Color(nsColor: .separatorColor) : .clear,
                    lineWidth: 1
                )
        )
        .task {
            await viewModel.loadItems(
                schemaProvider: schemaProvider,
                databaseType: databaseType
            )
        }
        .onKeyPress(characters: .init(charactersIn: "jn"), phases: [.down, .repeat]) { keyPress in
            guard keyPress.modifiers.contains(.control) else { return .ignored }
            viewModel.moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "kp"), phases: [.down, .repeat]) { keyPress in
            guard keyPress.modifiers.contains(.control) else { return .ignored }
            viewModel.moveSelection(by: -1)
            return .handled
        }
    }

    private var searchField: some View {
        NativeSearchField(
            text: $viewModel.searchText,
            placeholder: String(localized: "Search tables, views, databases, queries..."),
            controlSize: .large,
            onMoveUp: { viewModel.moveSelection(by: -1) },
            onMoveDown: { viewModel.moveSelection(by: 1) },
            onSubmit: { openSelectedItem() },
            focusOnAppear: true
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var itemList: some View {
        ScrollViewReader { proxy in
            List(selection: $viewModel.selectedItemId) {
                ForEach(viewModel.groups) { group in
                    if let header = group.header {
                        Section {
                            ForEach(group.items) { item in
                                itemRow(item)
                            }
                        } header: {
                            Text(header)
                        }
                    } else {
                        ForEach(group.items) { item in
                            itemRow(item)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: String.self) { _ in
                EmptyView()
            } primaryAction: { selection in
                guard let id = selection.first,
                      let item = viewModel.flatItems.first(where: { $0.id == id })
                else { return }
                viewModel.selectedItemId = id
                commit(item)
            }
            .onChange(of: viewModel.selectedItemId) { _, newValue in
                if let id = newValue {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private func itemRow(_ item: QuickSwitcherItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.iconName)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Text(highlightedName(for: item))
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowSeparator(.hidden)
        .id(item.id)
        .tag(item.id)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
            Text(String(localized: "Loading..."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
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
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            shortcutHint(keys: "↑↓", label: String(localized: "Navigate"))
            shortcutHint(keys: "↩", label: String(localized: "Open"))
            Spacer()
            shortcutHint(keys: "esc", label: String(localized: "Close"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func shortcutHint(keys: String, label: String) -> some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(nsColor: .quaternarySystemFill))
                )
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func highlightedName(for item: QuickSwitcherItem) -> AttributedString {
        var attributed = AttributedString(item.name)
        guard !item.matchedIndices.isEmpty else { return attributed }
        let characterIndices = Array(attributed.characters.indices)
        for index in item.matchedIndices where index < characterIndices.count {
            let start = characterIndices[index]
            let end = attributed.characters.index(after: start)
            attributed[start..<end].font = .body.weight(.semibold)
            attributed[start..<end].foregroundColor = .accentColor
        }
        return attributed
    }

    private func openSelectedItem() {
        guard let item = viewModel.selectedItem() else { return }
        commit(item)
    }

    private func commit(_ item: QuickSwitcherItem) {
        viewModel.recordSelection(item)
        onSelect(item)
        onDismiss()
    }
}
