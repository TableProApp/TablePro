//
//  QuickSwitcherPanelView.swift
//  TablePro
//

import AppKit
import SwiftUI

struct QuickSwitcherPanelView: View {
    let schemaProvider: SQLSchemaProvider
    let connectionId: UUID
    let databaseType: DatabaseType
    let openTables: Set<QuickSwitcherOpenTable>
    let browseSchema: String?
    let onSelect: (QuickSwitcherItem, QuickSwitcherCommitIntent) -> Void
    let onDismiss: () -> Void

    @State private var viewModel: QuickSwitcherViewModel

    init(
        schemaProvider: SQLSchemaProvider,
        connectionId: UUID,
        databaseType: DatabaseType,
        openTables: Set<QuickSwitcherOpenTable> = [],
        browseSchema: String? = nil,
        onSelect: @escaping (QuickSwitcherItem, QuickSwitcherCommitIntent) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.schemaProvider = schemaProvider
        self.connectionId = connectionId
        self.databaseType = databaseType
        self.openTables = openTables
        self.browseSchema = browseSchema
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
                openTables: openTables,
                browseSchema: browseSchema
            )
        }
        .task(id: viewModel.crossConnectionLoadVersion) {
            await viewModel.loadCrossConnectionItems()
        }
        .task(id: viewModel.crossConnectionQueryLoadVersion) {
            await viewModel.loadCrossConnectionQueryItems()
        }
        .onReceive(AppEvents.shared.queryHistoryDidUpdate) { _ in
            viewModel.invalidateCrossConnectionQueryItems()
        }
        .onReceive(AppEvents.shared.sqlFavoritesDidUpdate) { _ in
            viewModel.invalidateCrossConnectionQueryItems()
        }
    }
}

