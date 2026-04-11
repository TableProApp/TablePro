//
//  DatabaseSwitcherSheet.swift
//  TablePro
//
//  Complete redesign of the database switcher dialog.
//  Features: Rich metadata, recent databases, refresh, create database, preview panel.
//

import AppKit
import SwiftUI
import TableProPluginKit

struct DatabaseSwitcherSheet: View {
    @Binding var isPresented: Bool
    @Environment(\.dismiss) private var dismiss

    let currentDatabase: String?
    let currentSchema: String?
    let databaseType: DatabaseType
    let connectionId: UUID
    let onSelect: (String) -> Void
    let onSelectSchema: ((String) -> Void)?

    @State private var viewModel: DatabaseSwitcherViewModel
    @State private var showCreateDialog = false

    private enum FocusField {
        case search
        case databaseList
    }

    @FocusState private var focus: FocusField?

    private var isSchemaMode: Bool { viewModel.isSchemaMode }

    /// The active name used for current-badge comparison, depending on mode.
    private var activeName: String? {
        isSchemaMode ? currentSchema : currentDatabase
    }

    init(
        isPresented: Binding<Bool>, currentDatabase: String?, currentSchema: String? = nil,
        databaseType: DatabaseType,
        connectionId: UUID, onSelect: @escaping (String) -> Void,
        onSelectSchema: ((String) -> Void)? = nil
    ) {
        self._isPresented = isPresented
        self.currentDatabase = currentDatabase
        self.currentSchema = currentSchema
        self.databaseType = databaseType
        self.connectionId = connectionId
        self.onSelect = onSelect
        self.onSelectSchema = onSelectSchema
        self._viewModel = State(
            wrappedValue: DatabaseSwitcherViewModel(
                connectionId: connectionId,
                currentDatabase: currentDatabase,
                currentSchema: currentSchema,
                databaseType: databaseType
            ))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Text(isSchemaMode
                ? String(localized: "Open Schema")
                : String(localized: "Open Database"))
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.body, weight: .semibold))
                .padding(.vertical, 12)

            // Databases / Schemas toggle (PostgreSQL only)
            if PluginManager.shared.supportsSchemaSwitching(for: databaseType) {
                Picker("", selection: $viewModel.mode) {
                    Text(String(localized: "Databases"))
                        .tag(DatabaseSwitcherViewModel.Mode.database)
                    Text(String(localized: "Schemas"))
                        .tag(DatabaseSwitcherViewModel.Mode.schema)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .onChange(of: viewModel.mode) {
                    Task { await viewModel.fetchDatabases() }
                }
            }

            Divider()

            // Toolbar: Search + Refresh + Create
            toolbar

            Divider()

            // Content
            if viewModel.isLoading {
                loadingView
            } else if let error = viewModel.errorMessage {
                errorView(error)
            } else if PluginManager.shared.connectionMode(for: databaseType) == .fileBased {
                sqliteEmptyState
            } else if viewModel.filteredDatabases.isEmpty {
                emptyState
            } else {
                databaseList
            }

            Divider()

            // Footer
            footer
        }
        .frame(width: 420, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .defaultFocus($focus, .search)
        .task { await viewModel.fetchDatabases() }
        .sheet(isPresented: $showCreateDialog) {
            CreateDatabaseSheet { name, charset, collation in
                try await viewModel.createDatabase(
                    name: name, charset: charset, collation: collation)
                await viewModel.refreshDatabases()
            }
        }
        .onExitCommand {
            // SwiftUI handles sheet priority automatically - no nested sheets take precedence
            dismiss()
        }
        .onKeyPress(.return) {
            openSelectedDatabase()
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(up: true)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(up: false)
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "jn"), phases: [.down, .repeat]) { keyPress in
            guard keyPress.modifiers.contains(.control) else { return .ignored }
            moveSelection(up: false)
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "kp"), phases: [.down, .repeat]) { keyPress in
            guard keyPress.modifiers.contains(.control) else { return .ignored }
            moveSelection(up: true)
            return .handled
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            // Search
            SearchFieldView(
                placeholder: isSchemaMode
                    ? String(localized: "Search schemas...")
                    : String(localized: "Search databases..."),
                text: $viewModel.searchText
            )
            .focused($focus, equals: .search)

            // Refresh
            Button(action: {
                Task { await viewModel.refreshDatabases() }
            }) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Refresh database list"))

            // Create (only for non-SQLite)
            if databaseType != .sqlite && !isSchemaMode {
                Button(action: { showCreateDialog = true }) {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Create new database"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Database List

    private var databaseList: some View {
        ScrollViewReader { proxy in
            List(selection: $viewModel.selectedDatabase) {
                ForEach(viewModel.filteredDatabases) { db in
                    databaseRow(db)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .focused($focus, equals: .databaseList)
            .onChange(of: viewModel.selectedDatabase) { _, newValue in
                if let item = newValue {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(item, anchor: .center)
                    }
                }
            }
        }
    }

    private func databaseRow(_ database: DatabaseMetadata) -> some View {
        let isSelected = database.name == viewModel.selectedDatabase
        let isCurrent = database.name == activeName

        return HStack(spacing: 10) {
            // Icon
            Image(systemName: database.icon)
                .font(.system(size: 14))
                .foregroundStyle(
                    isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : (database.isSystemDatabase ? Color(nsColor: .systemOrange) : Color(nsColor: .systemBlue)))

            // Name
            Text(database.name)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)

            Spacer()

            // Current badge
            if isCurrent {
                Text("current")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.7) : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                isSelected
                                    ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.15)
                                    : Color(nsColor: .quaternaryLabelColor))
                    )
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .listRowBackground(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
                .padding(.horizontal, 4)
        )
        .listRowInsets(ThemeEngine.shared.activeTheme.spacing.listRowInsets.swiftUI)
        .listRowSeparator(.hidden)
        .id(database.name)
        .tag(database.name)
        .overlay(
            DoubleClickView {
                viewModel.selectedDatabase = database.name
                openSelectedDatabase()
            }
        )
    }

    // MARK: - Empty States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
            Text(isSchemaMode
                ? String(localized: "Loading schemas...")
                : String(localized: "Loading databases..."))
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: ThemeEngine.shared.activeTheme.iconSizes.extraLarge))
                .foregroundStyle(.orange)

            Text(isSchemaMode
                ? String(localized: "Failed to load schemas")
                : String(localized: "Failed to load databases"))
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.body, weight: .medium))

            Text(message)
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Retry") {
                Task { await viewModel.fetchDatabases() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sqliteEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .font(.system(size: ThemeEngine.shared.activeTheme.iconSizes.extraLarge))
                .foregroundStyle(.secondary)

            Text("SQLite is file-based")
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.body, weight: .medium))

            Text(
                "Each SQLite file is a separate database.\nTo open a different database, create a new connection."
            )
            .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: ThemeEngine.shared.activeTheme.iconSizes.extraLarge))
                .foregroundStyle(.secondary)

            if viewModel.searchText.isEmpty {
                Text(isSchemaMode
                    ? String(localized: "No schemas found")
                    : String(localized: "No databases found"))
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.body, weight: .medium))
            } else {
                Text(isSchemaMode
                    ? String(localized: "No matching schemas")
                    : String(localized: "No matching databases"))
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.body, weight: .medium))

                Text(isSchemaMode
                    ? String(format: String(localized: "No schemas match \"%@\""), viewModel.searchText)
                    : String(format: String(localized: "No databases match \"%@\""), viewModel.searchText))
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
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
                openSelectedDatabase()
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                viewModel.selectedDatabase == nil || viewModel.selectedDatabase == activeName
            )
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(12)
    }

    // MARK: - Actions

    private func moveSelection(up: Bool) {
        let allDbs = viewModel.filteredDatabases
        guard !allDbs.isEmpty else { return }

        // Defer state update to avoid "Publishing changes from within view updates" warning
        Task { @MainActor in
            if let selected = viewModel.selectedDatabase,
               let currentIndex = allDbs.firstIndex(where: { $0.name == selected })
            {
                if up {
                    let newIndex = max(0, currentIndex - 1)
                    viewModel.selectedDatabase = allDbs[newIndex].name
                } else {
                    let newIndex = min(allDbs.count - 1, currentIndex + 1)
                    viewModel.selectedDatabase = allDbs[newIndex].name
                }
            } else {
                viewModel.selectedDatabase = up ? allDbs.last?.name : allDbs.first?.name
            }
        }
    }

    private func openSelectedDatabase() {
        guard let database = viewModel.selectedDatabase else { return }

        // Don't reopen current database/schema
        if database == activeName {
            dismiss()
            return
        }

        // Call appropriate callback
        if viewModel.isSchemaMode, PluginManager.shared.supportsSchemaSwitching(for: databaseType), let onSelectSchema {
            onSelectSchema(database)
        } else {
            onSelect(database)
        }
        dismiss()
    }
}

// MARK: - DoubleClickView

/// NSViewRepresentable that detects double-clicks without interfering with native List selection
private struct DoubleClickView: NSViewRepresentable {
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughDoubleClickView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PassThroughDoubleClickView)?.onDoubleClick = onDoubleClick
    }
}

private class PassThroughDoubleClickView: NSView {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        }
        // Always forward to next responder for List selection
        super.mouseDown(with: event)
    }
}

// MARK: - Preview

#Preview("MySQL Databases") {
    DatabaseSwitcherSheet(
        isPresented: .constant(true),
        currentDatabase: "production",
        databaseType: .mysql,
        connectionId: UUID()
    ) { _ in }
}

#Preview("SQLite Empty") {
    DatabaseSwitcherSheet(
        isPresented: .constant(true),
        currentDatabase: nil,
        databaseType: .sqlite,
        connectionId: UUID()
    ) { _ in }
}
