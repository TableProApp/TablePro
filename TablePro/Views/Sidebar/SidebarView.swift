//
//  SidebarView.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import SwiftUI
import TableProPluginKit

struct SidebarView: View {
    @State private var viewModel: SidebarViewModel
    @State private var favoriteTables: Set<FavoriteTablesStorage.FavoriteEntry> = []
    @State private var showDatabaseFilter: Bool = false

    private var schemaService: SchemaService { SchemaService.shared }

    var sidebarState: SharedSidebarState
    var windowState: WindowSidebarState
    @Binding var pendingTruncates: Set<String>
    @Binding var pendingDeletes: Set<String>

    var onDoubleClick: ((TableInfo) -> Void)?
    var connectionId: UUID
    private weak var coordinator: MainContentCoordinator?

    private var tables: [TableInfo] {
        schemaService.tables(for: connectionId)
    }

    private var routines: [RoutineInfo] {
        schemaService.routines(for: connectionId)
    }

    private var pluginCapabilities: PluginCapabilities {
        viewModel.capabilities(for: connectionId)
    }

    private var hasAnyMatch: Bool {
        SidebarObjectKind.allCases.contains { kind in
            countFor(kind: kind) > 0
        }
    }

    private var groupingStrategy: GroupingStrategy {
        PluginManager.shared.databaseGroupingStrategy(for: viewModel.databaseType)
    }

    private var supportsSchemaFooter: Bool {
        guard PluginManager.shared.supportsSchemaSwitching(for: viewModel.databaseType) else { return false }
        return groupingStrategy != .hierarchicalSchema && !usesDatabaseTree
    }

    private var selectedTablesBinding: Binding<Set<TableInfo>> {
        Binding(
            get: { windowState.selectedTables },
            set: { windowState.selectedTables = $0 }
        )
    }

    init(
        sidebarState: SharedSidebarState,
        windowState: WindowSidebarState,
        onDoubleClick: ((TableInfo) -> Void)? = nil,
        pendingTruncates: Binding<Set<String>>,
        pendingDeletes: Binding<Set<String>>,
        tableOperationOptions: Binding<[String: TableOperationOptions]>,
        databaseType: DatabaseType,
        connectionId: UUID,
        coordinator: MainContentCoordinator? = nil
    ) {
        self.sidebarState = sidebarState
        self.windowState = windowState
        self.onDoubleClick = onDoubleClick
        _pendingTruncates = pendingTruncates
        _pendingDeletes = pendingDeletes
        let selectedBinding = Binding(
            get: { windowState.selectedTables },
            set: { windowState.selectedTables = $0 }
        )
        let vm = SidebarViewModel.shared(
            connectionId: connectionId,
            databaseType: databaseType,
            selectedTables: selectedBinding,
            pendingTruncates: pendingTruncates,
            pendingDeletes: pendingDeletes,
            tableOperationOptions: tableOperationOptions
        )
        vm.searchText = sidebarState.searchText
        if databaseType == .redis, let existingVM = sidebarState.redisKeyTreeViewModel {
            vm.redisKeyTreeViewModel = existingVM
        }
        _viewModel = State(wrappedValue: vm)
        self.connectionId = connectionId
        self.coordinator = coordinator
    }

    // MARK: - Body

    var body: some View {
        Group {
            switch sidebarState.selectedSidebarTab {
            case .tables:
                VStack(spacing: 0) {
                    tablesContent
                    tablesBottomBar
                }
            case .favorites:
                if let coordinator {
                    FavoritesTabView(
                        connectionId: connectionId,
                        sharedSidebarState: sidebarState,
                        tables: tables,
                        coordinator: coordinator
                    )
                } else {
                    Color.clear
                }
            }
        }
        .onChange(of: sidebarState.searchText) { _, newValue in
            viewModel.searchText = newValue
        }
        .onAppear {
            coordinator?.sidebarViewModel = viewModel
            if let driver = DatabaseManager.shared.driver(for: connectionId),
               coordinator?.toolbarState.databaseVersion == nil {
                coordinator?.toolbarState.databaseVersion = driver.serverVersion
            }
        }
        .sheet(isPresented: $viewModel.showOperationDialog) {
            if let operationType = viewModel.pendingOperationType {
                let dialogTables = viewModel.pendingOperationTables
                if let firstTable = dialogTables.first {
                    TableOperationDialog(
                        isPresented: $viewModel.showOperationDialog,
                        tableName: firstTable,
                        tableCount: dialogTables.count,
                        operationType: operationType,
                        databaseType: viewModel.databaseType
                    ) { options in
                        viewModel.confirmOperation(options: options)
                    }
                }
            }
        }
    }

    // MARK: - Tables Content

    @ViewBuilder
    private var tablesContent: some View {
        if groupingStrategy == .hierarchicalSchema {
            hierarchicalContent
        } else if usesDatabaseTree {
            databaseTreeContent
        } else {
            flatContent
        }
    }