struct QuickSwitcherPanelContent: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @Bindable var viewModel: QuickSwitcherViewModel
    let onCommit: (QuickSwitcherItem, QuickSwitcherCommitIntent) -> Void

    @State private var keyMonitor: Any?

    var body: some View {
        QuickSwitcherGlassGroup {
            VStack(spacing: 0) {
                inputRow

                Divider().opacity(dividerOpacity)

                scopeBar

                if showsResultSurface {
                    Divider().opacity(dividerOpacity)
                    results
                }

                Divider().opacity(dividerOpacity)

                footer
            }
            .frame(width: QuickSwitcherMetrics.width)
            .quickSwitcherSurface(cornerRadius: QuickSwitcherMetrics.cornerRadius)
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    // MARK: - State

    private var trimmedQuery: String {
        viewModel.searchText.trimmingCharacters(in: .whitespaces)
    }

    /// What the next Escape will actually do, which is not the same question as whether there is a
    /// meaningful query. The field editor owns the first Escape and branches on the raw string, so
    /// a query of nothing but spaces still has something to clear. Branching the hint on the
    /// trimmed query instead promised "Close" and then cleared.
    private var escapeDismissesPanel: Bool {
        viewModel.searchText.isEmpty
    }

    private var showsResultSurface: Bool {
        !viewModel.flatItems.isEmpty || !trimmedQuery.isEmpty || viewModel.isLoadingResults
    }

    private var dividerOpacity: Double {
        colorSchemeContrast == .increased ? 1 : 0.6
    }

    // MARK: - Input

    private var inputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            QuickSwitcherSearchField(
                text: $viewModel.searchText,
                placeholder: String(localized: "Search tables, views, databases, queries…"),
                onMoveUp: { viewModel.moveSelection(by: -1) },
                onMoveDown: { viewModel.moveSelection(by: 1) },
                onSubmit: { openSelectedItem() }
            )
        }
        .padding(.horizontal, 18)
        .frame(height: QuickSwitcherMetrics.inputRowHeight)
    }

    // MARK: - Scopes

    /// A scope bar, which is what the HIG calls this: "a control for filtering and adjusting the
    /// scope of a search". macOS draws one as a segmented control, and SwiftUI's own `searchScopes`
    /// puts exactly this picker under the search field. The row it replaced was five capsule
    /// buttons, which is an idiom macOS does not have: no HIG component, no AppKit control and no
    /// Apple app ships one, and the selected capsule was the only opaque thing on a glass panel
    /// (measured: its pixels did not move at all when the desktop behind the panel changed, while
    /// every other element shifted with the material).
    ///
    /// Text, not icons: the HIG says to "prefer using either text or images, not a mix of both, in
    /// a single segmented control", and macOS renders `Label(_:systemImage:)` in a segmented picker
    /// as text anyway, so a symbol here would be written and never drawn.
    ///
    /// Always present: gating the scope controls on "nothing is listed yet" removed them from the
    /// view tree the instant a single Recent row existed, which is the panel's very first frame on
    /// any connection with history, so four of the five scopes had no mouse affordance at all.
    private var scopeBar: some View {
        Picker(String(localized: "Scope"), selection: $viewModel.scope) {
            ForEach(QuickSwitcherScope.allCases) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.large)
        /// The search field owns first responder for the panel's whole life and only claims it
        /// once, so anything here that could take focus on click would end typing. This is the same
        /// guard the toolbar and the filter field use.
        .focusable(false)
        .accessibilityIdentifier("quick-switcher-scope-picker")
        .padding(.horizontal, 14)
        .frame(height: QuickSwitcherMetrics.scopeBarHeight)
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        if viewModel.flatItems.isEmpty {
            statusRow
        } else {
            resultsList
        }
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
                .padding(.vertical, QuickSwitcherMetrics.listVerticalPadding)
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
            rowHeight: QuickSwitcherMetrics.rowHeight,
            headerHeight: QuickSwitcherMetrics.sectionHeaderHeight,
            maxVisibleRows: QuickSwitcherMetrics.maxVisibleRows
        ) + QuickSwitcherMetrics.listVerticalPadding * 2
    }

    /// Every bit of the header's height lives inside the one frame `listHeight` is told about.
    /// Padding applied outside it makes the row taller than the list budgets for, and the list is
    /// then short by that much per header, which clips the last row.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 24)
            .padding(.bottom, 2)
            .frame(height: QuickSwitcherMetrics.sectionHeaderHeight, alignment: .bottom)
    }

    /// A first load can take seconds (schema introspection, the database and schema lists, favorites
    /// and 200 history rows), and until it lands the panel has no items to show. Reporting that as
    /// "No results" is indistinguishable from a genuine miss.
    @ViewBuilder
    private var statusRow: some View {
        if viewModel.isLoadingResults {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading…")
            }
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .frame(height: QuickSwitcherMetrics.rowHeight + QuickSwitcherMetrics.listVerticalPadding * 2)
        } else {
            Text(String(format: String(localized: "No results for \"%@\""), viewModel.searchText))
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .frame(height: QuickSwitcherMetrics.rowHeight + QuickSwitcherMetrics.listVerticalPadding * 2)
        }
    }

    private func itemRow(_ item: QuickSwitcherItem) -> some View {
        /// The panel closes as soon as it stops being key, so "unfocused" is a state it cannot be in
        /// and must not depict. Gating this on whether an arrow key had fired painted the row Return
        /// commits as inactive until the user pressed one.
        let isSelected = item.id == viewModel.selectedItemId

        return HStack(spacing: 12) {
            iconView(for: item, isSelected: isSelected)

            Text(highlightedName(for: item))
                .font(.body)
                .foregroundStyle(isSelected ? Color.emphasizedSelectionLabel : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            trailingAccessories(for: item, isSelected: isSelected)
        }
        .padding(.horizontal, 18)
        .frame(height: QuickSwitcherMetrics.rowHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: QuickSwitcherMetrics.rowCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .selectedContentBackgroundColor))
                    .padding(.horizontal, QuickSwitcherMetrics.rowInset)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            viewModel.selectedItemId = item.id
            onCommit(item, .open)
        }
        .simultaneousGesture(
            TapGesture().onEnded { viewModel.selectedItemId = item.id }
        )
        .contextMenu { contextMenuActions(for: item) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(item.name))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onCommit(item, .open) }
        .id(item.id)
    }

    private func iconView(for item: QuickSwitcherItem, isSelected: Bool) -> some View {
        Image(systemName: item.iconName)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isSelected ? Color.emphasizedSelectionLabel : Color.secondary)
            .frame(width: QuickSwitcherMetrics.iconContainerSize, height: QuickSwitcherMetrics.iconContainerSize)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.emphasizedSelectionLabel.opacity(0.2)
                            : Color(nsColor: .quaternarySystemFill)
                    )
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func trailingAccessories(for item: QuickSwitcherItem, isSelected: Bool) -> some View {
        let secondaryColor = isSelected ? Color.emphasizedSelectionLabel.opacity(0.85) : Color.secondary

        if item.isOpenInTab, !isSelected {
            Text(String(localized: "Open"))
                .font(.caption2.weight(.medium))
                .foregroundStyle(secondaryColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color(nsColor: .quaternarySystemFill)))
        }

        if showsSubtitle(for: item, isSelected: isSelected) {
            Text(item.subtitle)
                .font(.callout)
                .foregroundStyle(secondaryColor)
                .lineLimit(1)
        }

        if isSelected {
            Text(commitHint(for: item))
                .font(.caption)
                .foregroundStyle(secondaryColor)
        }
    }

    /// A cross-connection result keeps its path while selected, because it names the connection
    /// the commit is about to open and nothing else on the row carries that.
    private func showsSubtitle(for item: QuickSwitcherItem, isSelected: Bool) -> Bool {
        guard !item.subtitle.isEmpty else { return false }
        return !isSelected || item.target != nil
    }

    private func commitHint(for item: QuickSwitcherItem) -> String {
        switch item.kind {
        case .table, .view, .systemTable:
            return item.isOpenInTab ? String(localized: "Switch to Tab") : String(localized: "Open")
        case .database, .schema:
            return String(localized: "Switch")
        case .procedure, .function, .trigger:
            return String(localized: "Show DDL")
        case .savedQuery, .queryHistory:
            return String(localized: "Load Query")
        }
    }

    // MARK: - Footer

    /// The one place the panel's whole keyboard contract is written down. It also makes the first
    /// Escape legible: the panel clears a typed query before it dismisses (#1490), and with nothing
    /// on screen saying so, that first press reads as a key that did nothing.
    private var footer: some View {
        HStack(spacing: 14) {
            keyHint("\u{21A9}", String(localized: "Open"))
            keyHint("\u{2318}\u{21A9}", String(localized: "New Tab"))

            Spacer(minLength: 0)

            keyHint("\u{2318}1\u{2013}5", String(localized: "Scope"))
            keyHint(
                "\u{238B}",
                escapeDismissesPanel ? String(localized: "Close") : String(localized: "Clear")
            )
        }
        .padding(.horizontal, 16)
        .frame(height: QuickSwitcherMetrics.footerHeight)
        /// Read as one element rather than eight. The commit keys are already offered as actions on
        /// the rows themselves, so the part worth speaking is the one the glyphs exist to
        /// disambiguate: which of the two things the next Escape will do.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(escapeHintLabel))
    }

    private var escapeHintLabel: String {
        escapeDismissesPanel
            ? String(localized: "Escape closes Open Quickly")
            : String(localized: "Escape clears the search text")
    }

    private func keyHint(_ symbol: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .frame(minWidth: 20, minHeight: 17)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(nsColor: .quaternarySystemFill))
                )
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Menu

    @ViewBuilder
    private func contextMenuActions(for item: QuickSwitcherItem) -> some View {
        Button(String(localized: "Open")) {
            viewModel.selectedItemId = item.id
            onCommit(item, .open)
        }
        if item.kind == .table || item.kind == .view || item.kind == .systemTable
            || item.kind == .savedQuery || item.kind == .queryHistory {
            Button(String(localized: "Open in New Tab")) {
                viewModel.selectedItemId = item.id
                onCommit(item, .openInNewWindowTab)
            }
        }
        if item.kind == .table || item.kind == .view || item.kind == .systemTable {
            if viewModel.canOpenStructure(item) {
                Button(String(localized: "Open Structure")) {
                    viewModel.selectedItemId = item.id
                    onCommit(item, .openStructure)
                }
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

    // MARK: - Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window is QuickSwitcherPanel else { return event }
            let command = QuickSwitcherKeyCommand.resolve(
                characters: event.charactersIgnoringModifiers ?? "",
                modifiers: event.modifierFlags,
                scopeCount: QuickSwitcherScope.allCases.count
            )
            guard let command else { return event }

            switch command {
            case let .moveSelection(offset):
                viewModel.moveSelection(by: offset)
            case let .selectScope(index):
                viewModel.scope = QuickSwitcherScope.allCases[index]
            case let .commit(intent):
                commitSelection(intent: intent)
            }
            return nil
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
        commitSelection(intent: QuickSwitcherKeyCommand.commitIntent(for: NSEvent.modifierFlags))
    }

    private func commitSelection(intent: QuickSwitcherCommitIntent) {
        Task { @MainActor in
            await viewModel.flushPendingFilter()
            guard let item = viewModel.selectedItem() else { return }
            onCommit(item, intent)
        }
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
