import SwiftUI
import TableProPluginKit

struct SidebarTreeView: View {
    private var databaseManager: DatabaseManager { .shared }
    private var schemaService: SchemaService { .shared }

    let connectionId: UUID
    @ObservedObject var viewModel: SidebarViewModel
    @ObservedObject var windowState: WindowSidebarState
    @ObservedObject var sidebarState: SharedSidebarState
    @Binding var pendingTruncates: Set<DatabaseTreeTableRef>
    @Binding var pendingDeletes: Set<DatabaseTreeTableRef>
    weak var coordinator: MainContentCoordinator?
    // Also carries the all-schema listing the view model's scan reads, so a listing that lands redraws the verdicts.
    @ObservedObject var catalog: ConnectionSidebarCatalog

    @ObservedObject private var sidebarDisplay = SidebarDisplayPreferences.shared

    private var activeDatabase: String? {
        let name = coordinator?.browseDatabaseName ?? ""
        return name.isEmpty ? nil : name
    }

    private var isConnected: Bool {
        databaseManager.session(for: connectionId)?.reportedStatus == .connected
    }

    private var systemSchemas: Set<String> {
        Set(PluginManager.shared.systemSchemaNames(for: viewModel.databaseType))
    }

    private var schemas: [String] {
        DatabaseTreeVisibility.visibleSchemas(
            schemaService.schemas(for: connectionId),
            systemSchemas: systemSchemas,
            activeSchema: coordinator?.toolbarState.currentSchema,
            showsSystem: sidebarDisplay.options.showSystemContainers,
            selected: sidebarState.schemaFilter(for: activeDatabase),
            pinned: Set(pendingTruncates.union(pendingDeletes).compactMap(\.qualifyingSchema))
        )
    }

    private var searchText: String {
        viewModel.filterQuery
    }

    // The outline's own verdict, so the empty state and the rows never disagree.
    private var visibleSchemas: [String] {
        guard !searchText.isEmpty else { return schemas }
        // The listing of the database the schemas were read from, which during a switch is the one being left.
        let listingMatches = schemaService.loadedScope(for: connectionId).flatMap {
            viewModel.schemaListingMatches(database: $0.database, searchText: searchText)
        }
        return schemas.filter { schema in
            DatabaseTreeFilter.hierarchicalSchemaSearchVerdict(
                schema: schema,
                database: activeDatabase,
                searchText: searchText,
                loadedContent: DatabaseTreeFilter.hierarchicalLoadedContent(
                    in: schemaService,
                    connectionId: connectionId,
                    schema: schema,
                    searchText: searchText,
                    database: activeDatabase
                ),
                listingMatches: listingMatches,
                listingCoversSchema: !systemSchemas.contains(schema)
            ).isVisible
        }
    }

    var body: some View {
        Group {
            if schemas.isEmpty {
                emptySchemasState
            } else if !searchText.isEmpty && visibleSchemas.isEmpty {
                noMatchState
            } else {
                VStack(spacing: 0) {
                    SidebarSchemaFilterBanner(
                        connectionId: connectionId,
                        database: activeDatabase,
                        databaseType: viewModel.databaseType,
                        sidebarState: sidebarState,
                        catalog: catalog
                    )
                    treeList
                }
            }
        }
    }

    private var treeList: some View {
        DatabaseTreeOutlineView(
            connectionId: connectionId,
            databaseType: viewModel.databaseType,
            coordinator: coordinator,
            windowState: windowState,
            sidebarState: sidebarState,
            viewModel: viewModel,
            pendingTruncates: pendingTruncates,
            pendingDeletes: pendingDeletes,
            searchText: viewModel.filterQuery,
            isConnected: isConnected,
            activeDatabase: activeDatabase,
            activeSchema: coordinator?.toolbarState.currentSchema,
            selectedTables: windowState.selectedTables,
            showRecentTables: sidebarDisplay.options.showRecentTables,
            showSystemContainers: sidebarDisplay.options.showSystemContainers,
            showsPartitions: sidebarDisplay.options.showPartitions,
            rowSizePreference: sidebarDisplay.options.rowSize
        )
    }

    private var emptySchemasState: some View {
        let entityName = PluginManager.shared.schemaEntityNamePlural(for: viewModel.databaseType)
        return UnavailableStateView(
            String(format: String(localized: "No %@"), entityName),
            systemImage: "folder",
            description: Text(String(
                format: String(localized: "This connection has no %@ yet."),
                entityName.lowercased()
            ))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchState: some View {
        UnavailableStateView.search(text: searchText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
