//
//  QuickSwitcherPanelView.swift
//  TablePro
//

import AppKit
import SwiftUI

private enum PanelMetrics {
    static let width: CGFloat = 640
    static let inputRowHeight: CGFloat = 52
    static let rowHeight: CGFloat = 44
    static let rowSelectionInset: CGFloat = 8
    static let rowSelectionRadius: CGFloat = 12
    static let iconContainerSize: CGFloat = 26
    static let sectionHeaderHeight: CGFloat = 34
    static let scopeButtonSize: CGFloat = 44
    static let listVerticalPadding: CGFloat = 8
    static let maxVisibleRows = 9

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

    @State private var isNavigating = false
    @State private var keyMonitor: Any?

    var body: some View {
        HStack(spacing: 10) {
            mainSurface

            if !showsResultSurface {
                ForEach(QuickSwitcherScope.allCases.filter { $0 != .all }) { scope in
                    scopeButton(scope)
                }
            }
        }
        .frame(width: PanelMetrics.width)
        .onChange(of: viewModel.searchText) { _, _ in isNavigating = false }
        .onChange(of: viewModel.scope) { _, _ in isNavigating = false }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    private var showsResultSurface: Bool {
        !viewModel.flatItems.isEmpty || !trimmedQuery.isEmpty
    }

    private var trimmedQuery: String {
        viewModel.searchText.trimmingCharacters(in: .whitespaces)
    }

    private var surfaceCornerRadius: CGFloat {
        showsResultSurface ? PanelMetrics.cornerRadius : PanelMetrics.inputRowHeight / 2
    }

    private var surfaceStrokeColor: Color {
        if colorSchemeContrast == .increased {
            return Color(nsColor: .separatorColor)
        }
        return showsResultSurface ? .clear : barStrokeColor
    }

    private var mainSurface: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                inputFields
                if viewModel.scope != .all {
                    activeScopeBadge
                }
            }
            .padding(.horizontal, 18)
            .frame(height: PanelMetrics.inputRowHeight)

            if showsResultSurface {
                Divider()
                    .padding(.horizontal, 10)

                if viewModel.flatItems.isEmpty {
                    noResultsRow
                } else {
                    resultsList
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(QuickSwitcherPanelBackground(cornerRadius: surfaceCornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous)
                .strokeBorder(surfaceStrokeColor, lineWidth: showsResultSurface ? 1 : 0.5)
        )
    }

    private func scopeButton(_ scope: QuickSwitcherScope) -> some View {
        Button {
            viewModel.scope = scope
        } label: {
            Image(systemName: scope.iconName)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(viewModel.scope == scope ? Color.primary : Color.secondary)
                .frame(width: PanelMetrics.scopeButtonSize, height: PanelMetrics.scopeButtonSize)
                .background(QuickSwitcherPanelBackground(cornerRadius: PanelMetrics.scopeButtonSize / 2))
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(barStrokeColor, lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(scope.title)
    }

    private var barStrokeColor: Color {
        colorSchemeContrast == .increased
            ? Color(nsColor: .separatorColor)
            : Color(nsColor: .separatorColor).opacity(0.6)
    }

    private var inputFields: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.secondary)

            QuickSwitcherSearchField(
                text: $viewModel.searchText,
                placeholder: String(localized: "Search tables, views, databases, queries..."),
                onMoveUp: {
                    isNavigating = true
                    viewModel.moveSelection(by: -1)
                },
                onMoveDown: {
                    isNavigating = true
                    viewModel.moveSelection(by: 1)
                },
                onSubmit: { openSelectedItem() }
            )
        }
    }

