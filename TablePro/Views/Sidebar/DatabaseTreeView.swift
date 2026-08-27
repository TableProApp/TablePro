//
//  DatabaseTreeView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

struct DatabaseTreeRoutineRef: Identifiable, Equatable {
    let database: String?
    let schema: String?
    let routine: RoutineInfo

    var id: String {
        "\(database ?? "")|\(schema ?? "")|\(routine.id)"
    }

    var objectRef: DatabaseObjectRef {
        DatabaseObjectRef(routine: routine, database: database ?? "")
    }
}

struct DatabaseTreeTriggerRef: Identifiable, Equatable {
    let database: String?
    let schema: String?
    let trigger: TriggerInfo

    var id: String {
        "\(database ?? "")|\(schema ?? "")|\(trigger.id)"
    }

    var objectRef: DatabaseObjectRef {
        DatabaseObjectRef(trigger: trigger, database: database ?? "")
    }
}

struct DatabaseTreeView: View {
    @Bindable private var treeService = DatabaseTreeMetadataService.shared

    let connectionId: UUID
    let databaseType: DatabaseType
    let viewModel: SidebarViewModel
    let windowState: WindowSidebarState
    @Binding var pendingTruncates: Set<DatabaseTreeTableRef>
    @Binding var pendingDeletes: Set<DatabaseTreeTableRef>
    let coordinator: MainContentCoordinator?
    let sidebarState: SharedSidebarState

    @State private var settingsManager = AppSettingsManager.shared

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

    private var databases: [DatabaseMetadata] {
        treeService.databases(for: connectionId)
    }

    private var filteredDatabases: [DatabaseMetadata] {
        DatabaseTreeVisibility.visible(
            databases: databases,
            selected: sidebarState.databaseFilterSelected,
            activeDatabase: activeDatabase
        )
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
                VStack(spacing: 0) {
                    filterBanner
                    outline
                }
            case .idle, .loading:
                loadingState
            }
        }
        .task(id: isConnected) {
            await treeService.loadDatabases(connectionId: connectionId, databaseType: databaseType)
        }
    }

    /// A filtered list looks exactly like a short one, so it has to say it is filtered. The button
    /// that used to carry that state, at the bottom of the sidebar, is gone.
    @ViewBuilder
    private var filterBanner: some View {
        if DatabaseTreeVisibility.isFiltering(selected: sidebarState.databaseFilterSelected) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(.tint)
                Text(String(
                    format: String(localized: "Showing %lld of %lld"),
                    filteredDatabases.count,
                    databases.count
                ))
                .lineLimit(1)
                Spacer(minLength: 4)
                Button(String(localized: "Show All")) {
                    sidebarState.databaseFilterSelected = []
                }
                .buttonStyle(.link)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .accessibilityElement(children: .combine)
            Divider()
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
            searchText: viewModel.filterQuery,
            isConnected: isConnected,
            activeDatabase: activeDatabase,
            activeSchema: activeSchema,
            selectedTables: windowState.selectedTables,
            showRecentTables: settingsManager.general.showRecentTables,
            rowSizePreference: settingsManager.general.sidebarRowSize
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
