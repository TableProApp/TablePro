//
//  HistoryPanelView.swift
//  TablePro
//
//  Pure SwiftUI query history panel with split-view layout.
//  Left pane: history list with search/filter. Right pane: query preview.
//

import AppKit
import SwiftUI

/// Query history panel with master-detail layout
struct HistoryPanelView: View {
    let connectionId: UUID
    // MARK: - State

    @State private var selectedEntryID: UUID?
    @State private var searchText = ""
    @State private var dateFilter: UIDateFilter = .all
    @State private var entries: [QueryHistoryEntry] = []
    @State private var showClearAllAlert = false
    @State private var searchTask: Task<Void, Never>?
    @State private var copyButtonTitle = String(localized: "Copy Query")
    @State private var copyResetTask: Task<Void, Never>?
    @State private var favoriteDialogQuery: FavoriteDialogQuery?
    @FocusedValue(\.commandActions) private var actions

    private let dataProvider = HistoryDataProvider()

    // MARK: - Computed

    private var selectedEntry: QueryHistoryEntry? {
        guard let id = selectedEntryID else { return nil }
        return entries.first { $0.id == id }
    }

    // MARK: - Body

    var body: some View {
        HSplitView {
            historyList
                .frame(minWidth: 200, idealWidth: 250)

            queryPreview
                .frame(minWidth: 300)
        }
        .onAppear {
            restoreFilterState()
            loadData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .queryHistoryDidUpdate)) { _ in
            loadData()
        }
        .sheet(item: $favoriteDialogQuery) { item in
            FavoriteEditDialog(
                connectionId: connectionId,
                favorite: nil,
                initialQuery: item.query,
                folders: []
            )
        }
    }
}

// MARK: - History List (Left Pane)