    // MARK: - Bottom Bar

    private var tablesBottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                createObjectMenu
                if usesDatabaseTree {
                    databaseFilterButton
                }
                Spacer()
                if supportsSchemaFooter {
                    SchemaPickerControl(
                        connectionId: connectionId,
                        databaseType: viewModel.databaseType,
                        coordinator: coordinator
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var isDatabaseFilterActive: Bool {
        !sidebarState.databaseFilterSelected.isEmpty
    }

    private var databaseFilterSelectionBinding: Binding<Set<String>> {
        Binding(
            get: { sidebarState.databaseFilterSelected },
            set: { sidebarState.databaseFilterSelected = $0 }
        )
    }

    private var databaseFilterButton: some View {
        Button {
            showDatabaseFilter = true
        } label: {
            Image(systemName: isDatabaseFilterActive
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
                .foregroundStyle(isDatabaseFilterActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.borderless)
        .help(String(localized: "Filter databases"))
        .accessibilityIdentifier("sidebar-database-filter")
        .popover(isPresented: $showDatabaseFilter) {
            DatabaseTreeFilterPopover(
                connectionId: connectionId,
                selectedDatabases: databaseFilterSelectionBinding
            )
        }
    }

    private var createObjectMenu: some View {
        Menu {
            Button(String(localized: "New Table")) { coordinator?.createNewTable() }
            Button(String(localized: "New View")) { coordinator?.createView() }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Create a new table or view"))
        .disabled(coordinator?.safeModeLevel.blocksAllWrites ?? true)
        .accessibilityIdentifier("sidebar-create-table")
    }

    private var usesDatabaseTree: Bool {
        PluginManager.shared.supportsDatabaseTree(for: viewModel.databaseType)
            && sidebarState.sidebarLayout == .tree
    }

    @ViewBuilder
    private var databaseTreeContent: some View {
        DatabaseTreeView(
            connectionId: connectionId,
            databaseType: viewModel.databaseType,
            viewModel: viewModel,
            windowState: windowState,
            pendingTruncates: $pendingTruncates,
            pendingDeletes: $pendingDeletes,
            coordinator: coordinator,
            sidebarState: sidebarState
        )
    }

    @ViewBuilder
    private var hierarchicalContent: some View {
        switch schemaService.state(for: connectionId) {
        case .idle, .loading:
            loadingState
        case .failed(let message):
            errorState(message: message)
        case .loaded:
            SidebarTreeView(
                connectionId: connectionId,
                viewModel: viewModel,
                windowState: windowState,
                pendingTruncates: $pendingTruncates,
                pendingDeletes: $pendingDeletes,
                onDoubleClick: onDoubleClick,
                coordinator: coordinator
            )
        }
    }

    @ViewBuilder
    private var flatContent: some View {
        switch schemaService.state(for: connectionId) {
        case .loading where tables.isEmpty:
            loadingState
        case .failed(let message):
            errorState(message: message)
        case .loaded where !viewModel.filterQuery.isEmpty && !hasAnyMatch:
            noMatchState
        case .loaded(let allTables) where allTables.isEmpty && routines.isEmpty:
            emptyState
        case .loaded, .loading:
            tableList
        case .idle:
            emptyState
        }
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

    private var noMatchState: some View {
        ContentUnavailableView.search(text: viewModel.searchText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        let entityName = PluginManager.shared.tableEntityName(for: viewModel.databaseType)
        let containerName = PluginManager.shared.containerEntityName(for: viewModel.databaseType)
        let noItemsLabel = String(format: String(localized: "No %@"), entityName)
        let noItemsDetail = String(
            format: String(localized: "This %1$@ has no %2$@ yet."),
            containerName.lowercased(),
            entityName.lowercased()
        )
        return ContentUnavailableView(
            noItemsLabel,
            systemImage: "tablecells",
            description: Text(noItemsDetail)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Table List

    private var activeDatabase: String? {
        let name = coordinator?.activeDatabaseName ?? ""
        return name.isEmpty ? nil : name
    }

    private func isFavorite(_ table: TableInfo) -> Bool {
        favoriteTables.contains(FavoriteTablesStorage.FavoriteEntry(
            connectionId: connectionId,
            database: activeDatabase,
            schema: table.schema,
            name: table.name
        ))
    }

    private func toggleFavorite(_ table: TableInfo) {
        FavoriteTablesStorage.shared.toggle(
            name: table.name,
            schema: table.schema,
            database: activeDatabase,
            connectionId: connectionId
        )
    }

    private var tableList: some View {
        List(selection: selectedTablesBinding) {
            ForEach(SidebarObjectKind.allCases, id: \.self) { kind in
                sectionView(for: kind)
            }

            if viewModel.databaseType == .redis, let keyTreeVM = sidebarState.redisKeyTreeViewModel {
                Section(isExpanded: $viewModel.isRedisKeysExpanded) {
                    RedisKeyTreeView(
                        nodes: keyTreeVM.displayNodes(searchText: viewModel.filterQuery),
                        isLoading: keyTreeVM.isLoading,
                        isTruncated: keyTreeVM.isTruncated,
                        onSelectNamespace: { prefix in
                            coordinator?.browseRedisNamespace(prefix)
                        },
                        onSelectKey: { key, keyType in
                            coordinator?.openRedisKey(key, keyType: keyType)
                        }
                    )
                } header: {
                    Text(String(localized: "Keys"))
                }
            }
        }
        .sidebarListLayout()
        .contextMenu(forSelectionType: TableInfo.self) { selection in
            SidebarContextMenu(
                clickedTable: selection.first,
                selectedTables: selection,
                isReadOnly: coordinator?.safeModeLevel.blocksAllWrites ?? false,
                onBatchToggleTruncate: { viewModel.batchToggleTruncate(tableNames: $0) },
                onBatchToggleDelete: { viewModel.batchToggleDelete(tableNames: $0) },
                coordinator: coordinator
            )
        } primaryAction: { selection in
            guard let table = selection.first else { return }
            onDoubleClick?(table)
        }
        .onExitCommand {
            windowState.selectedTables.removeAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .favoriteTablesDidChange)) { _ in
            favoriteTables = FavoriteTablesStorage.shared.favorites(for: connectionId)
        }
        .onAppear {
            favoriteTables = FavoriteTablesStorage.shared.favorites(for: connectionId)
        }
    }

    // MARK: - Section View

    @ViewBuilder
    private func sectionView(for kind: SidebarObjectKind) -> some View {
        let count = countFor(kind: kind)
        if viewModel.sectionShouldRender(kind: kind, itemCount: count, capabilities: pluginCapabilities) {
            let isExpanded = sectionExpandedBinding(kind: kind, hasMatches: count > 0)
            Section(isExpanded: isExpanded) {
                sectionRows(for: kind)
            } header: {
                sectionHeader(for: kind)
            }
        }
    }

    private func sectionExpandedBinding(kind: SidebarObjectKind, hasMatches: Bool) -> Binding<Bool> {
        Binding(
            get: { viewModel.effectiveExpanded(kind: kind, hasMatches: hasMatches) },
            set: { viewModel.expanded[kind] = $0 }
        )
    }

    @ViewBuilder
    private func sectionRows(for kind: SidebarObjectKind) -> some View {
        if kind.isRoutine {
            ForEach(viewModel.filteredRoutines(of: kind, from: routines)) { routine in
                RoutineRowView(routine: routine)
                    .tag(routine)
                    .contextMenu {
                        RoutineContextMenu(routine: routine) { selected in
                            coordinator?.showRoutineDDL(selected)
                        }
                    }
            }
        } else {
            ForEach(viewModel.filteredTables(of: kind, from: tables)) { table in
                TableRow(
                    table: table,
                    isPendingTruncate: pendingTruncates.contains(table.name),
                    isPendingDelete: pendingDeletes.contains(table.name),
                    isFavorite: isFavorite(table),
                    onToggleFavorite: { toggleFavorite(table) }
                )
                .tag(table)
            }
        }
    }

    private func sectionHeader(for kind: SidebarObjectKind) -> some View {
        let title = sectionTitle(for: kind)
        let helpLabel = String(
            format: String(localized: "Right-click to show all %@"),
            title.lowercased()
        )
        return Text(title)
            .help(helpLabel)
            .contextMenu {
                sectionHeaderMenu(for: kind, title: title)
            }
    }

    @ViewBuilder
    private func sectionHeaderMenu(for kind: SidebarObjectKind, title: String) -> some View {
        if !kind.isRoutine {
            Button(String(format: String(localized: "Show All %@"), title)) {
                if kind == .table {
                    coordinator?.showAllTablesMetadata()
                }
            }
            .disabled(kind != .table)
        }
        Button(String(localized: "Refresh")) {
            switch kind {
            case .procedure:
                Task { await coordinator?.refreshProcedures() }
            case .function:
                Task { await coordinator?.refreshFunctions() }
            default:
                Task { await coordinator?.refreshTables() }
            }
        }
    }

    private func sectionTitle(for kind: SidebarObjectKind) -> String {
        if kind == .table {
            return PluginManager.shared.tableEntityName(for: viewModel.databaseType)
        }
        return kind.pluralDisplayName
    }

    private func countFor(kind: SidebarObjectKind) -> Int {
        if kind.isRoutine {
            return viewModel.filteredRoutines(of: kind, from: routines).count
        }
        return viewModel.filteredTables(of: kind, from: tables).count
    }
}

// MARK: - Preview

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
