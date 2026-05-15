import AppKit
import SwiftUI
import TableProPluginKit

/// Bridges the toolbar's weak coordinator reference to a concrete `DatabaseSwitcherPopover`.
/// Resolves the current database/schema at presentation time so the popover always reflects
/// the active session, even after the user switches between tabs.
struct DatabaseSwitcherPopoverHost: View {
    weak var coordinator: MainContentCoordinator?

    var body: some View {
        if let coordinator {
            let connection = coordinator.connection
            let session = DatabaseManager.shared.session(for: connection.id)
            let activeDatabase = session?.currentDatabase ?? connection.database
            let activeSchema = session?.currentSchema

            DatabaseSwitcherPopover(
                currentDatabase: activeDatabase,
                currentSchema: activeSchema,
                databaseType: connection.type,
                connectionId: connection.id,
                onSelect: { [weak coordinator] database in
                    Task { await coordinator?.switchDatabase(to: database) }
                },
                onSelectSchema: PluginManager.shared.supportsSchemaSwitching(for: connection.type)
                    ? { [weak coordinator] schema in
                        Task { await coordinator?.switchSchema(to: schema) }
                    }
                    : nil,
                onRequestCreate: { [weak coordinator] in
                    coordinator?.activeSheet = .createDatabase
                },
                onRequestDrop: { [weak coordinator] name in
                    coordinator?.databaseToDrop = name
                }
            )
        } else {
            EmptyView()
        }
    }
}

struct DatabaseSwitcherPopover: View {
    let currentDatabase: String?
    let currentSchema: String?
    let databaseType: DatabaseType
    let connectionId: UUID
    let onSelect: (String) -> Void
    let onSelectSchema: ((String) -> Void)?
    let onRequestCreate: () -> Void
    let onRequestDrop: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: DatabaseSwitcherViewModel
    @State private var supportsCreateDatabase = false

    private enum FocusField {
        case search
        case list
    }

    @FocusState private var focus: FocusField?

    /// Fixed popover dimensions. Matches the native pattern of Emoji Picker,
    /// Font Panel, and Color Picker — popovers with tabs and search keep stable
    /// chrome and a stable frame so switching tabs doesn't reflow the surface.
    private static let popoverWidth: CGFloat = 320
    private static let popoverHeight: CGFloat = 360

    private var isSchemaMode: Bool { viewModel.isSchemaMode }
    private var activeName: String? { isSchemaMode ? currentSchema : currentDatabase }
    private var supportsDropDatabase: Bool {
        !isSchemaMode && PluginManager.shared.supportsDropDatabase(for: databaseType)
    }
    private var supportsSchemaSwitching: Bool {
        PluginManager.shared.supportsSchemaSwitching(for: databaseType)
    }
    private var showsCreateRow: Bool {
        !isSchemaMode && supportsCreateDatabase
    }

