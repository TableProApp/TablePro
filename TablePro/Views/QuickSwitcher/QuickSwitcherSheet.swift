//
//  QuickSwitcherSheet.swift
//  TablePro
//

import SwiftUI

struct QuickSwitcherSheet: View {
    @Binding var isPresented: Bool
    @Environment(\.dismiss) private var dismiss

    let schemaProvider: SQLSchemaProvider
    let connectionId: UUID
    let databaseType: DatabaseType
    let onSelect: (QuickSwitcherItem) -> Void

    @State private var viewModel: QuickSwitcherViewModel

    init(
        isPresented: Binding<Bool>,
        schemaProvider: SQLSchemaProvider,
        connectionId: UUID,
        databaseType: DatabaseType,
        onSelect: @escaping (QuickSwitcherItem) -> Void
    ) {
        self._isPresented = isPresented
        self.schemaProvider = schemaProvider
        self.connectionId = connectionId
        self.databaseType = databaseType
        self.onSelect = onSelect
        self._viewModel = State(wrappedValue: QuickSwitcherViewModel(connectionId: connectionId))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            if viewModel.isLoading {
                loadingView
            } else if viewModel.flatItems.isEmpty {
                emptyState
            } else {
                itemList
            }

            Divider()

            footer
        }
        .frame(width: 460, height: 500)
        .navigationTitle(String(localized: "Quick Switcher"))
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await viewModel.loadItems(
                schemaProvider: schemaProvider,
                databaseType: databaseType
            )
        }
        .onExitCommand { dismiss() }
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

    private var toolbar: some View {
        NativeSearchField(
            text: $viewModel.searchText,
            placeholder: String(localized: "Search tables, views, databases..."),
            onMoveUp: { viewModel.moveSelection(by: -1) },
            onMoveDown: { viewModel.moveSelection(by: 1) },
            focusOnAppear: true
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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

            Text(item.name)
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
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
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
            .disabled(viewModel.selectedItemId == nil)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(12)
    }

    private func openSelectedItem() {
        guard let item = viewModel.selectedItem() else { return }
        commit(item)
    }

    private func commit(_ item: QuickSwitcherItem) {
        viewModel.recordSelection(item)
        onSelect(item)
        dismiss()
    }
}
