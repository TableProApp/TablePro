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
    @State private var settingsManager = AppSettingsManager.shared

    private var schemaService: SchemaService { SchemaService.shared }

    var sidebarState: SharedSidebarState
    var windowState: WindowSidebarState
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

    private var hasAnyMatch: Bool {
        SidebarObjectKind.allCases.contains { kind in
            countFor(kind: kind) > 0
        }
    }

    private var groupingStrategy: GroupingStrategy {
        PluginManager.shared.databaseGroupingStrategy(for: viewModel.databaseType)
    }

    /// Only the flat list is scoped to one schema. The tree already shows every schema as a node,
    /// so a picker there would name a schema the list is not filtered by.
    private var supportsSchemaFooter: Bool {
        guard PluginManager.shared.supportsSchemaSwitching(for: viewModel.databaseType) else { return false }
        return rootShape == .flat
    }

    /// The one derivation of the sidebar's shape. The outline's coordinator calls the same resolver
    /// with the same inputs, so the wrapper this view picks and the root the outline builds can
    /// never describe different sidebars.
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
        let selectedBinding = Binding(
            get: { windowState.selectedTables },
            set: { windowState.selectTables($0) }
        )
        let vm = SidebarViewModel.shared(
            connectionId: connectionId,
            databaseType: databaseType,
            selectedTables: selectedBinding,
            pendingTruncates: pendingTruncates,
            pendingDeletes: pendingDeletes,
            tableOperationOptions: tableOperationOptions
        )
        /// Nothing observable is written here. This initializer runs on every evaluation of the
        /// parent's body, and the view model already seeds its own filter and watches the field.
        _viewModel = State(wrappedValue: vm)
        self.connectionId = connectionId
        self.coordinator = coordinator
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            switch sidebarState.selectedSidebarTab {
            case .tables:
                tablesContent
            case .favorites:
                if let coordinator {
                    FavoritesTabView(
                        connectionId: connectionId,
                        databaseType: viewModel.databaseType,
                        sharedSidebarState: sidebarState,
                        tables: tables,
                        coordinator: coordinator
                    )
                } else {
                    Color.clear
                }
            }

            sidebarFooter
        }
        .onChange(of: settingsManager.general.showRecentTables) { _, _ in
            sidebarState.reloadRecentTablesFromStore()
        }
        .onAppear {
            coordinator?.sidebarViewModel = viewModel
            if let driver = DatabaseManager.shared.driver(for: connectionId),
               coordinator?.toolbarState.databaseVersion == nil {
                coordinator?.toolbarState.databaseVersion = driver.serverVersion
            }
        }
        .onChange(of: viewModel.showOperationDialog) { _, isPresented in
            guard isPresented else { return }
            presentOperationAlert()
        }
    }

    private func presentOperationAlert() {
        guard let operationType = viewModel.pendingOperationType,
              let firstTable = viewModel.pendingOperationTables.first
        else {
            viewModel.showOperationDialog = false
            return
        }
        let prompt = TableOperationPrompt(
            operationType: operationType,
            tableName: firstTable.table.name,
            tableCount: viewModel.pendingOperationTables.count,
            cascadeSupported: PluginManager.shared.supportsCascadeDrop(for: viewModel.databaseType),
            foreignKeyDisableSupported: PluginManager.shared.supportsForeignKeyDisable(for: viewModel.databaseType)
        )
        let model = viewModel
        TableOperationAlert.present(prompt: prompt, window: coordinator?.contentWindow) { options in
            model.showOperationDialog = false
            guard let options else {
                model.cancelPendingOperation()
                return
            }
            model.confirmOperation(options: options)
        }
    }

    // MARK: - Footer

    /// The schema picker belongs to the flat table list alone, and the support link belongs to
    /// anyone without a license, so the bar draws when either has something to put in it.
    private var showsSchemaPicker: Bool {
        supportsSchemaFooter && sidebarState.selectedSidebarTab == .tables
    }

    @ViewBuilder
    private var sidebarFooter: some View {
        if showsSchemaPicker || LicenseManager.shared.supportAudience == .prospect {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 8) {
                    SupportPromptLink()
                        .font(.caption)
                    Spacer()
                    if showsSchemaPicker {
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
    }

    // MARK: - Tables Content

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
                sidebarState: sidebarState,
                pendingTruncates: $pendingTruncates,
                pendingDeletes: $pendingDeletes,
                coordinator: coordinator
            )
        }
    }

    @ViewBuilder
    private var flatContent: some View {
        switch SidebarObjectListPresentation.resolve(
            state: schemaService.state(for: connectionId),
            hasActiveFilter: !viewModel.filterQuery.isEmpty,
            hasAnyMatch: hasAnyMatch,
            hasRoutines: !routines.isEmpty,
            hasTriggers: !triggers.isEmpty
        ) {
        case .loading:
            loadingState
        case .failed(let message):
            errorState(message: message)
        case .noMatch:
            noMatchState
        case .empty:
            emptyState
        case .list:
            tableList
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
            Button("Retry") {
                Task { await schemaService.refresh(connectionId: connectionId) }
            }
            .controlSize(.small)
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
        let name = coordinator?.browseDatabaseName ?? ""
        return name.isEmpty ? nil : name
    }

    private var isConnected: Bool {
        DatabaseManager.shared.session(for: connectionId)?.status == .connected
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
            showRecentTables: settingsManager.general.showRecentTables,
            rowSizePreference: settingsManager.general.sidebarRowSize
        )
    }

    private func countFor(kind: SidebarObjectKind) -> Int {
        switch kind.category {
        case .table:   return viewModel.filteredTables(of: kind, from: tables).count
        case .routine: return viewModel.filteredRoutines(of: kind, from: routines).count
        case .trigger: return viewModel.filteredTriggers(from: triggers).count
        }
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
