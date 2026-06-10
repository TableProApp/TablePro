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
    static let sectionHeaderHeight: CGFloat = 34
    static let chipRowHeight: CGFloat = 40
    static let listVerticalPadding: CGFloat = 6
    static let maxVisibleRows = 12

    static var cornerRadius: CGFloat {
        if #available(macOS 26.0, *) {
            return 28
        }
        return 13
    }
}

struct QuickSwitcherPanelView: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let schemaProvider: SQLSchemaProvider
    let connectionId: UUID
    let databaseType: DatabaseType
    let openTableNames: Set<String>
    let onSelect: (QuickSwitcherItem, QuickSwitcherCommitIntent) -> Void
    let onDismiss: () -> Void

    @State private var viewModel: QuickSwitcherViewModel
    @State private var keyMonitor: Any?

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
        VStack(spacing: 0) {
            inputRow

            if showsContent {
                Divider()
                scopeChips
                if viewModel.flatItems.isEmpty {
                    noResultsRow
                } else {
                    resultsList
                }
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
        .task {
            await viewModel.loadItems(
                schemaProvider: schemaProvider,
                databaseType: databaseType,
                openTableNames: openTableNames
            )
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    private var showsContent: Bool {
        guard !viewModel.isLoading else { return false }
        if viewModel.flatItems.isEmpty {
            return !viewModel.searchText.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
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

    private var scopeChips: some View {
        HStack(spacing: 8) {
            ForEach(QuickSwitcherScope.allCases) { scope in
                scopeChip(scope)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: PanelMetrics.chipRowHeight)
    }

    private func scopeChip(_ scope: QuickSwitcherScope) -> some View {
        let isSelected = viewModel.scope == scope
        return Button {
            viewModel.scope = scope
        } label: {
            Text(scope.title)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(
                    Capsule().fill(isSelected ? Color(nsColor: .quaternarySystemFill) : Color.clear)
                )
                .overlay(
                    Capsule().strokeBorder(
                        Color(nsColor: .separatorColor),
                        lineWidth: isSelected ? 0 : 0.5
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.groups) { group in
                        if let header = group.header {
                            sectionHeader(header)
                        }
                        ForEach(group.items) { item in
                            itemRow(item)
                        }
                    }
                }
                .padding(.vertical, PanelMetrics.listVerticalPadding)
            }
            .frame(height: listHeight)
            .onChange(of: viewModel.selectedItemId) { _, newValue in
                if let id = newValue {
                    proxy.scrollTo(id)
                }
            }
        }
    }

    private var listHeight: CGFloat {
        viewModel.listHeight(
            rowHeight: PanelMetrics.rowHeight,
            headerHeight: PanelMetrics.sectionHeaderHeight,
            maxVisibleRows: PanelMetrics.maxVisibleRows
        ) + PanelMetrics.listVerticalPadding * 2
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 20)
            .padding(.top, 18)
            .padding(.bottom, 4)
    }

    private func itemRow(_ item: QuickSwitcherItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.iconName)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(highlightedName(for: item))
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if item.isOpenInTab {
                Text(String(localized: "Open"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color(nsColor: .quaternarySystemFill)))
            }

            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: PanelMetrics.rowHeight)
        .background {
            if item.id == viewModel.selectedItemId {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                    .padding(.horizontal, 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectedItemId = item.id
            commit(item, intent: .open)
        }
        .contextMenu { contextMenuActions(for: item) }
        .id(item.id)
    }

    private var noResultsRow: some View {
        Text(String(format: String(localized: "No results for \"%@\""), viewModel.searchText))
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .frame(height: PanelMetrics.rowHeight + PanelMetrics.listVerticalPadding * 2)
    }

    @ViewBuilder
    private func contextMenuActions(for item: QuickSwitcherItem) -> some View {
        Button(String(localized: "Open")) {
            viewModel.selectedItemId = item.id
            commit(item, intent: .open)
        }
        if item.kind == .table || item.kind == .view || item.kind == .systemTable {
            Button(String(localized: "Open in New Tab")) {
                viewModel.selectedItemId = item.id
                commit(item, intent: .openInNewWindowTab)
            }
            Button(String(localized: "Open Structure")) {
                viewModel.selectedItemId = item.id
                commit(item, intent: .openStructure)
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

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window is QuickSwitcherPanel else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let characters = event.charactersIgnoringModifiers ?? ""

            if modifiers == .command,
               let digit = Int(characters),
               digit >= 1, digit <= QuickSwitcherScope.allCases.count {
                viewModel.scope = QuickSwitcherScope.allCases[digit - 1]
                return nil
            }
            if modifiers == .control {
                switch characters {
                case "j", "n":
                    viewModel.moveSelection(by: 1)
                    return nil
                case "k", "p":
                    viewModel.moveSelection(by: -1)
                    return nil
                default:
                    break
                }
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
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
        commit(item, intent: intent)
    }

    private func commit(_ item: QuickSwitcherItem, intent: QuickSwitcherCommitIntent) {
        viewModel.recordSelection(item)
        onSelect(item, intent)
        onDismiss()
    }
}
