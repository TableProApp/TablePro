//
//  DatabaseTreeView.swift
//  TablePro
//

import os
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

struct DatabaseTreeSchemaRef: Identifiable {
    let database: String
    let schema: String

    var id: String {
        "\(database)|\(schema)"
    }
}

struct DatabaseTreeView: View {
    @Bindable private var treeService = DatabaseTreeMetadataService.shared

    private static let logger = Logger(subsystem: "com.TablePro", category: "SidebarTreeView")

    let connectionId: UUID
    let databaseType: DatabaseType
    let viewModel: SidebarViewModel
    let windowState: WindowSidebarState
    @Binding var pendingTruncates: Set<String>
    @Binding var pendingDeletes: Set<String>
    let coordinator: MainContentCoordinator?

    @State private var localSelection: Set<DatabaseTreeTableRef> = []

    private var groupingStrategy: GroupingStrategy {
        PluginManager.shared.databaseGroupingStrategy(for: databaseType)
    }

    private var supportsSchemaLevel: Bool {
        groupingStrategy == .bySchema
    }

    private var activeDatabase: String? {
        let name = coordinator?.toolbarState.currentDatabase ?? ""
        return name.isEmpty ? nil : name
    }

    private var activeSchema: String? {
        coordinator?.toolbarState.currentSchema
    }

    private var committedActiveDatabase: String? {
        guard let session = DatabaseManager.shared.session(for: connectionId) else { return nil }
        let value = session.activeDatabase
        return value.isEmpty ? nil : value
    }

    private var committedActiveSchema: String? {
        DatabaseManager.shared.session(for: connectionId)?.currentSchema
    }

    private var schemaGenerationToken: Int {
        SchemaService.shared.generationToken(for: connectionId)
    }

    @MainActor
    private func activate(_ ref: DatabaseTreeTableRef?) async {
        guard let ref else { return }
        if ref.database != committedActiveDatabase {
            await coordinator?.switchDatabase(to: ref.database)
        }
        if let schema = ref.schema,
           schema != coordinator?.toolbarState.currentSchema,
           PluginManager.shared.supportsSchemaSwitching(for: databaseType) {
            await coordinator?.switchSchema(to: schema)
        }
    }

    private var systemSchemas: Set<String> {
        Set(PluginManager.shared.systemSchemaNames(for: databaseType))
    }

    private var databases: [DatabaseMetadata] {
        treeService.databases(for: connectionId)
    }

    private var searchText: String {
        viewModel.searchText
    }

    private var selectedTablesBinding: Binding<Set<DatabaseTreeTableRef>> {
        Binding(
            get: { localSelection },
            set: { localSelection = $0 }
        )
    }

    var body: some View {
        Group {
            let state = treeService.databaseListState(for: connectionId)
            if case .failed(let message) = state {
                errorState(message: message)
            } else if databases.isEmpty {
                if case .loaded = state {
                    emptyDatabasesState
                } else {
                    loadingState
                }
            } else {
                treeList
            }
        }
        .onAppear {
            Self.logger.debug(
                "onAppear connId=\(connectionId, privacy: .public) active=\(committedActiveDatabase ?? "nil", privacy: .public) toolbar=\(activeDatabase ?? "nil", privacy: .public)"
            )
            loadDatabasesIfNeeded()
            expandActive()
            reconcileLoads(retryFailed: false)
        }
        .onChange(of: activeContextKey) { old, new in
            Self.logger.debug("trigger activeContextKey '\(old, privacy: .public)' -> '\(new, privacy: .public)'")
            expandActive()
        }
        .onChange(of: reconcileKey) { old, new in
            Self.logger.debug("trigger reconcileKey '\(old, privacy: .public)' -> '\(new, privacy: .public)'")
            reconcileLoads(retryFailed: true)
        }
        .onChange(of: schemaGenerationToken) { old, new in
            Self.logger.debug("trigger schemaGeneration \(old, privacy: .public) -> \(new, privacy: .public)")
            reconcileLoads(retryFailed: false)
        }
        .onChange(of: localSelection) { oldRefs, newRefs in
            guard let ref = SelectionDelta.singleAddition(old: oldRefs, new: newRefs) else { return }
            Self.logger.debug(
                "selection-navigate db=\(ref.database, privacy: .public) schema=\(ref.schema ?? "nil", privacy: .public) table=\(ref.table.name, privacy: .public)"
            )
            openTable(ref.table, in: ref.database, schema: ref.schema)
        }
    }

