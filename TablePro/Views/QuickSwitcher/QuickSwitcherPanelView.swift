//
//  QuickSwitcherPanelView.swift
//  TablePro
//

import AppKit
import SwiftUI

private enum PanelMetrics {
    static let width: CGFloat = 640
    static let inputRowHeight: CGFloat = 52
    static let rowHeight: CGFloat = 30
    static let sectionHeaderHeight: CGFloat = 28
    static let noResultsHeight: CGFloat = 140
    static let maxVisibleRows = 12

    static var cornerRadius: CGFloat {
        if #available(macOS 26.0, *) {
            return 28
        }
        return 13
    }
}

struct QuickSwitcherPanelView: View {
    let schemaProvider: SQLSchemaProvider
    let connectionId: UUID
    let databaseType: DatabaseType
    let openTableNames: Set<String>
    let onSelect: (QuickSwitcherItem, QuickSwitcherCommitIntent) -> Void
    let onDismiss: () -> Void

    @State private var viewModel: QuickSwitcherViewModel

    init(
        schemaProvider: SQLSchemaProvider,
        connectionId: UUID,
        databaseType: DatabaseType,
        openTableNames: Set<String> = [],
        onSelect: @escaping (QuickSwitcherItem, QuickSwitcherCommitIntent) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.schemaProvider = schemaProvider
        self.connectionId = connectionId
        self.databaseType = databaseType
        self.openTableNames = openTableNames
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        self._viewModel = State(wrappedValue: QuickSwitcherViewModel(connectionId: connectionId))
    }

    var body: some View {
        QuickSwitcherPanelContent(viewModel: viewModel) { item, intent in
            viewModel.recordSelection(item)
            onSelect(item, intent)
            onDismiss()
        }
        .task {
            await viewModel.loadItems(
                schemaProvider: schemaProvider,
                databaseType: databaseType,
                openTableNames: openTableNames
            )
        }
    }
}

struct QuickSwitcherPanelContent: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @Bindable var viewModel: QuickSwitcherViewModel
    let onCommit: (QuickSwitcherItem, QuickSwitcherCommitIntent) -> Void

    var body: some View {
        VStack(spacing: 0) {
            inputRow
            scopeBar

            if !viewModel.flatItems.isEmpty {
                Divider()
                itemList
            } else if !trimmedQuery.isEmpty {
                Divider()
                ContentUnavailableView.search(text: trimmedQuery)
                    .frame(height: PanelMetrics.noResultsHeight)
            }
        }
        .frame(width: PanelMetrics.width)
        .background(QuickSwitcherPanelBackground(cornerRadius: PanelMetrics.cornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous)
                .strokeBorder(
                    colorSchemeContrast == .increased ? Color(nsColor: .separatorColor) : .clear,
                    lineWidth: 1
                )
        )
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

    private var trimmedQuery: String {
        viewModel.searchText.trimmingCharacters(in: .whitespaces)
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.secondary)

            QuickSwitcherSearchField(
                text: $viewModel.searchText,
                placeholder: String(localized: "Search tables, views, databases, queries..."),
                onMoveUp: { viewModel.moveSelection(by: -1) },
                onMoveDown: { viewModel.moveSelection(by: 1) },
                onSubmit: { openSelectedItem() }
            )
        }
        .padding(.horizontal, 16)
        .frame(height: PanelMetrics.inputRowHeight)
    }

    private var scopeBar: some View {
        HStack(spacing: 6) {
            ForEach(Array(QuickSwitcherScope.allCases.enumerated()), id: \.element) { index, scope in
                Toggle(scope.title, isOn: scopeBinding(for: scope))
                    .toggleStyle(.button)
                    .buttonStyle(.accessoryBar)
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func scopeBinding(for scope: QuickSwitcherScope) -> Binding<Bool> {
        Binding(
            get: { viewModel.scope == scope },
            set: { isOn in
                viewModel.scope = isOn ? scope : .all
            }
        )
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
            .frame(height: viewModel.listHeight(
                rowHeight: PanelMetrics.rowHeight,
                headerHeight: PanelMetrics.sectionHeaderHeight,
                maxVisibleRows: PanelMetrics.maxVisibleRows
            ))
            .contextMenu(forSelectionType: String.self) { selection in
                if let id = selection.first,
                   let item = viewModel.flatItems.first(where: { $0.id == id }) {
                    contextMenuActions(for: item)
                }
            } primaryAction: { selection in
                guard let id = selection.first,
                      let item = viewModel.flatItems.first(where: { $0.id == id })
                else { return }
                viewModel.selectedItemId = id
                onCommit(item, .open)
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

            if item.isOpenInTab {
                Text(String(localized: "Open"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color(nsColor: .quaternarySystemFill)))
            }

            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(height: PanelMetrics.rowHeight)
        .contentShape(Rectangle())
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowSeparator(.hidden)
        .id(item.id)
        .tag(item.id)
    }

    @ViewBuilder
    private func contextMenuActions(for item: QuickSwitcherItem) -> some View {
        Button(String(localized: "Open")) {
            onCommit(item, .open)
        }
        if item.kind == .table || item.kind == .view || item.kind == .systemTable {
            Button(String(localized: "Open in New Tab")) {
                onCommit(item, .openInNewWindowTab)
            }
            Button(String(localized: "Open Structure")) {
                onCommit(item, .openStructure)
            }
        }
        Divider()
        Button(String(localized: "Copy Name")) {
            copyToPasteboard(item.name)
        }
        if item.kind == .savedQuery || item.kind == .queryHistory {
            Button(String(localized: "Copy Query")) {
                copyToPasteboard(item.payload ?? item.name)
            }
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func highlightedName(for item: QuickSwitcherItem) -> AttributedString {
        var attributed = AttributedString(item.name)
        guard !item.matchedIndices.isEmpty else { return attributed }
        let characterIndices = Array(attributed.characters.indices)
        for index in item.matchedIndices where index < characterIndices.count {
            let start = characterIndices[index]
            let end = attributed.characters.index(after: start)
            attributed[start..<end].font = .body.weight(.semibold)
        }
        return attributed
    }

    private func openSelectedItem() {
        guard let item = viewModel.selectedItem() else { return }
        let intent: QuickSwitcherCommitIntent = NSEvent.modifierFlags.contains(.option)
            ? .openInNewWindowTab
            : .open
        onCommit(item, intent)
    }
}

#Preview("Browse tables") {
    let viewModel = QuickSwitcherViewModel(connectionId: UUID())
    viewModel.allItems = [
        QuickSwitcherItem(id: "t1", name: "users", kind: .table, subtitle: "", isOpenInTab: true),
        QuickSwitcherItem(id: "t2", name: "user_profiles", kind: .table, subtitle: ""),
        QuickSwitcherItem(id: "t3", name: "orders", kind: .table, subtitle: ""),
        QuickSwitcherItem(id: "v1", name: "active_users", kind: .view, subtitle: "View"),
        QuickSwitcherItem(id: "d1", name: "analytics", kind: .database, subtitle: "Database"),
        QuickSwitcherItem(id: "f1", name: "Monthly revenue", kind: .savedQuery, subtitle: "rev")
    ]
    viewModel.scope = .tables
    return QuickSwitcherPanelContent(viewModel: viewModel) { _, _ in }
        .padding(40)
        .background(Color.gray.opacity(0.4))
}

#Preview("Empty") {
    let viewModel = QuickSwitcherViewModel(connectionId: UUID())
    return QuickSwitcherPanelContent(viewModel: viewModel) { _, _ in }
        .padding(40)
        .background(Color.gray.opacity(0.4))
}
