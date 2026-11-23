import SwiftUI
import TableProPluginKit
import TableProUtilities

struct SidebarView: View {
    @ObservedObject private var featureAccess = FeatureAccess.shared
    @StateObject private var viewModel: SidebarViewModel
    @ObservedObject private var sidebarDisplay = SidebarDisplayPreferences.shared
    @State private var showsSchemaProgress = false
    @State private var showsLoadedCatalog = false

    @ObservedObject private var catalog: ConnectionSidebarCatalog

    private var databaseManager: DatabaseManager { .shared }
    private var schemaService: SchemaService { .shared }
    private var treeMetadata: DatabaseTreeMetadataService { .shared }
    private var temporaryTables: TemporaryTableStore { .shared }

    @ObservedObject var sidebarState: SharedSidebarState
    @ObservedObject var windowState: WindowSidebarState
    @Binding var pendingTruncates: Set<DatabaseTreeTableRef>
    @Binding var pendingDeletes: Set<DatabaseTreeTableRef>

    var connectionId: UUID
    private weak var coordinator: MainContentCoordinator?

    private var tables: [TableInfo] {
        schemaService.tables(for: connectionId)
    }

    private var routines: [RoutineInfo] {
        schemaService.routines(for: connectionId)
    }

    private var triggers: [TriggerInfo] {
        schemaService.triggers(for: connectionId)
    }

    private var userDefinedTypes: [UserDefinedTypeInfo] {
        schemaService.userDefinedTypes(for: connectionId)
    }

    private var hasAnyMatch: Bool {
        let declared = SidebarServerObjectKind.declared(by: DatabaseManager.shared.driver(for: connectionId))
        return SidebarObjectKind.ordered(declared: declared).contains { kind in
            countFor(kind: kind) > 0
        } || !otherSchemaMatches.isEmpty || !attachedSchemaMatches.isEmpty || hasTemporaryMatch
    }

    private var attachedSchemaMatches: [String] {
        guard rootShape == .flat, !viewModel.filterQuery.isEmpty, let database = activeDatabase,
              PluginManager.shared.listsAttachedDatabases(for: viewModel.databaseType) else { return [] }
        let searchText = viewModel.filterQuery
        return SidebarAttachedSchemas.visible(
            attached: schemaService.attachedSchemas(for: connectionId),
            database: database,
            searchText: searchText,
            loadedContent: { schema in
                DatabaseTreeFilter.loadedObjectBuckets(
                    in: treeMetadata,
                    connectionId: connectionId,
                    database: database,
                    schema: schema,
                    searchText: searchText
                )
            }
        )
    }

    private var hasTemporaryMatch: Bool {
        let search = SidebarSearch(viewModel.filterQuery)
        let database = activeDatabase
        return temporaryTables.tables(connectionId: connectionId, database: database ?? "").contains {
            search.matchesObject(named: $0.name, database: database, schema: $0.schema)
        }
    }

    // Counted too, or a search matching only another schema shows No Results and never draws the outline.
    private var otherSchemaMatches: [String] {
        guard rootShape == .flat, !viewModel.filterQuery.isEmpty, let database = activeDatabase,
              DatabaseTreeMetadataService.listsTablesPerSchema(groupingStrategy) else { return [] }
        let searchText = viewModel.filterQuery
        let systemSchemas = Set(PluginManager.shared.systemSchemaNames(for: viewModel.databaseType))
        let pending = Set(pendingTruncates.union(pendingDeletes).compactMap { ref -> String? in
            (ref.database ?? database) == database ? ref.qualifyingSchema : nil
        })
        return DatabaseTreeFilter.otherSchemaMatches(
            database: database,
            browsedSchema: coordinator?.toolbarState.currentSchema,
            searchText: searchText,
            hiddenSchemas: sidebarDisplay.options.showSystemContainers ? [] : systemSchemas,
            listingMatches: viewModel.schemaListingMatches(database: database, searchText: searchText),
            keptSchemas: SidebarSchemaFilter().keptSchemas(connectionId: connectionId, database: database)?
                .union(pending),
            loadedContent: { schema, listingMatches in
                DatabaseTreeFilter.loadedObjectBuckets(
                    in: treeMetadata,
                    connectionId: connectionId,
                    database: database,
                    schema: schema,
                    searchText: searchText,
                    listingMatches: listingMatches
                )
            }
        )
    }