    init(
        currentDatabase: String?,
        currentSchema: String?,
        databaseType: DatabaseType,
        connectionId: UUID,
        onSelect: @escaping (String) -> Void,
        onSelectSchema: ((String) -> Void)? = nil,
        onRequestCreate: @escaping () -> Void,
        onRequestDrop: @escaping (String) -> Void
    ) {
        self.currentDatabase = currentDatabase
        self.currentSchema = currentSchema
        self.databaseType = databaseType
        self.connectionId = connectionId
        self.onSelect = onSelect
        self.onSelectSchema = onSelectSchema
        self.onRequestCreate = onRequestCreate
        self.onRequestDrop = onRequestDrop
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
            if supportsSchemaSwitching {
                modePicker
                Divider()
            }

            searchField

            Divider()

            content

            if showsCreateRow {
                Divider()
                createButton
            }
        }
        .frame(width: Self.popoverWidth, height: Self.popoverHeight)
        .background(refreshShortcut)
        .task { await viewModel.fetchDatabases() }
        .task { await refreshCreateSupport() }
        .onKeyPress(.return) {
            commitSelection()
            return .handled
        }
        .onKeyPress(.upArrow) {
            viewModel.moveUp()
            return .handled
        }
        .onKeyPress(.downArrow) {
            viewModel.moveDown()
            return .handled
        }
    }

    /// Hidden ⌘R binding. Native popovers (Mail mailbox switcher, Safari tab group
    /// picker) don't show a visible refresh button — they auto-refresh on open via
    /// `.task`. We keep the shortcut for power users.
    private var refreshShortcut: some View {
        Button("") {
            Task { await viewModel.refreshDatabases() }
        }
        .keyboardShortcut("r", modifiers: .command)
        .hidden()
    }

    private var modePicker: some View {
        Picker("", selection: $viewModel.mode) {
            Text(String(localized: "Databases"))
                .tag(DatabaseSwitcherViewModel.Mode.database)
            Text(String(localized: "Schemas"))
                .tag(DatabaseSwitcherViewModel.Mode.schema)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onChange(of: viewModel.mode) {
            Task { await viewModel.fetchDatabases() }
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .frame(width: 14)

            TextField(
                "",
                text: $viewModel.searchText,
                prompt: Text(searchPlaceholder)
                    .foregroundStyle(.tertiary)
            )
            .textFieldStyle(.plain)
            .font(.body)
            .focused($focus, equals: .search)
            .onKeyPress(.downArrow) {
                viewModel.moveDown()
                return .handled
            }
            .onKeyPress(.upArrow) {
                viewModel.moveUp()
                return .handled
            }
            .onKeyPress(.return) {
                commitSelection()
                return .handled
            }
            .onKeyPress(.escape) {
                if viewModel.searchText.isEmpty {
                    return .ignored
                }
                viewModel.searchText = ""
                return .handled
            }

            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35))
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .onAppear { focus = .search }
    }

    private var searchPlaceholder: String {
        isSchemaMode
            ? String(localized: "Search schemas")
            : String(localized: "Search databases")
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            loadingView
        } else if let error = viewModel.errorMessage {
            errorView(error)
        } else if PluginManager.shared.connectionMode(for: databaseType) == .fileBased {
            sqliteState
        } else if viewModel.filteredDatabases.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List(selection: $viewModel.selectedDatabase) {
                ForEach(viewModel.filteredDatabases) { db in
                    row(for: db)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .focused($focus, equals: .list)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contextMenu(forSelectionType: String.self) { selection in
                contextMenuItems(for: selection)
            } primaryAction: { selection in
                guard let name = selection.first else { return }
                viewModel.selectedDatabase = name
                commitSelection()
            }
            .onChange(of: viewModel.selectedDatabase) { _, newValue in
                guard let item = newValue else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(item)
                }
            }
        }
    }

    private func row(for database: DatabaseMetadata) -> some View {
        let isCurrent = database.name == activeName
        return HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .opacity(isCurrent ? 1 : 0)
                .frame(width: 14)

            Image(systemName: rowIcon(for: database))
                .font(.body)
                .foregroundStyle(database.isSystemDatabase ? Color.secondary : Color.accentColor)
                .frame(width: 16)

            Text(database.name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        .listRowSeparator(.hidden)
        .id(database.name)
        .tag(database.name)
    }

    private func rowIcon(for database: DatabaseMetadata) -> String {
        if isSchemaMode {
            return "folder.fill"
        }
        return database.icon
    }

    @ViewBuilder
    private func contextMenuItems(for selection: Set<String>) -> some View {
        if supportsDropDatabase,
           let name = selection.first,
           let database = viewModel.filteredDatabases.first(where: { $0.name == name }),
           !database.isSystemDatabase,
           database.name != activeName {
            Button(role: .destructive) {
                dismiss()
                onRequestDrop(database.name)
            } label: {
                Label(String(localized: "Drop Database…"), systemImage: "trash")
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(isSchemaMode
                ? String(localized: "Loading schemas…")
                : String(localized: "Loading databases…"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(Color(nsColor: .systemOrange))
            Text(isSchemaMode
                ? String(localized: "Failed to load schemas")
                : String(localized: "Failed to load databases"))
                .font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            Button(String(localized: "Retry")) {
                Task { await viewModel.fetchDatabases() }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 12)
    }

    private var sqliteState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(String(localized: "SQLite is file-based"))
                .font(.callout.weight(.medium))
            Text(String(localized: "Open a different file from the Welcome window."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
            if viewModel.searchText.isEmpty {
                Text(isSchemaMode
                    ? String(localized: "No schemas")
                    : String(localized: "No databases"))
                    .font(.callout.weight(.medium))
            } else {
                Text(isSchemaMode
                    ? String(format: String(localized: "No schemas match “%@”"), viewModel.searchText)
                    : String(format: String(localized: "No databases match “%@”"), viewModel.searchText))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 12)
    }

    private var createButton: some View {
        HStack {
            Button {
                dismiss()
                onRequestCreate()
            } label: {
                Label(String(localized: "New Database…"), systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "New Database (⌘N)"))
            .keyboardShortcut("n", modifiers: .command)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func commitSelection() {
        guard let name = viewModel.selectedDatabase else { return }
        if name == activeName {
            dismiss()
            return
        }
        if isSchemaMode, supportsSchemaSwitching, let onSelectSchema {
            onSelectSchema(name)
        } else {
            onSelect(name)
        }
        dismiss()
    }

    private func refreshCreateSupport() async {
        do {
            let spec = try await viewModel.loadCreateDatabaseForm()
            supportsCreateDatabase = spec != nil
        } catch {
            supportsCreateDatabase = false
        }
    }
}