private extension HistoryPanelView {
    var historyList: some View {
        VStack(spacing: 0) {
            // Header with filter controls and search
            VStack(spacing: 8) {
                HStack {
                    Spacer()

                    Button {
                        showClearAllAlert = true
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .disabled(entries.isEmpty)
                    .help(String(localized: "Clear all history"))
                    .accessibilityLabel(String(localized: "Clear all history"))

                    Picker("", selection: $dateFilter) {
                        ForEach(UIDateFilter.allCases, id: \.self) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }

                TextField(String(localized: "Search queries..."), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
            .padding(12)

            Divider()

            // Entry list or empty state
            if entries.isEmpty {
                emptyState
            } else {
                List(entries, selection: $selectedEntryID) { entry in
                    HistoryRowSwiftUI(entry: entry)
                        .tag(entry.id)
                        .contextMenu { contextMenu(for: entry) }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, ThemeEngine.shared.activeTheme.rowHeights.comfortable)
                .onDeleteCommand {
                    deleteSelectedEntry()
                }
                .onCopyCommand {
                    copySelectedQuery()
                    return []
                }
            }
        }
        .alert(String(localized: "Clear All History?"), isPresented: $showClearAllAlert) {
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Clear All"), role: .destructive) {
                Task { @MainActor in
                    _ = await dataProvider.clearAll()
                    entries = dataProvider.historyEntries
                }
            }
        } message: {
            let count = entries.count
            let itemName = count == 1
                ? String(localized: "history entry")
                : String(localized: "history entries")
            Text("This will permanently delete \(count) \(itemName). This action cannot be undone.")
        }
        .onChange(of: dateFilter) {
            saveFilterState()
            loadData()
        }
        .onChange(of: searchText) {
            scheduleSearch()
        }
    }

    // MARK: - Empty States

    var emptyState: some View {
        VStack(spacing: 8) {
            if !searchText.isEmpty || dateFilter != .all {
                Image(systemName: "magnifyingglass")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text("No Matching Queries")
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.body, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Try adjusting your search terms\nor date filter.")
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text("No Query History Yet")
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.body, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Your executed queries will\nappear here for quick access.")
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Context Menu

    @ViewBuilder
    func contextMenu(for entry: QueryHistoryEntry) -> some View {
        Button {
            copyQuery(entry)
        } label: {
            Label(String(localized: "Copy Query"), systemImage: "doc.on.doc")
        }

        Button {
            runInNewTab(entry)
        } label: {
            Label(String(localized: "Run in New Tab"), systemImage: "play")
        }

        Button {
            favoriteDialogQuery = FavoriteDialogQuery(query: entry.query)
        } label: {
            Label(String(localized: "Save as Favorite"), systemImage: "star")
        }

        Divider()

        Button(role: .destructive) {
            deleteEntry(entry)
        } label: {
            Label(String(localized: "Delete"), systemImage: "trash")
        }
    }
}

// MARK: - Query Preview (Right Pane)

private extension HistoryPanelView {
    @ViewBuilder
    var queryPreview: some View {
        if let entry = selectedEntry {
            VStack(spacing: 0) {
                // Query text with syntax highlighting
                HighlightedSQLTextView(
                    sql: entry.query.hasSuffix(";") ? entry.query : entry.query + ";",
                    databaseType: entry.query.trimmingCharacters(in: .whitespaces)
                        .hasPrefix("db.") ? .mongodb : .mysql
                )
                .background(Color(nsColor: ThemeEngine.shared.colors.editor.background))

                Divider()

                // Metadata
                VStack(alignment: .leading, spacing: 4) {
                    Text(buildPrimaryMetadata(entry))
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                        .foregroundStyle(.secondary)
                    Text(buildSecondaryMetadata(entry))
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)

                Divider()

                // Action buttons
                HStack {
                    Button(copyButtonTitle) {
                        copyQueryWithFeedback(entry)
                    }
                    .controlSize(.small)

                    Spacer()

                    Button(String(localized: "Load in Editor")) {
                        loadInEditor(entry)
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
        } else {
            previewEmptyState
        }
    }

    var previewEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("Select a Query")
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.title3, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Choose a query from the list\nto see its full content here.")
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Metadata Builders

    func buildPrimaryMetadata(_ entry: QueryHistoryEntry) -> String {
        var parts: [String] = []
        parts.append("Database: \(entry.databaseName)")
        parts.append(entry.formattedExecutionTime)

        if entry.rowCount >= 0 {
            parts.append(entry.formattedRowCount)
        }

        return parts.joined(separator: "  |  ")
    }

    private static let metadataDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    func buildSecondaryMetadata(_ entry: QueryHistoryEntry) -> String {
        let executedAt = Self.metadataDateFormatter.string(from: entry.executedAt)
        var text = String(format: String(localized: "Executed: %@"), executedAt)

        if !entry.wasSuccessful, let error = entry.errorMessage {
            text += "\nError: \(error)"
        }

        return text
    }
}

// MARK: - Actions

private extension HistoryPanelView {
    func loadData() {
        dataProvider.dateFilter = dateFilter
        dataProvider.searchText = searchText
        Task { @MainActor in
            await dataProvider.loadData()
            entries = dataProvider.historyEntries

            // Clear selection if the selected entry no longer exists
            if let id = selectedEntryID, !entries.contains(where: { $0.id == id }) {
                selectedEntryID = nil
            }
        }
    }

    func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            loadData()
        }
    }

    func deleteEntry(_ entry: QueryHistoryEntry) {
        Task { @MainActor in
            _ = await dataProvider.deleteEntry(id: entry.id)
            entries = dataProvider.historyEntries
        }
    }

    func deleteSelectedEntry() {
        guard let entry = selectedEntry else { return }
        let currentIndex = entries.firstIndex(of: entry)
        deleteEntry(entry)

        // After deletion triggers reload, select adjacent entry
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            if let idx = currentIndex, !entries.isEmpty {
                let newIndex = min(idx, entries.count - 1)
                if newIndex >= 0, newIndex < entries.count {
                    selectedEntryID = entries[newIndex].id
                }
            }
        }
    }

    func copyQuery(_ entry: QueryHistoryEntry) {
        ClipboardService.shared.writeText(entry.query)
    }

    func copySelectedQuery() {
        guard let entry = selectedEntry else { return }
        copyQuery(entry)
    }

    func copyQueryWithFeedback(_ entry: QueryHistoryEntry) {
        copyQuery(entry)
        copyButtonTitle = String(localized: "Copied!")
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            copyButtonTitle = String(localized: "Copy Query")
        }
    }

    func loadInEditor(_ entry: QueryHistoryEntry) {
        actions?.loadQueryIntoEditor(entry.query)
    }

    func runInNewTab(_ entry: QueryHistoryEntry) {
        actions?.newTab(initialQuery: entry.query)
    }

    // MARK: - Filter State Persistence

    func restoreFilterState() {
        let savedFilter = UserDefaults.standard.integer(forKey: "HistoryPanel.dateFilter")
        if let filter = UIDateFilter(rawValue: savedFilter) {
            dateFilter = filter
        }
    }

    func saveFilterState() {
        UserDefaults.standard.set(dateFilter.rawValue, forKey: "HistoryPanel.dateFilter")
    }
}

// MARK: - History Row

/// Single history entry row view
private struct HistoryRowSwiftUI: View {
    let entry: QueryHistoryEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.wasSuccessful ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(entry.wasSuccessful ? Color(nsColor: .systemGreen) : Color(nsColor: .systemRed))
                .font(.system(size: ThemeEngine.shared.activeTheme.iconSizes.default))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.queryPreview)
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium, design: .monospaced))
                    .lineLimit(1)

                Text(entry.databaseName)
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack {
                    Text(relativeTime(entry.executedAt))
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(entry.formattedExecutionTime)
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

#if DEBUG
struct HistoryPanelView_Previews: PreviewProvider {
    static var previews: some View {
        HistoryPanelView(connectionId: UUID())
            .frame(width: 600, height: 300)
    }
}
#endif
