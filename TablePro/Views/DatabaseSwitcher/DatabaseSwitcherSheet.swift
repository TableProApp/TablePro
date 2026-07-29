import AppKit
import SwiftUI
import TableProPluginKit

/// Database picker presented as a modal sheet for backup and restore flows.
/// Quick database switching from the toolbar uses `DatabaseSwitcherPopover`.
struct DatabaseSwitcherSheet: View {
    enum Mode {
        case backup
        case restore
    }

    @Binding var isPresented: Bool
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    let currentDatabase: String?
    let databaseType: DatabaseType
    let connectionId: UUID
    let onSelect: (String) -> Void

    @State private var viewModel: DatabaseSwitcherViewModel

    private enum FocusField { case list }

    @FocusState private var focus: FocusField?

    init(
        isPresented: Binding<Bool>,
        mode: Mode,
        currentDatabase: String?,
        databaseType: DatabaseType,
        connectionId: UUID,
        onSelect: @escaping (String) -> Void
    ) {
        self._isPresented = isPresented
        self.mode = mode
        self.currentDatabase = currentDatabase
        self.databaseType = databaseType
        self.connectionId = connectionId
        self.onSelect = onSelect
        self._viewModel = State(
            wrappedValue: DatabaseSwitcherViewModel(
                connectionId: connectionId,
                currentDatabase: currentDatabase,
                databaseType: databaseType,
                sidebarState: SharedSidebarState.forConnection(connectionId)
            ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                Divider()
                content
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(primaryButtonLabel) {
                        commitSelection()
                    }
                    .disabled(primaryButtonDisabled)
                }
            }
        }
        .frame(width: 480, height: 460)
        .onExitCommand { dismiss() }
        .task { await viewModel.fetchDatabases() }
    }

    private var navigationTitle: String {
        switch mode {
        case .backup: return String(localized: "Backup Database")
        case .restore: return String(localized: "Restore Database")
        }
    }

    private var primaryButtonLabel: String {
        switch mode {
        case .backup: return String(localized: "Choose Destination…")
        case .restore: return String(localized: "Restore…")
        }
    }

    private var primaryButtonDisabled: Bool {
        viewModel.selectedDatabase == nil
    }

    private var searchField: some View {
        NativeSearchField(
            text: $viewModel.searchText,
            placeholder: String(localized: "Search databases"),
            onMoveUp: { viewModel.moveUp() },
            onMoveDown: { viewModel.moveDown() },
            focusOnAppear: true
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            loadingView
        } else if let error = viewModel.errorMessage {
            errorView(error)
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
            .onChange(of: viewModel.selectedDatabase) { _, newValue in
                guard let item = newValue else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(item, anchor: .center)
                }
            }
            .onKeyPress(.return) {
                commitSelection()
                return .handled
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
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .listRowSeparator(.hidden)
        .id(database.name)
        .tag(database.name)
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(String(localized: "Loading databases…"))
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
            Text(String(localized: "Failed to load databases"))
                .font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            Button(String(localized: "Retry")) {
                Task { await viewModel.fetchDatabases() }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
            if viewModel.searchText.isEmpty {
                Text(String(localized: "No databases"))
                    .font(.callout.weight(.medium))
            } else {
                Text(String(format: String(localized: "No databases match “%@”"), viewModel.searchText))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func commitSelection() {
        guard let database = viewModel.selectedDatabase else { return }
        onSelect(database)
    }
}

#Preview("Backup") {
    DatabaseSwitcherSheet(
        isPresented: .constant(true),
        mode: .backup,
        currentDatabase: "production",
        databaseType: .postgresql,
        connectionId: UUID()
    ) { _ in }
}
