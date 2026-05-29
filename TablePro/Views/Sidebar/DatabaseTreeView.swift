//
//  DatabaseTreeView.swift
//  TablePro
//

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

struct DatabaseTreeView: View {
    @Bindable private var treeService = DatabaseTreeMetadataService.shared

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
            loadDatabasesIfNeeded()
            expandActive()
        }
        .onChange(of: activeDatabase ?? "") { _, _ in
            expandActive()
        }
        .onChange(of: activeSchema ?? "") { _, _ in
            expandActive()
        }
        .onChange(of: localSelection) { oldRefs, newRefs in
            guard let ref = SelectionDelta.singleAddition(old: oldRefs, new: newRefs) else { return }
            openTable(ref.table, in: ref.database, schema: ref.schema)
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
                    await treeService.loadSchemaList(connectionId: connectionId, database: database)
                }
        case .failed(let message):
            errorRow(message)
        case .loaded(let schemas):
            let visible = visibleSchemas(database: database, all: schemas)
            if visible.isEmpty {
                emptyRow(String(localized: "No schemas"))
            } else {
                ForEach(visible, id: \.self) { schema in
                    DisclosureGroup(
                        isExpanded: schemaExpansionBinding(database: database, schema: schema)
                    ) {
                        tablesContent(database: database, schema: schema)
                    } label: {
                        schemaHeader(database: database, schema: schema)
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
                ForEach(tables) { table in
                    TableRow(
                        table: table,
                        isPendingTruncate: pendingTruncates.contains(table.name),
                        isPendingDelete: pendingDeletes.contains(table.name)
                    )
                    .tag(DatabaseTreeTableRef(database: database, schema: schema, table: table))
                }
                ForEach(routines) { routine in
                    RoutineRowView(routine: routine)
                        .tag(routine)
                        .contextMenu {
                            RoutineContextMenu(routine: routine) { selected in
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
        guard !searchText.isEmpty else { return nonSystem }
        return nonSystem.filter { databaseMatchesSearch($0) }
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
        let filtered = all.filter { !systemSchemas.contains($0) }
        guard !searchText.isEmpty else { return filtered }
        return filtered.filter { schema in
            schema.localizedCaseInsensitiveContains(searchText)
                || schemaContentMatchesSearch(database: database, schema: schema)
        }
    }

    private func filteredTables(database: String, schema: String?) -> [TableInfo] {
        let all = tables(database: database, schema: schema)
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private func filteredRoutines(database: String, schema: String?) -> [RoutineInfo] {
        let all = routines(database: database, schema: schema)
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private func databaseExpansionBinding(for database: String) -> Binding<Bool> {
        Binding(
            get: { !searchText.isEmpty || windowState.expandedTreeDatabases.contains(database) },
            set: { isExpanded in
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
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return }
        Task {
            await treeService.loadDatabaseList(
                connectionId: connectionId,
                driver: driver,
                databaseType: databaseType
            )
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
        Task { @MainActor in
            await coordinator?.switchDatabase(to: database)
        }
    }

    private func setActiveSchema(database: String, schema: String) {
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
            if database != committedActiveDatabase {
                await coordinator?.switchDatabase(to: database)
            }
            if let schema,
               schema != coordinator?.toolbarState.currentSchema,
               PluginManager.shared.supportsSchemaSwitching(for: databaseType) {
                await coordinator?.switchSchema(to: schema)
            }
            coordinator?.openTableTab(table)
        }
    }
}