    private var groupingStrategy: GroupingStrategy {
        PluginManager.shared.databaseGroupingStrategy(for: viewModel.databaseType)
    }

    // The tree shows every schema as a node, so a picker there would name a schema the list is not filtered by.
    private var supportsSchemaFooter: Bool {
        guard PluginManager.shared.supportsSchemaSwitching(for: viewModel.databaseType) else { return false }
        return rootShape == .flat
    }

    // The outline's coordinator calls the same resolver, so the wrapper and the root never describe different sidebars.
    private var rootShape: SidebarRootShape {
        SidebarRootShapeResolver.resolve(
            groupingStrategy: groupingStrategy,
            sidebarLayout: sidebarState.sidebarLayout,
            supportsDatabaseTree: PluginManager.shared.supportsDatabaseTree(for: viewModel.databaseType)
        )
    }

    init(
        sidebarState: SharedSidebarState,
        windowState: WindowSidebarState,
        pendingTruncates: Binding<Set<DatabaseTreeTableRef>>,
        pendingDeletes: Binding<Set<DatabaseTreeTableRef>>,
        tableOperationOptions: Binding<[DatabaseTreeTableRef: TableOperationOptions]>,
        databaseType: DatabaseType,
        connectionId: UUID,
        coordinator: MainContentCoordinator? = nil
    ) {
        self.sidebarState = sidebarState
        self.windowState = windowState
        _pendingTruncates = pendingTruncates
        _pendingDeletes = pendingDeletes
        let vm = SidebarViewModel.shared(
            connectionId: connectionId,
            databaseType: databaseType,
            pendingTruncates: pendingTruncates,
            pendingDeletes: pendingDeletes,
            tableOperationOptions: tableOperationOptions
        )
        // Nothing observable is written here: this runs on every evaluation of the parent's body.
        _viewModel = StateObject(wrappedValue: vm)
        self.connectionId = connectionId
        self.coordinator = coordinator
        _catalog = ObservedObject(
            wrappedValue: coordinator?.sidebarCatalog ?? ConnectionSidebarCatalog(connectionId: connectionId, toolbarState: nil)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            switch sidebarState.selectedSidebarTab {
            case .tables:
                if #available(macOS 14.0, *) {
                    FeatureTipInline(tip: OpenQuicklyTip(shortcut: FeatureTipShortcut.display(for: .quickSwitcher)))
                }
                tablesContent
            case .favorites:
                if let coordinator {
                    FavoritesTabView(
                        connectionId: connectionId,
                        databaseType: viewModel.databaseType,
                        sharedSidebarState: sidebarState,
                        coordinator: coordinator,
                        catalog: catalog
                    )
                } else {
                    Color.clear
                }
            }

            sidebarFooter
        }
        .onChange(of: sidebarDisplay.options.showRecentTables) { _ in
            sidebarState.reloadRecentTablesFromStore()
        }
        // A new session, or a database whose session is another connection, holds its own temporary tables.
        .task(id: TemporaryTableReadKey(connectionId: connectionId, database: activeDatabase, isConnected: isConnected)) {
            guard isConnected else { return }
            TemporaryTableStore.shared.refresh(connectionId: connectionId)
        }
        .onAppear {
            coordinator?.sidebarViewModel = viewModel
            // A pane put back on screen shows the list it already had.
            showsLoadedCatalog = isCatalogLoaded
        }
        .onChange(of: isCatalogLoaded) { isLoaded in
            guard isLoaded else {
                showsLoadedCatalog = false
                return
            }
            // A refresh can put the catalog back to loading before the frame, and a stale true skips the next hold.
            CommittedTurn.after(in: coordinator?.contentWindow) { showsLoadedCatalog = isCatalogLoaded }
        }
        .onChange(of: windowState.pendingTableOperation?.id) { _ in
            guard let request = windowState.pendingTableOperation else { return }
            presentOperationAlert(for: request)
        }
    }

    private func presentOperationAlert(for request: PendingTableOperation) {
        let windowState = windowState
        guard let firstTable = request.tables.first else {
            windowState.resolveTableOperation(request)
            return
        }
        let prompt = TableOperationPrompt(
            operationType: request.operation,
            tableName: firstTable.table.name,
            tableCount: request.tables.count,
            cascadeSupported: PluginManager.shared.supportsCascadeDrop(for: viewModel.databaseType),
            foreignKeyDisableSupported: PluginManager.shared.supportsForeignKeyDisable(for: viewModel.databaseType)
        )
        let model = viewModel
        TableOperationAlert.present(prompt: prompt, window: coordinator?.contentWindow) { options in
            windowState.resolveTableOperation(request)
            guard let options else { return }
            model.confirmOperation(request, options: options)
        }
    }

    // Favorites draws its own bar, because its commands belong to that view.
    @ViewBuilder
    private var sidebarFooter: some View {
        if sidebarState.selectedSidebarTab == .tables {
            let offersCreation = SidebarCreationFacts.offersAnyCreation(
                connectionId: connectionId,
                databaseType: viewModel.databaseType,
                offersBrowsedFolders: rootShape == .flat
            )
            if offersCreation || supportsSchemaFooter || featureAccess.supportAudience == .prospect {
                SidebarFooterBar {
                    if offersCreation {
                        SidebarAddButton(sections: { creationSections() }, isEnabled: isConnected)
                    }
                } trailing: {
                    if supportsSchemaFooter {
                        SchemaPickerControl(
                            connectionId: connectionId,
                            databaseType: viewModel.databaseType,
                            coordinator: coordinator,
                            catalog: catalog
                        )
                    }
                }
            }
        }
    }

    // Built when the menu opens, so the driver probes stay off the redraw path.
    private func creationSections() -> [DatabaseTreeMenuSection] {
        DatabaseTreeMenuSpec.creationSections(
            SidebarCreationFacts.resolve(
                connectionId: connectionId,
                databaseType: viewModel.databaseType,
                offersBrowsedFolders: rootShape == .flat,
                activeDatabase: activeDatabase
            ),
            hidesDatabaseWrites: false
        )
    }

    @ViewBuilder
    private var tablesContent: some View {
        switch rootShape {
        case .hierarchicalSchema: hierarchicalContent
        case .databaseTree: databaseTreeContent
        case .flat: flatContent
        }
    }

    @ViewBuilder
    private var databaseTreeContent: some View {
        if let coordinator {
            DatabaseTreeView(
                connectionId: connectionId,
                databaseType: viewModel.databaseType,
                viewModel: viewModel,
                windowState: windowState,
                pendingTruncates: $pendingTruncates,
                pendingDeletes: $pendingDeletes,
                coordinator: coordinator,
                toolbarState: coordinator.toolbarState,
                sidebarState: sidebarState,
                catalog: catalog
            )
        }
    }

    @ViewBuilder
    private var hierarchicalContent: some View {
        let presentation = SidebarObjectListPresentation.resolveDeferringEmptyStates(
            state: presentedSchemaState,
            hasOutlastedGrace: showsSchemaProgress
        )
        Group {
            switch presentation {
            case .preparing:
                Color.clear
            case .failed(let message):
                errorState(message: message)
            case .loading:
                loadingState
            case .noDatabaseSelected:
                noDatabaseSelectedState
            case .noMatch, .list:
                SidebarTreeView(
                    connectionId: connectionId,
                    viewModel: viewModel,
                    windowState: windowState,
                    sidebarState: sidebarState,
                    pendingTruncates: $pendingTruncates,
                    pendingDeletes: $pendingDeletes,
                    coordinator: coordinator,
                    catalog: catalog
                )
            }
        }
        .loadingRevealGate(
            isActive: presentation == .preparing || presentation == .loading,
            isRevealed: $showsSchemaProgress
        )
    }

    private var isCatalogLoaded: Bool {
        if case .loaded = schemaService.state(for: connectionId) { return true }
        return false
    }

    // A connection's first catalog can land in the turn that commits the restored tab's frame, and building the
    // outline there made one stall of both. The outline goes up in a later turn, the loading state held till then.
    private var presentedSchemaState: SchemaState {
        SidebarObjectListPresentation.presentedState(schemaService.state(for: connectionId), showsLoaded: showsLoadedCatalog)
    }

    private var objectListPresentation: SidebarObjectListPresentation {
        SidebarObjectListPresentation.resolve(
            state: presentedSchemaState,
            hasActiveFilter: !viewModel.filterQuery.isEmpty,
            hasAnyMatch: hasAnyMatch,
            hasOutlastedGrace: showsSchemaProgress,
            needsDatabaseSelection: needsDatabaseSelection,
            awaitsSearchListing: awaitsSearchListing
        )
    }

    private var awaitsSearchListing: Bool {
        guard rootShape == .flat, !viewModel.filterQuery.isEmpty, let database = activeDatabase,
              DatabaseTreeMetadataService.listsTablesPerSchema(groupingStrategy) else { return false }
        switch treeMetadata.allSchemaTablesLoadState(connectionId: connectionId, database: database) {
        case .loading: return true
        // A search asks for it at once, but never while disconnected.
        case .idle: return databaseManager.session(for: connectionId)?.reportedStatus.isConnected == true
        case .loaded, .failed: return false
        }
    }

    private var needsDatabaseSelection: Bool {
        viewModel.databaseType.browsingRequiresSelectedDatabase && activeDatabase == nil
    }

    // Resolved above the switch, so the pure, tested resolver decides every branch.
    @ViewBuilder
    private var flatContent: some View {
        let presentation = objectListPresentation
        Group {
            switch presentation {
            case .preparing:
                Color.clear
            case .loading:
                loadingState
            case .failed(let message):
                errorState(message: message)
            case .noDatabaseSelected:
                noDatabaseSelectedState
            case .noMatch:
                noMatchState
            case .list:
                tableList
            }
        }
        .loadingRevealGate(
            isActive: presentation == .preparing || presentation == .loading,
            isRevealed: $showsSchemaProgress
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
            Button("Retry") {
                Task { await schemaService.refresh(connectionId: connectionId) }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var noDatabaseSelectedState: some View {
        UnavailableStateView {
            Label(String(localized: "No Database Selected"), systemImage: "cylinder")
        } description: {
            Text("Open a database to browse its tables.")
        } actions: {
            Button(String(localized: "Open Database…")) {
                coordinator?.commandActions?.openDatabaseSwitcher()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchState: some View {
        UnavailableStateView.search(text: viewModel.searchText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var activeDatabase: String? {
        let name = coordinator?.browseDatabaseName ?? ""
        return name.isEmpty ? nil : name
    }

    private var isConnected: Bool {
        databaseManager.session(for: connectionId)?.reportedStatus == .connected
    }

    private var tableList: some View {
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

    private func countFor(kind: SidebarObjectKind) -> Int {
        switch kind.category {
        case .table:   return viewModel.filteredTables(of: kind, from: tables).count
        case .routine: return viewModel.filteredRoutines(of: kind, from: routines).count
        case .trigger: return viewModel.filteredTriggers(from: triggers).count
        case .type:    return viewModel.filteredUserTypes(from: userDefinedTypes).count
        case .server:
            guard let serverKind = kind.serverKind else { return 0 }
            return viewModel.filteredServerObjects(
                kindId: serverKind.id,
                from: schemaService.serverObjects(for: connectionId, kindId: serverKind.id)
            ).count
        }
    }
}

private struct TemporaryTableReadKey: Hashable {
    let connectionId: UUID
    let database: String?
    let isConnected: Bool
}

#Preview {
    SidebarView(
        sidebarState: SharedSidebarState(),
        windowState: WindowSidebarState(),
        pendingTruncates: .constant([]),
        pendingDeletes: .constant([]),
        tableOperationOptions: .constant([:]),
        databaseType: .mysql,
        connectionId: UUID()
    )
    .frame(width: 250, height: 400)
}
