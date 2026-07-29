import AppKit
import SwiftUI
import TableProPluginKit

struct DatabaseSwitcherPopoverHost: View {
    weak var coordinator: MainContentCoordinator?

    var body: some View {
        if let coordinator {
            let connection = coordinator.connection
            let session = DatabaseManager.shared.session(for: connection.id)
            let switchTarget = PluginManager.shared.containerSwitchTarget(for: connection.type) ?? .database
            let activeContainer: String? = switch switchTarget {
            case .database: session?.currentDatabase ?? connection.database
            case .schema: coordinator.toolbarState.currentSchema ?? session?.currentSchema
            }

            DatabaseSwitcherPopover(
                currentDatabase: activeContainer,
                databaseType: connection.type,
                connectionId: connection.id,
                onSelect: { [weak coordinator] container in
                    Task { await coordinator?.switchContainer(to: container) }
                },
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
    let databaseType: DatabaseType
    let connectionId: UUID
    let onSelect: (String) -> Void
    let onRequestCreate: () -> Void
    let onRequestDrop: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: DatabaseSwitcherViewModel
    @State private var supportsCreateDatabase = false

    private static let popoverWidth: CGFloat = 320
    private static let popoverHeight: CGFloat = 360

    private var supportsDropDatabase: Bool {
        PluginManager.shared.supportsDropDatabase(for: databaseType)
    }
    private var showsCreateRow: Bool {
        supportsCreateDatabase
    }
    private var containerName: String {
        PluginManager.shared.containerEntityName(for: databaseType)
    }
    private var containerNamePlural: String {
        PluginManager.shared.containerEntityNamePlural(for: databaseType)
    }

    init(
        currentDatabase: String?,
        databaseType: DatabaseType,
        connectionId: UUID,
        onSelect: @escaping (String) -> Void,
        onRequestCreate: @escaping () -> Void,
        onRequestDrop: @escaping (String) -> Void
    ) {
        self.currentDatabase = currentDatabase
        self.databaseType = databaseType
        self.connectionId = connectionId
        self.onSelect = onSelect
        self.onRequestCreate = onRequestCreate
        self.onRequestDrop = onRequestDrop
        self._viewModel = State(
            wrappedValue: DatabaseSwitcherViewModel(
                connectionId: connectionId,
                currentDatabase: currentDatabase,
                databaseType: databaseType,
                sidebarState: SharedSidebarState.forConnection(connectionId)
            ))
    }

    var body: some View {
        VStack(spacing: 0) {
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
    }

    private var refreshShortcut: some View {
        Button("") {
            Task { await viewModel.refreshDatabases() }
        }
        .keyboardShortcut("r", modifiers: .command)
        .hidden()
    }

    private var searchField: some View {
        NativeSearchField(
            text: $viewModel.searchText,
            placeholder: String(format: String(localized: "Search %@"), containerNamePlural.lowercased()),
            onMoveUp: { viewModel.moveUp() },
            onMoveDown: { viewModel.moveDown() },
            onSubmit: { commitSelection() },
            focusOnAppear: true
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
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
        let isCurrent = database.name == currentDatabase
        return HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .opacity(isCurrent ? 1 : 0)
                .frame(width: 14)

            Image(systemName: database.icon)
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

    @ViewBuilder
    private func contextMenuItems(for selection: Set<String>) -> some View {
        if supportsDropDatabase,
           let name = selection.first,
           let database = viewModel.filteredDatabases.first(where: { $0.name == name }),
           !database.isSystemDatabase,
           database.name != currentDatabase {
            Button(role: .destructive) {
                dismiss()
                onRequestDrop(database.name)
            } label: {
                Label(String(format: String(localized: "Drop %@…"), containerName), systemImage: "trash")
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(String(format: String(localized: "Loading %@…"), containerNamePlural.lowercased()))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(.orange)
            Text(String(format: String(localized: "Failed to load %@"), containerNamePlural.lowercased()))
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
                Text(String(format: String(localized: "No %@"), containerNamePlural.lowercased()))
                    .font(.callout.weight(.medium))
            } else {
                Text(String(
                    format: String(localized: "No %1$@ match “%2$@”"),
                    containerNamePlural.lowercased(),
                    viewModel.searchText
                ))
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
                Label(String(format: String(localized: "New %@…"), containerName), systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .help(String(format: String(localized: "New %@ (⌘N)"), containerName))
            .keyboardShortcut("n", modifiers: .command)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func commitSelection() {
        guard let name = viewModel.selectedDatabase else { return }
        if name == currentDatabase {
            dismiss()
            return
        }
        onSelect(name)
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
