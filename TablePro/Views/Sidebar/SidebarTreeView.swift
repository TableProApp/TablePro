import SwiftUI
import TableProPluginKit

struct SidebarTreeView: View {
    @Bindable private var schemaService = SchemaService.shared

    let connectionId: UUID
    let viewModel: SidebarViewModel
    let windowState: WindowSidebarState
    var sidebarState: SharedSidebarState
    @Binding var pendingTruncates: Set<DatabaseTreeTableRef>
    @Binding var pendingDeletes: Set<DatabaseTreeTableRef>
    weak var coordinator: MainContentCoordinator?

    @State private var settingsManager = AppSettingsManager.shared
    @State private var searchLoadTask: Task<Void, Never>?

    private var activeDatabase: String? {
        let name = coordinator?.browseDatabaseName ?? ""
        return name.isEmpty ? nil : name
    }

    private var isConnected: Bool {
        DatabaseManager.shared.session(for: connectionId)?.status == .connected
    }

    private var systemSchemas: Set<String> {
        Set(PluginManager.shared.systemSchemaNames(for: viewModel.databaseType))
    }

    private var schemas: [String] {
        schemaService.schemas(for: connectionId).filter { !systemSchemas.contains($0) }
    }

    private var searchText: String {
        viewModel.filterQuery
    }

    private var visibleSchemas: [String] {
        guard !searchText.isEmpty else { return schemas }
        return schemas.filter { schemaIsVisibleDuringSearch($0) }
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
        .onChange(of: searchText) { _, newValue in
            scheduleSearchLoad(searchText: newValue)
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
            rowSizePreference: settingsManager.general.sidebarRowSize
        )
    }

    private var emptySchemasState: some View {
        let entityName = PluginManager.shared.schemaEntityNamePlural(for: viewModel.databaseType)
        return ContentUnavailableView(
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
        ContentUnavailableView.search(text: searchText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The same rule the outline applies, so the empty state and the rows can never disagree about
    /// whether a schema survived the filter.
    private func schemaIsVisibleDuringSearch(_ schema: String) -> Bool {
        DatabaseTreeFilter.hierarchicalSchemaIsVisible(
            schema,
            searchText: searchText,
            isLoaded: schemaService.isSchemaSettled(for: connectionId, schema: schema),
            tables: schemaService.tables(for: connectionId, schema: schema),
            routines: schemaService.routines(for: connectionId, schema: schema),
            triggers: schemaService.triggers(for: connectionId, schema: schema),
            userTypes: schemaService.userDefinedTypes(for: connectionId, schema: schema)
        )
    }

    private func loadObjects(for schema: String) {
        let database = activeDatabase
        Task {
            await schemaService.loadSchemaObjects(connectionId: connectionId, schema: schema, database: database)
        }
    }

    private func scheduleSearchLoad(searchText: String) {
        searchLoadTask?.cancel()
        guard !searchText.isEmpty else { return }
        let schemasSnapshot = schemas
        searchLoadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            for schema in schemasSnapshot {
                if case .loaded = schemaService.schemaState(for: connectionId, schema: schema) {
                    continue
                }
                loadObjects(for: schema)
            }
        }
    }
}
