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

struct DatabaseTreeUserTypeRef: Identifiable, Equatable {
    let database: String?
    let schema: String?
    let type: UserDefinedTypeInfo

    var id: String {
        "\(database ?? "")|\(schema ?? "")|\(type.id)"
    }

    var objectRef: DatabaseObjectRef {
        DatabaseObjectRef(userType: type, database: database ?? "")
    }
}

struct DatabaseTreeView: View {
    @ObservedObject private var treeService = DatabaseTreeMetadataService.shared

    let connectionId: UUID
    let databaseType: DatabaseType
    @ObservedObject var viewModel: SidebarViewModel
    @ObservedObject var windowState: WindowSidebarState
    @Binding var pendingTruncates: Set<DatabaseTreeTableRef>
    @Binding var pendingDeletes: Set<DatabaseTreeTableRef>
    let coordinator: MainContentCoordinator?

    /// The publisher behind `activeDatabase` and `activeSchema` is the toolbar state, not the
    /// coordinator, and `@ObservedObject` cannot wrap an optional. The coordinator holds it as
    /// a stable `let`, so the view observes it directly.
    @ObservedObject var toolbarState: ConnectionToolbarState
    @ObservedObject var sidebarState: SharedSidebarState

    @ObservedObject private var settingsManager = AppSettingsManager.shared
    @State private var showsDatabaseProgress = false

    private var activeDatabase: String? {
        let name = toolbarState.currentDatabase
        return name.isEmpty ? nil : name
    }

    private var activeSchema: String? {
        toolbarState.currentSchema
    }

    private var isConnected: Bool {
        DatabaseManager.shared.session(for: connectionId)?.status == .connected
    }

    private var databases: [DatabaseMetadata] {
        treeService.databases(for: connectionId)
    }

    private var showsSystemContainers: Bool {
        settingsManager.general.showSystemContainers
    }

    private var filteredDatabases: [DatabaseMetadata] {
        DatabaseTreeVisibility.visible(
            databases: databases,
            selected: sidebarState.databaseFilterSelected,
            activeDatabase: activeDatabase,
            showsSystem: showsSystemContainers
        )
    }

    private var isFiltering: Bool {
        DatabaseTreeVisibility.isFiltering(
            selected: sidebarState.databaseFilterSelected,
            databases: databases,
            showsSystem: showsSystemContainers
        )
    }

    private var isFilterHidingEverything: Bool {
        isFiltering && filteredDatabases.isEmpty
    }

    private var isLoadingDatabases: Bool {
        switch treeService.databaseListState(for: connectionId) {
        case .idle, .loading:
            return true
        case .loaded, .failed:
            return false
        }
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
                if showsDatabaseProgress {
                    loadingState
                } else {
                    Color.clear
                }
            }
        }
        .loadingRevealGate(isActive: isLoadingDatabases, isRevealed: $showsDatabaseProgress)
        .task(id: isConnected) {
            await treeService.loadDatabases(connectionId: connectionId, databaseType: databaseType)
        }
    }

    /// A filtered list looks exactly like a short one, so it has to say it is filtered. The button
    /// that used to carry that state, at the bottom of the sidebar, is gone.
    @ViewBuilder
    private var filterBanner: some View {
        if isFiltering {
            let summary = DatabaseTreeVisibility.summary(
                databases: databases,
                selected: sidebarState.databaseFilterSelected,
                showsSystem: showsSystemContainers
            )
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(.tint)
                Text(String(
                    format: String(localized: "Showing %lld of %lld"),
                    summary.shown,
                    summary.total
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
            showSystemContainers: showsSystemContainers,
            showsPartitions: settingsManager.general.showPartitions,
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
            RevealedTextView(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyDatabasesState: some View {
        UnavailableStateView(
            String(localized: "No Databases"),
            systemImage: "cylinder",
            description: Text("This server has no databases yet.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredEmptyState: some View {
        UnavailableStateView {
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
