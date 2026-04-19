//
//  SidebarView.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import SwiftUI

// MARK: - SidebarView

/// Sidebar view with segmented tab picker for Tables and Favorites
struct SidebarView: View {
    @State private var viewModel: SidebarViewModel

    @Binding var tables: [TableInfo]
    var sidebarState: SharedSidebarState
    @Binding var pendingTruncates: Set<String>
    @Binding var pendingDeletes: Set<String>

    var onDoubleClick: ((TableInfo) -> Void)?
    var connectionId: UUID
    private weak var coordinator: MainContentCoordinator?

    private var filteredTables: [TableInfo] {
        guard !viewModel.searchText.isEmpty else { return tables }
        return tables.filter { $0.name.localizedCaseInsensitiveContains(viewModel.searchText) }
    }

    private var selectedTablesBinding: Binding<Set<TableInfo>> {
        Binding(
            get: { sidebarState.selectedTables },
            set: { sidebarState.selectedTables = $0 }
        )
    }

    init(
        tables: Binding<[TableInfo]>,
        sidebarState: SharedSidebarState,
        onDoubleClick: ((TableInfo) -> Void)? = nil,
        pendingTruncates: Binding<Set<String>>,
        pendingDeletes: Binding<Set<String>>,
        tableOperationOptions: Binding<[String: TableOperationOptions]>,
        databaseType: DatabaseType,
        connectionId: UUID,
        coordinator: MainContentCoordinator? = nil
    ) {
        _tables = tables
        self.sidebarState = sidebarState
        self.onDoubleClick = onDoubleClick
        _pendingTruncates = pendingTruncates
        _pendingDeletes = pendingDeletes
        let selectedBinding = Binding(
            get: { sidebarState.selectedTables },
            set: { sidebarState.selectedTables = $0 }
        )
        let vm = SidebarViewModel(
            tables: tables,
            selectedTables: selectedBinding,
            pendingTruncates: pendingTruncates,
            pendingDeletes: pendingDeletes,
            tableOperationOptions: tableOperationOptions,
            databaseType: databaseType,
            connectionId: connectionId
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
                tablesContent
            case .favorites:
                FavoritesTabView(
                    connectionId: connectionId,
                    searchText: viewModel.searchText,
                    coordinator: coordinator
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                NativeSearchField(
                    text: Binding(
                        get: { sidebarState.searchText },
                        set: { sidebarState.searchText = $0 }
                    ),
                    placeholder: sidebarState.selectedSidebarTab == .tables
                        ? String(localized: "Filter")
                        : String(localized: "Filter favorites")
                )
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 4)

                Picker("", selection: Binding(
                    get: { sidebarState.selectedSidebarTab },
                    set: { sidebarState.selectedSidebarTab = $0 }
                )) {
                    Text("Tables").tag(SidebarTab.tables)
                    Text("Favorites").tag(SidebarTab.favorites)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .frame(minWidth: 280)
        .onChange(of: sidebarState.searchText) { _, newValue in
            viewModel.searchText = newValue
        }
        .onAppear {
            coordinator?.sidebarViewModel = viewModel
            coordinator?.healSidebarLoadingStateIfNeeded()
            // Update toolbar version if driver connected before this window's observer was set up
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
        switch coordinator?.sidebarLoadingState ?? (tables.isEmpty ? .idle : .loaded) {
        case .loading:
            loadingState
        case .error(let message):
            errorState(message: message)
        case .loaded where tables.isEmpty:
            emptyState
        case .loaded:
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

    private var emptyState: some View {
        let entityName = PluginManager.shared.tableEntityName(for: viewModel.databaseType)
        let noItemsLabel = String(format: String(localized: "No %@"), entityName)
        let noItemsDetail = String(format: String(localized: "This database has no %@ yet."), entityName.lowercased())
        return ContentUnavailableView(
            noItemsLabel,
            systemImage: "tablecells",
            description: Text(noItemsDetail)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Table List

    private var tableList: some View {
        let entityLabel = PluginManager.shared.tableEntityName(for: viewModel.databaseType)
        let noMatchLabel = String(format: String(localized: "No matching %@"), entityLabel.lowercased())
        let helpLabel = String(format: String(localized: "Right-click to show all %@"), entityLabel.lowercased())
        let showAllLabel = String(format: String(localized: "Show All %@"), entityLabel)
        return List(selection: selectedTablesBinding) {
            if filteredTables.isEmpty {
                ContentUnavailableView(
                    noMatchLabel,
                    systemImage: "magnifyingglass"
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                Section(isExpanded: $viewModel.isTablesExpanded) {
                    ForEach(filteredTables) { table in
                        TableRow(
                            table: table,
                            isPendingTruncate: pendingTruncates.contains(table.name),
                            isPendingDelete: pendingDeletes.contains(table.name)
                        )
                        .tag(table)
                        .overlay {
                            DoubleClickDetector {
                                onDoubleClick?(table)
                            }
                        }
                        .contextMenu {
                            SidebarContextMenu(
                                clickedTable: table,
                                selectedTables: selectedTablesBinding,
                                isReadOnly: coordinator?.safeModeLevel.blocksAllWrites ?? false,
                                onBatchToggleTruncate: { viewModel.batchToggleTruncate() },
                                onBatchToggleDelete: { viewModel.batchToggleDelete() },
                                coordinator: coordinator
                            )
                        }
                    }
                } header: {
                    Text(entityLabel)
                        .help(helpLabel)
                        .contextMenu {
                            Button(showAllLabel) {
                                coordinator?.showAllTablesMetadata()
                            }
                        }
                }

                if viewModel.databaseType == .redis, let keyTreeVM = sidebarState.redisKeyTreeViewModel {
                    Section(isExpanded: $viewModel.isRedisKeysExpanded) {
                        RedisKeyTreeView(
                            nodes: keyTreeVM.displayNodes(searchText: viewModel.searchText),
                            expandedPrefixes: Binding(
                                get: { keyTreeVM.expandedPrefixes },
                                set: { keyTreeVM.expandedPrefixes = $0 }
                            ),
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
                        Text("Keys")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .contextMenu {
            SidebarContextMenu(
                clickedTable: nil,
                selectedTables: selectedTablesBinding,
                isReadOnly: coordinator?.safeModeLevel.blocksAllWrites ?? false,
                onBatchToggleTruncate: { viewModel.batchToggleTruncate() },
                onBatchToggleDelete: { viewModel.batchToggleDelete() },
                coordinator: coordinator
            )
        }
        .onExitCommand {
            sidebarState.selectedTables.removeAll()
        }
    }
}

// MARK: - Preview

#Preview {
    SidebarView(
        tables: .constant([]),
        sidebarState: SharedSidebarState(),
        pendingTruncates: .constant([]),
        pendingDeletes: .constant([]),
        tableOperationOptions: .constant([:]),
        databaseType: .mysql,
        connectionId: UUID()
    )
    .frame(width: 250, height: 400)
}
