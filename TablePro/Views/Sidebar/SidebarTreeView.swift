import SwiftUI
import TableProPluginKit

struct SidebarTreeView: View {
    @ObservedObject private var databaseManager = DatabaseManager.shared
    @ObservedObject private var schemaService = SchemaService.shared
    @ObservedObject private var treeMetadata = DatabaseTreeMetadataService.shared

    let connectionId: UUID
    @ObservedObject var viewModel: SidebarViewModel
    @ObservedObject var windowState: WindowSidebarState
    @ObservedObject var sidebarState: SharedSidebarState
    @Binding var pendingTruncates: Set<DatabaseTreeTableRef>
    @Binding var pendingDeletes: Set<DatabaseTreeTableRef>
    weak var coordinator: MainContentCoordinator?

    @ObservedObject private var settingsManager = AppSettingsManager.shared

    private var activeDatabase: String? {
        let name = coordinator?.browseDatabaseName ?? ""
        return name.isEmpty ? nil : name
    }

    private var isConnected: Bool {
        databaseManager.session(for: connectionId)?.status == .connected
    }

    private var systemSchemas: Set<String> {
        Set(PluginManager.shared.systemSchemaNames(for: viewModel.databaseType))
    }

    private var schemas: [String] {
        DatabaseTreeVisibility.visibleSchemas(
            schemaService.schemas(for: connectionId),
            systemSchemas: systemSchemas,
            activeSchema: coordinator?.toolbarState.currentSchema,
            showsSystem: settingsManager.general.showSystemContainers
        )
    }

    private var searchText: String {
        viewModel.filterQuery
    }

    /// The same verdict the outline applies, so the empty state and the rows can never disagree about
    /// whether a schema survived the filter.
    private var visibleSchemas: [String] {
        guard !searchText.isEmpty else { return schemas }
        let listingMatches = DatabaseTreeFilter.hierarchicalListingMatches(
            in: treeMetadata,
            schemaService: schemaService,
            connectionId: connectionId,
            searchText: searchText
        )
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
                treeList
            }
        }
    }

    /// Same outline the other two sidebar shapes use. See `SidebarView.tableList` for why a SwiftUI
    /// `List` cannot serve here.
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
            showRecentTables: settingsManager.general.showRecentTables,
            showSystemContainers: settingsManager.general.showSystemContainers,
            showsPartitions: settingsManager.general.showPartitions,
            rowSizePreference: settingsManager.general.sidebarRowSize
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