    private var activeContextKey: String {
        "\(activeDatabase ?? "")|\(activeSchema ?? "")"
    }

    private var reconcileKey: String {
        "\(committedActiveDatabase ?? "")|\(committedActiveSchema ?? "")|\(connectionStatusToken)"
    }

    private var connectionStatusToken: String {
        switch DatabaseManager.shared.session(for: connectionId)?.status {
        case .connected: return "connected"
        case .connecting: return "connecting"
        case .error: return "error"
        case .disconnected, .none: return "disconnected"
        }
    }

    private var treeList: some View {
        List(selection: selectedTablesBinding) {
            ForEach(visibleDatabases, id: \.id) { db in
                DisclosureGroup(isExpanded: databaseExpansionBinding(for: db.name)) {
                    databaseBody(db)
                } label: {
                    databaseHeader(db)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: DatabaseTreeTableRef.self) { selection in
            SidebarContextMenu(
                clickedTable: selection.first?.table,
                selectedTables: Set(selection.map(\.table)),
                isReadOnly: coordinator?.safeModeLevel.blocksAllWrites ?? false,
                onBatchToggleTruncate: { viewModel.batchToggleTruncate(tableNames: $0) },
                onBatchToggleDelete: { viewModel.batchToggleDelete(tableNames: $0) },
                coordinator: coordinator,
                activateBeforeAction: { await activate(selection.first) }
            )
        } primaryAction: { selection in
            guard let ref = selection.first else { return }
            openTable(ref.table, in: ref.database, schema: ref.schema)
        }
        .onExitCommand {
            localSelection.removeAll()
        }
    }

    @ViewBuilder
    private func databaseBody(_ db: DatabaseMetadata) -> some View {
        if supportsSchemaLevel {
            schemasContent(for: db.name)
        } else {
            tablesContent(database: db.name, schema: nil)
        }
    }

    private func databaseHeader(_ db: DatabaseMetadata) -> some View {
        let isActive = db.name == activeDatabase
        return Label {
            Text(db.name)
                .fontWeight(isActive ? .bold : .regular)
                .foregroundStyle(rowForeground(isActive: isActive, isSystem: db.isSystemDatabase))
        } icon: {
            Image(systemName: db.isSystemDatabase ? "gearshape" : "cylinder")
                .foregroundStyle(db.isSystemDatabase ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }
        .contextMenu {
            Button(String(localized: "Use as Active Database")) {
                setActiveDatabase(db.name)
            }
            .disabled(isActive)
            Button(String(localized: "Refresh")) {
                refreshDatabase(db.name)
            }
        }
    }

    private func schemaHeader(database: String, schema: String) -> some View {
        let isActive = (database == activeDatabase) && (schema == activeSchema)
        let isSystem = systemSchemas.contains(schema)
        return Label {
            Text(schema)
                .fontWeight(isActive ? .bold : .regular)
                .foregroundStyle(rowForeground(isActive: isActive, isSystem: isSystem))
        } icon: {
            Image(systemName: "folder")
                .foregroundStyle(.tint)
        }
        .contextMenu {
            Button(String(localized: "Use as Active Schema")) {
                setActiveSchema(database: database, schema: schema)
            }
            .disabled(isActive)
            Button(String(localized: "Refresh")) {
                refreshSchema(database: database, schema: schema)
            }
        }
    }

    private func rowForeground(isActive: Bool, isSystem: Bool) -> AnyShapeStyle {
        if isActive { return AnyShapeStyle(.tint) }
        if isSystem { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(.primary)
    }

    @ViewBuilder
    private func schemasContent(for database: String) -> some View {
        let state = treeService.schemaListState(connectionId: connectionId, database: database)
        switch state {
        case .idle, .loading:
            loadingRow(String(localized: "Loading schemas\u{2026}"))
                .task(id: database) {
                    Self.logger.debug("task->loadSchemaList db=\(database, privacy: .public)")
                    await treeService.loadSchemaList(connectionId: connectionId, database: database)
                }
        case .failed(let message):
            errorRow(message)
        case .loaded(let schemas):
            let visible = visibleSchemas(database: database, all: schemas)
            if visible.isEmpty {
                emptyRow(String(localized: "No schemas"))
            } else {
                ForEach(visible.map { DatabaseTreeSchemaRef(database: database, schema: $0) }) { ref in
                    DisclosureGroup(
                        isExpanded: schemaExpansionBinding(database: ref.database, schema: ref.schema)
                    ) {
                        tablesContent(database: ref.database, schema: ref.schema)
                    } label: {
                        schemaHeader(database: ref.database, schema: ref.schema)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tablesContent(database: String, schema: String?) -> some View {
        switch treeService.tableState(
            connectionId: connectionId, database: database, schema: schema
        ) {
        case .idle, .loading:
            loadingRow(String(localized: "Loading tables\u{2026}"))
                .task(id: "\(database)|\(schema ?? "")") {
                    Self.logger.debug(
                        "task->loadTables db=\(database, privacy: .public) schema=\(schema ?? "nil", privacy: .public)"
                    )
                    await treeService.loadTables(
                        connectionId: connectionId, database: database, schema: schema
                    )
                }
        case .failed(let message):
            errorRow(message)
        case .loaded:
            let tables = filteredTables(database: database, schema: schema)
            let routines = filteredRoutines(database: database, schema: schema)
            if tables.isEmpty && routines.isEmpty {
                emptyRow(String(localized: "No items"))
            } else {
                ForEach(tables.map { DatabaseTreeTableRef(database: database, schema: schema, table: $0) }) { ref in
                    TableRow(
                        table: ref.table,
                        isPendingTruncate: pendingTruncates.contains(ref.table.name),
                        isPendingDelete: pendingDeletes.contains(ref.table.name)
                    )
                    .tag(ref)
                }
                ForEach(routines.map { DatabaseTreeRoutineRef(database: database, schema: schema, routine: $0) }) { ref in
                    RoutineRowView(routine: ref.routine)
                        .contextMenu {
                            RoutineContextMenu(routine: ref.routine) { selected in
                                coordinator?.showRoutineDDL(selected)
                            }
                        }
                }
            }
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

    private var emptyDatabasesState: some View {
        ContentUnavailableView(
            String(localized: "No Databases"),
            systemImage: "cylinder",
            description: Text("This server has no databases yet.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func errorRow(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func tables(database: String, schema: String?) -> [TableInfo] {
        treeService.tables(connectionId: connectionId, database: database, schema: schema)
    }

    private func routines(database: String, schema: String?) -> [RoutineInfo] {
        treeService.routines(connectionId: connectionId, database: database, schema: schema)
    }

    private var visibleDatabases: [DatabaseMetadata] {
        let nonSystem = databases.filter { !$0.isSystemDatabase }
        let matched = searchText.isEmpty ? nonSystem : nonSystem.filter { databaseMatchesSearch($0) }
        var seen = Set<String>()
        return matched.filter { seen.insert($0.id).inserted }
    }

    private func databaseMatchesSearch(_ db: DatabaseMetadata) -> Bool {
        if db.name.localizedCaseInsensitiveContains(searchText) { return true }
        let schemas = treeService.schemaListState(connectionId: connectionId, database: db.name)
        if case .loaded(let list) = schemas {
            if list.contains(where: { $0.localizedCaseInsensitiveContains(searchText) }) { return true }
            for schema in list where schemaContentMatchesSearch(database: db.name, schema: schema) {
                return true
            }
        }
        if schemaContentMatchesSearch(database: db.name, schema: nil) { return true }
        return false
    }

    private func schemaContentMatchesSearch(database: String, schema: String?) -> Bool {
        if let schema, schema.localizedCaseInsensitiveContains(searchText) { return true }
        let tableMatches = tables(database: database, schema: schema)
            .contains { $0.name.localizedCaseInsensitiveContains(searchText) }
        if tableMatches { return true }
        let routineMatches = routines(database: database, schema: schema)
            .contains { $0.name.localizedCaseInsensitiveContains(searchText) }
        return routineMatches
    }

    private func visibleSchemas(database: String, all: [String]) -> [String] {
        let nonSystem = all.filter { !systemSchemas.contains($0) }
        let matched = searchText.isEmpty
            ? nonSystem
            : nonSystem.filter { schema in
                schema.localizedCaseInsensitiveContains(searchText)
                    || schemaContentMatchesSearch(database: database, schema: schema)
            }
        var seen = Set<String>()
        return matched.filter { seen.insert($0).inserted }
    }

    private func filteredTables(database: String, schema: String?) -> [TableInfo] {
        let all = tables(database: database, schema: schema)
        let matched = searchText.isEmpty
            ? all
            : all.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        var seen = Set<String>()
        return matched.filter { seen.insert($0.id).inserted }
    }

    private func filteredRoutines(database: String, schema: String?) -> [RoutineInfo] {
        let all = routines(database: database, schema: schema)
        let matched = searchText.isEmpty
            ? all
            : all.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        var seen = Set<String>()
        return matched.filter { seen.insert($0.id).inserted }
    }

    private func databaseExpansionBinding(for database: String) -> Binding<Bool> {
        Binding(
            get: { !searchText.isEmpty || windowState.expandedTreeDatabases.contains(database) },
            set: { isExpanded in
                Self.logger.debug("expand-database db=\(database, privacy: .public) expanded=\(isExpanded, privacy: .public)")
                if isExpanded {
                    windowState.expandedTreeDatabases.insert(database)
                    loadDatabaseContentIfNeeded(database)
                } else {
                    windowState.expandedTreeDatabases.remove(database)
                }
            }
        )
    }

    private func schemaExpansionBinding(database: String, schema: String) -> Binding<Bool> {
        let key = DatabaseSchemaKey(database: database, schema: schema)
        return Binding(
            get: { !searchText.isEmpty || windowState.expandedTreeDatabaseSchemas.contains(key) },
            set: { isExpanded in
                Self.logger.debug(
                    "expand-schema db=\(database, privacy: .public) schema=\(schema, privacy: .public) expanded=\(isExpanded, privacy: .public)"
                )
                if isExpanded {
                    windowState.expandedTreeDatabaseSchemas.insert(key)
                    loadTablesIfNeeded(database: database, schema: schema)
                } else {
                    windowState.expandedTreeDatabaseSchemas.remove(key)
                }
            }
        )
    }

    private func loadDatabasesIfNeeded() {
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
            Self.logger.debug("loadDatabasesIfNeeded skip-no-driver connId=\(connectionId, privacy: .public)")
            return
        }
        Task {
            await treeService.loadDatabaseList(
                connectionId: connectionId,
                driver: driver,
                databaseType: databaseType
            )
        }
    }

    private func reconcileLoads(retryFailed: Bool) {
        guard case .loaded = treeService.databaseListState(for: connectionId) else {
            Self.logger.debug("reconcile skip (db list not loaded) retryFailed=\(retryFailed, privacy: .public)")
            return
        }
        let expandedSchemaCount = windowState.expandedTreeDatabaseSchemas.count
        Self.logger.debug(
            "reconcile begin retryFailed=\(retryFailed, privacy: .public) active=\(committedActiveDatabase ?? "nil", privacy: .public) activeSchema=\(committedActiveSchema ?? "nil", privacy: .public) expandedDbs=\(windowState.expandedTreeDatabases.count, privacy: .public) expandedSchemas=\(expandedSchemaCount, privacy: .public)"
        )

        if let active = committedActiveDatabase {
            ensureContentLoaded(
                database: active,
                schema: supportsSchemaLevel ? committedActiveSchema : nil,
                retryFailed: retryFailed
            )
        }

        for database in windowState.expandedTreeDatabases {
            guard !supportsSchemaLevel else {
                ensureSchemaListLoaded(database: database, retryFailed: retryFailed)
                let expandedSchemas = windowState.expandedTreeDatabaseSchemas
                    .filter { $0.database == database }
                for key in expandedSchemas {
                    ensureContentLoaded(database: database, schema: key.schema, retryFailed: retryFailed)
                }
                continue
            }
            ensureContentLoaded(database: database, schema: nil, retryFailed: retryFailed)
        }
    }

    private func ensureSchemaListLoaded(database: String, retryFailed: Bool) {
        let state = treeService.schemaListState(connectionId: connectionId, database: database)
        switch state {
        case .idle:
            Self.logger.debug("reconcile kick schemaList db=\(database, privacy: .public) reason=idle")
            loadDatabaseContentIfNeeded(database)
        case .failed where retryFailed:
            Self.logger.debug("reconcile kick schemaList db=\(database, privacy: .public) reason=retryFailed")
            loadDatabaseContentIfNeeded(database)
        case .loading, .loaded, .failed:
            return
        }
    }

    private func ensureContentLoaded(database: String, schema: String?, retryFailed: Bool) {
        let state = treeService.tableState(connectionId: connectionId, database: database, schema: schema)
        switch state {
        case .idle:
            Self.logger.debug(
                "reconcile kick tables db=\(database, privacy: .public) schema=\(schema ?? "nil", privacy: .public) reason=idle"
            )
            loadTablesIfNeeded(database: database, schema: schema)
        case .failed where retryFailed:
            Self.logger.debug(
                "reconcile kick tables db=\(database, privacy: .public) schema=\(schema ?? "nil", privacy: .public) reason=retryFailed"
            )
            loadTablesIfNeeded(database: database, schema: schema)
        case .loading, .loaded, .failed:
            return
        }
    }

    private func loadDatabaseContentIfNeeded(_ database: String) {
        if supportsSchemaLevel {
            Task { await treeService.loadSchemaList(connectionId: connectionId, database: database) }
        } else {
            loadTablesIfNeeded(database: database, schema: nil)
        }
    }

    private func loadTablesIfNeeded(database: String, schema: String?) {
        Task {
            await treeService.loadTables(connectionId: connectionId, database: database, schema: schema)
        }
    }

    private func refreshDatabase(_ database: String) {
        Task {
            await treeService.refreshDatabase(connectionId: connectionId, database: database)
            loadDatabaseContentIfNeeded(database)
        }
    }

    private func refreshSchema(database: String, schema: String) {
        Task {
            await treeService.reloadTables(
                connectionId: connectionId, database: database, schema: schema
            )
        }
    }

    private func expandActive() {
        guard let active = activeDatabase else { return }
        windowState.expandedTreeDatabases.insert(active)
        if let schema = activeSchema {
            windowState.expandedTreeDatabaseSchemas.insert(
                DatabaseSchemaKey(database: active, schema: schema)
            )
        }
    }

    private func setActiveDatabase(_ database: String) {
        guard database != activeDatabase else { return }
        Self.logger.debug("setActiveDatabase db=\(database, privacy: .public)")
        Task { @MainActor in
            await coordinator?.switchDatabase(to: database)
            Self.logger.debug(
                "setActiveDatabase done db=\(database, privacy: .public) committed=\(committedActiveDatabase ?? "nil", privacy: .public)"
            )
        }
    }

    private func setActiveSchema(database: String, schema: String) {
        Self.logger.debug(
            "setActiveSchema db=\(database, privacy: .public) schema=\(schema, privacy: .public)"
        )
        Task { @MainActor in
            if database != activeDatabase {
                await coordinator?.switchDatabase(to: database)
            }
            if schema != coordinator?.toolbarState.currentSchema {
                await coordinator?.switchSchema(to: schema)
            }
        }
    }

    private func openTable(_ table: TableInfo, in database: String, schema: String?) {
        Task { @MainActor in
            Self.logger.debug(
                "openTable begin table=\(table.name, privacy: .public) db=\(database, privacy: .public) schema=\(schema ?? "nil", privacy: .public) committed=\(committedActiveDatabase ?? "nil", privacy: .public)"
            )
            if database != committedActiveDatabase {
                Self.logger.debug("openTable switchDatabase -> \(database, privacy: .public)")
                await coordinator?.switchDatabase(to: database)
            }
            if let schema,
               schema != coordinator?.toolbarState.currentSchema,
               PluginManager.shared.supportsSchemaSwitching(for: databaseType) {
                Self.logger.debug("openTable switchSchema -> \(schema, privacy: .public)")
                await coordinator?.switchSchema(to: schema)
            }
            Self.logger.debug(
                "openTable openTableTab table=\(table.name, privacy: .public) committed=\(committedActiveDatabase ?? "nil", privacy: .public) currentSchema=\(coordinator?.toolbarState.currentSchema ?? "nil", privacy: .public)"
            )
            coordinator?.openTableTab(table)
        }
    }
}