    private var activeScopeBadge: some View {
        Button {
            viewModel.scope = .all
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewModel.scope.iconName)
                    .font(.system(size: 11, weight: .medium))
                Text(viewModel.scope.title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(Color(nsColor: .quaternarySystemFill)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Show all results"))
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
            .padding(.leading, 24)
            .padding(.top, 18)
            .padding(.bottom, 4)
    }

    private func itemRow(_ item: QuickSwitcherItem) -> some View {
        let isSelected = item.id == viewModel.selectedItemId
        let isEmphasized = isSelected && isNavigating

        return HStack(spacing: 12) {
            iconView(for: item, isEmphasized: isEmphasized)

            Text(highlightedName(for: item))
                .font(.system(size: 15))
                .foregroundStyle(isEmphasized ? Color.white : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            trailingAccessories(for: item, isSelected: isSelected, isEmphasized: isEmphasized)
        }
        .padding(.horizontal, 18)
        .frame(height: PanelMetrics.rowHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: PanelMetrics.rowSelectionRadius, style: .continuous)
                    .fill(
                        isEmphasized
                            ? Color(nsColor: .selectedContentBackgroundColor)
                            : Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
                    )
                    .padding(.horizontal, PanelMetrics.rowSelectionInset)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isNavigating = true
            viewModel.selectedItemId = item.id
            if NSApp.currentEvent?.clickCount == 2 {
                onCommit(item, .open)
            }
        }
        .contextMenu { contextMenuActions(for: item) }
        .id(item.id)
    }

    private func iconView(for item: QuickSwitcherItem, isEmphasized: Bool) -> some View {
        Image(systemName: item.iconName)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isEmphasized ? Color.white : Color.secondary)
            .frame(width: PanelMetrics.iconContainerSize, height: PanelMetrics.iconContainerSize)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isEmphasized
                            ? Color.white.opacity(0.2)
                            : Color(nsColor: .quaternarySystemFill)
                    )
            )
    }

    @ViewBuilder
    private func trailingAccessories(for item: QuickSwitcherItem, isSelected: Bool, isEmphasized: Bool) -> some View {
        let secondaryColor = isEmphasized ? Color.white.opacity(0.85) : Color.secondary

        if item.isOpenInTab, !isSelected {
            Text(String(localized: "Open"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(secondaryColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color(nsColor: .quaternarySystemFill)))
        }

        if isSelected {
            Text(commitHint(for: item))
                .font(.system(size: 12))
                .foregroundStyle(secondaryColor)
            keycap("↩", isEmphasized: isEmphasized)
        } else if !item.subtitle.isEmpty {
            Text(item.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(secondaryColor)
                .lineLimit(1)
        }
    }

    private func keycap(_ label: String, isEmphasized: Bool) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isEmphasized ? Color.white : Color.secondary)
            .frame(width: 24, height: 18)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isEmphasized ? Color.white.opacity(0.25) : Color(nsColor: .quaternarySystemFill))
            )
    }

    private func commitHint(for item: QuickSwitcherItem) -> String {
        switch item.kind {
        case .table, .view, .systemTable:
            return item.isOpenInTab ? String(localized: "Switch to Tab") : String(localized: "Open")
        case .database, .schema:
            return String(localized: "Switch")
        case .savedQuery, .queryHistory:
            return String(localized: "Load Query")
        }
    }

    private var noResultsRow: some View {
        Text(String(format: String(localized: "No results for \"%@\""), viewModel.searchText))
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .frame(height: PanelMetrics.rowHeight + PanelMetrics.listVerticalPadding * 2)
    }

    @ViewBuilder
    private func contextMenuActions(for item: QuickSwitcherItem) -> some View {
        Button(String(localized: "Open")) {
            viewModel.selectedItemId = item.id
            onCommit(item, .open)
        }
        if item.kind == .table || item.kind == .view || item.kind == .systemTable {
            Button(String(localized: "Open in New Tab")) {
                viewModel.selectedItemId = item.id
                onCommit(item, .openInNewWindowTab)
            }
            Button(String(localized: "Open Structure")) {
                viewModel.selectedItemId = item.id
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
                    isNavigating = true
                    viewModel.moveSelection(by: 1)
                    return nil
                case "k", "p":
                    isNavigating = true
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
            attributed[start..<end].font = .system(size: 15, weight: .semibold)
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

#Preview("Empty bar") {
    let viewModel = QuickSwitcherViewModel(connectionId: UUID())
    return QuickSwitcherPanelContent(viewModel: viewModel) { _, _ in }
        .padding(40)
        .background(Color.gray.opacity(0.4))
}
