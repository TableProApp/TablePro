//
//  DatabaseTreeView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

struct DatabaseTreeTableRef: Hashable, Identifiable {
    let database: String
    let schema: String?
    let table: TableInfo

    var id: String {
        "\(database)|\(schema ?? "")|\(table.id)"
    }

    static func == (lhs: DatabaseTreeTableRef, rhs: DatabaseTreeTableRef) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct DatabaseTreeRoutineRef: Identifiable {
    let database: String
    let schema: String?
    let routine: RoutineInfo

    var id: String {
        "\(database)|\(schema ?? "")|\(routine.id)"
    }
}

struct DatabaseTreeView: View {
    @Bindable private var treeService = DatabaseTreeMetadataService.shared

    let connectionId: UUID
    let databaseType: DatabaseType
    let viewModel: SidebarViewModel
    let windowState: WindowSidebarState
    @Binding var pendingTruncates: Set<String>
    @Binding var pendingDeletes: Set<String>
    let coordinator: MainContentCoordinator?
    let sidebarState: SharedSidebarState

    @State private var searchText: String = ""

    private var activeDatabase: String? {
        let name = coordinator?.toolbarState.currentDatabase ?? ""
        return name.isEmpty ? nil : name
    }

    private var activeSchema: String? {
        coordinator?.toolbarState.currentSchema
    }

    private var isConnected: Bool {
        DatabaseManager.shared.session(for: connectionId)?.status == .connected
    }

    private var connectionToken: String {
        isConnected ? "connected" : "down"
    }

    private var databases: [DatabaseMetadata] {
        treeService.databases(for: connectionId)
    }

    private var filteredDatabases: [DatabaseMetadata] {
        DatabaseTreeVisibility.visible(databases: databases, selected: sidebarState.databaseFilterSelected)
    }

    private var isFilterHidingEverything: Bool {
        DatabaseTreeVisibility.isFiltering(selected: sidebarState.databaseFilterSelected)
            && filteredDatabases.isEmpty
    }

    var body: some View {
        Group {
            switch treeService.databaseListState(for: connectionId) {
            case .failed(let message):
                errorState(message: message)
            case .loaded where databases.isEmpty:
                emptyDatabasesState
            case .loaded where isFilterHidingEverything:
                filteredEmptyState
            case .loaded:
                outline
            case .idle, .loading:
                loadingState
            }
        }
        .task(id: connectionToken) {
            await treeService.loadDatabases(connectionId: connectionId, databaseType: databaseType)
        }
        .task(id: viewModel.searchText) {
            let live = viewModel.searchText
            guard !live.isEmpty else { searchText = ""; return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            searchText = live
        }
    }

    private var outline: some View {
        DatabaseTreeOutlineView(
            connectionId: connectionId,
            databaseType: databaseType,
            coordinator: coordinator,
            windowState: windowState,
            sidebarState: sidebarState,
            viewModel: viewModel,
            pendingTruncates: pendingTruncates,
            pendingDeletes: pendingDeletes,
            searchText: searchText,
            connectionToken: connectionToken,
            activeDatabase: activeDatabase,
            activeSchema: activeSchema
        )
    }

    private var loadingState: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyDatabasesState: some View {
        ContentUnavailableView(
            String(localized: "No Databases"),
            systemImage: "cylinder",
            description: Text("This server has no databases yet.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredEmptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "No Databases Shown"), systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("The database filter hides every database on this connection.")
        } actions: {
            Button(String(localized: "Show All")) {
                sidebarState.databaseFilterSelected = []
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
