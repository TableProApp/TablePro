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
    /// What the sheet is being used for. `switch` (default) switches the active
    /// database/schema; `backup` picks a database to feed into a backup flow;
    /// `restore` picks the target database for a restore flow.
    enum Mode {
        case `switch`
        case backup
        case restore
    }

    /// Modes that pick a database for an out-of-band flow (backup / restore).
    /// These share UI affordances: schemas tab hidden, create/drop hidden,
    /// the primary button doesn't auto-dismiss.
    private var isHandoffMode: Bool {
        mode == .backup || mode == .restore
    }

    @Binding var isPresented: Bool
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    let currentDatabase: String?
    let currentSchema: String?
    let databaseType: DatabaseType
    let connectionId: UUID
    let onSelect: (String) -> Void
    let onSelectSchema: ((String) -> Void)?

    @State private var viewModel: DatabaseSwitcherViewModel
    @State private var showCreateDialog = false
    @State private var showDropDialog = false
    @State private var databaseToDrop: String?
    @State private var supportsCreateDatabase = false

    private enum FocusField {
        case databaseList
    }

    @FocusState private var focus: FocusField?

    private var isSchemaMode: Bool { viewModel.isSchemaMode }

    /// The active name used for current-badge comparison, depending on mode.
    private var activeName: String? {
        isSchemaMode ? currentSchema : currentDatabase
    }

    init(
        isPresented: Binding<Bool>,
        mode: Mode = .switch,
        currentDatabase: String?,
        currentSchema: String? = nil,
        databaseType: DatabaseType,
        connectionId: UUID,
        onSelect: @escaping (String) -> Void,
        onSelectSchema: ((String) -> Void)? = nil
    ) {
        self._isPresented = isPresented
        self.mode = mode
        self.currentDatabase = currentDatabase
        self.currentSchema = currentSchema
        self.databaseType = databaseType
        self.connectionId = connectionId
        self.onSelect = onSelect
        self.onSelectSchema = onSelectSchema
        // Backup and restore always operate at the database level (pg_dump
        // dumps a whole database). Force .database so PostgreSQL doesn't
        // open the picker in schema mode.
        let initialMode: DatabaseSwitcherViewModel.Mode? = (mode == .backup || mode == .restore)
            ? .database
            : nil
        self._viewModel = State(
            wrappedValue: DatabaseSwitcherViewModel(
                connectionId: connectionId,
                currentDatabase: currentDatabase,
                currentSchema: currentSchema,
                databaseType: databaseType,
                initialMode: initialMode
            ))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Databases / Schemas toggle (PostgreSQL only); hidden for handoff flows.
            if !isHandoffMode, PluginManager.shared.supportsSchemaSwitching(for: databaseType) {
                Picker("", selection: $viewModel.mode) {
                    Text(String(localized: "Databases"))
                        .tag(DatabaseSwitcherViewModel.Mode.database)
                    Text(String(localized: "Schemas"))
                        .tag(DatabaseSwitcherViewModel.Mode.schema)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .padding(.top, 12)
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
        .navigationTitle(navigationTitleString)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await viewModel.fetchDatabases() }
        .task { await refreshCreateSupport() }
        .sheet(isPresented: $showCreateDialog) {
            CreateDatabaseSheet(databaseType: databaseType, viewModel: viewModel)
        }
        .sheet(isPresented: $showDropDialog) {
            if let name = databaseToDrop {
                DropDatabaseSheet(databaseName: name, viewModel: viewModel) {
                    databaseToDrop = nil
                }
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
        .onKeyPress(.delete) {
            guard canDropSelected else { return .ignored }
            initiateDropForSelected()
            return .handled
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            NativeSearchField(
                text: $viewModel.searchText,
                placeholder: isSchemaMode
                    ? String(localized: "Search schemas...")
                    : String(localized: "Search databases..."),
                onMoveUp: { viewModel.moveUp() },
                onMoveDown: { viewModel.moveDown() },
                focusOnAppear: true
            )

            // Refresh
            Button(action: {
                Task { await viewModel.refreshDatabases() }
            }) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Refresh database list"))

            if !isHandoffMode, !isSchemaMode, supportsCreateDatabase {
                Button(action: { showCreateDialog = true }) {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Create new database"))
            }

            // Drop
            if !isHandoffMode, !isSchemaMode, PluginManager.shared.supportsDropDatabase(for: databaseType) {
                Button(action: { initiateDropForSelected() }) {
                    Image(systemName: "trash")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(!canDropSelected)
                .help(String(localized: "Drop selected database"))
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
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .focused($focus, equals: .databaseList)
            .contextMenu(forSelectionType: String.self) { selection in
                contextMenuItems(for: selection)
            } primaryAction: { selection in
                guard let name = selection.first else { return }
                viewModel.selectedDatabase = name
                openSelectedDatabase()
            }
            .onChange(of: viewModel.selectedDatabase) { _, newValue in
                if let item = newValue {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(item, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenuItems(for selection: Set<String>) -> some View {
        if !isSchemaMode,
           PluginManager.shared.supportsDropDatabase(for: databaseType),
           let name = selection.first,
           let database = viewModel.filteredDatabases.first(where: { $0.name == name }),
           !database.isSystemDatabase,
           database.name != activeName {
            Button(role: .destructive) {
                databaseToDrop = database.name
                showDropDialog = true
            } label: {
                Label(String(localized: "Drop Database..."), systemImage: "trash")
            }
        }
    }

    private func databaseRow(_ database: DatabaseMetadata) -> some View {
        let isCurrent = database.name == activeName

        return HStack(spacing: 10) {
            Image(systemName: database.icon)
                .font(.body)
                .foregroundStyle(database.isSystemDatabase ? Color(nsColor: .systemOrange) : Color(nsColor: .systemBlue))

            Text(database.name)
                .font(.body)

            Spacer()

            if isCurrent {
                Text("current")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(nsColor: .quaternaryLabelColor))
                    )
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        .listRowSeparator(.hidden)
        .id(database.name)
        .tag(database.name)
    }

    // MARK: - Empty States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
            Text(isSchemaMode
                ? String(localized: "Loading schemas...")
                : String(localized: "Loading databases..."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(Color(nsColor: .systemOrange))

            Text(isSchemaMode
                ? String(localized: "Failed to load schemas")
                : String(localized: "Failed to load databases"))
                .font(.body.weight(.medium))

            Text(message)
                .font(.subheadline)
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
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("SQLite is file-based")
                .font(.body.weight(.medium))

            Text(
                "Each SQLite file is a separate database.\nTo open a different database, create a new connection."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)

            if viewModel.searchText.isEmpty {
                Text(isSchemaMode
                    ? String(localized: "No schemas found")
                    : String(localized: "No databases found"))
                    .font(.body.weight(.medium))
            } else {
                Text(isSchemaMode
                    ? String(localized: "No matching schemas")
                    : String(localized: "No matching databases"))
                    .font(.body.weight(.medium))

                Text(isSchemaMode
                    ? String(format: String(localized: "No schemas match \"%@\""), viewModel.searchText)
                    : String(format: String(localized: "No databases match \"%@\""), viewModel.searchText))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var navigationTitleString: String {
        switch mode {
        case .switch:
            return isSchemaMode
                ? String(localized: "Open Schema")
                : String(localized: "Open Database")
        case .backup:
            return String(localized: "Backup Dump")
        case .restore:
            return String(localized: "Restore Dump")
        }
    }

    private var primaryButtonLabel: String {
        switch mode {
        case .switch: return String(localized: "Open")
        case .backup: return String(localized: "Backup Dump\u{2026}")
        case .restore: return String(localized: "Restore Dump\u{2026}")
        }
    }

    private var primaryButtonDisabled: Bool {
        guard let selected = viewModel.selectedDatabase else { return true }
        // In switch mode, picking the already-active database/schema is a no-op.
        // In backup/restore modes the active database is a valid target.
        if mode == .switch, selected == activeName { return true }
        return false
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }

            Spacer()

            Button(primaryButtonLabel) {
                openSelectedDatabase()
            }
            .buttonStyle(.borderedProminent)
            .disabled(primaryButtonDisabled)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(12)
    }

    // MARK: - Drop Helpers

    private var canDropSelected: Bool {
        guard !isSchemaMode,
              PluginManager.shared.supportsDropDatabase(for: databaseType),
              let selected = viewModel.selectedDatabase,
              selected != activeName
        else { return false }
        let isSystem = viewModel.filteredDatabases.first { $0.name == selected }?.isSystemDatabase ?? false
        return !isSystem
    }

    private func initiateDropForSelected() {
        guard canDropSelected, let selected = viewModel.selectedDatabase else { return }
        databaseToDrop = selected
        showDropDialog = true
    }

    // MARK: - Actions

    private func refreshCreateSupport() async {
        do {
            let spec = try await viewModel.loadCreateDatabaseForm()
            supportsCreateDatabase = spec != nil
        } catch {
            supportsCreateDatabase = false
        }
    }

    private func openSelectedDatabase() {
        guard let database = viewModel.selectedDatabase else { return }

        // Backup/restore: hand the selection off to the parent flow without
        // dismissing. The host sheet stays mounted and transitions to the
        // next step (save/open panel, then progress).
        if isHandoffMode {
            onSelect(database)
            return
        }

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
