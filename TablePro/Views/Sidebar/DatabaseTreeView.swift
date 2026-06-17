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

private enum SchemaTreeRow: Identifiable {
    case loading
    case empty
    case error(String)
    case schema(DatabaseTreeSchemaRef)

    var id: String {
        switch self {
        case .loading: return "status.loading"
        case .empty: return "status.empty"
        case .error: return "status.error"
        case .schema(let ref): return "schema.\(ref.id)"
        }
    }
}

private enum ObjectTreeRow: Identifiable {
    case loading
    case empty
    case error(String)
    case table(DatabaseTreeTableRef)
    case routine(DatabaseTreeRoutineRef)

    var id: String {
        switch self {
        case .loading: return "status.loading"
        case .empty: return "status.empty"
        case .error: return "status.error"
        case .table(let ref): return "table.\(ref.id)"
        case .routine(let ref): return "routine.\(ref.id)"
        }
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
    let sidebarState: SharedSidebarState

    @State private var localSelection: Set<DatabaseTreeTableRef> = []
    @State private var searchText: String = ""

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

    private var isConnected: Bool {
        DatabaseManager.shared.session(for: connectionId)?.status == .connected
    }

    private var connectionToken: String {
        isConnected ? "connected" : "down"
    }

    private var systemSchemas: Set<String> {
        Set(PluginManager.shared.systemSchemaNames(for: databaseType))
    }

    private var databases: [DatabaseMetadata] {
        treeService.databases(for: connectionId)
    }

    private var selectedTablesBinding: Binding<Set<DatabaseTreeTableRef>> {
        Binding(
            get: { localSelection },
            set: { localSelection = $0 }
        )
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
                treeList
            case .idle, .loading:
                loadingState
            }
        }
        .task(id: connectionToken) {
            await treeService.loadDatabases(connectionId: connectionId, databaseType: databaseType)
        }
        .task(id: viewModel.searchText) {
            let live = viewModel.searchText
            guard !live.isEmpty else { searchText = ""; return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            searchText = live
        }
        .onAppear { expandActive() }
        .onChange(of: activeContextKey) { _, _ in expandActive() }
        .onChange(of: localSelection) { oldRefs, newRefs in
            guard let ref = SelectionDelta.singleAddition(old: oldRefs, new: newRefs) else { return }
            openTable(ref.table, in: ref.database, schema: ref.schema)
        }
    }

    private var activeContextKey: String {
        "\(activeDatabase ?? "")|\(activeSchema ?? "")"
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
            openTable(ref.table, in: ref.database, schema: ref.schema, activateGridFocus: true)
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
            objectsContent(database: db.name, schema: nil)
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
        .accessibilityLabel(String(format: String(localized: "Database: %@"), db.name))
        .accessibilityAddTraits(.isHeader)
        .contextMenu {
            Button(String(localized: "Use as Active Database")) {
                setActiveDatabase(db.name)
            }
            .disabled(isActive)
            Button(String(localized: "Refresh")) {
                Task { await treeService.refreshSchemas(connectionId: connectionId, database: db.name) }
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
        .accessibilityLabel(String(format: String(localized: "Schema: %@"), schema))
        .accessibilityAddTraits(.isHeader)
        .contextMenu {
            Button(String(localized: "Use as Active Schema")) {
                setActiveSchema(database: database, schema: schema)
            }
            .disabled(isActive)
            Button(String(localized: "Refresh")) {
                Task {
                    await treeService.refreshObjects(connectionId: connectionId, database: database, schema: schema)
                }
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
        Group {
            ForEach(schemaRows(for: database)) { row in
                schemaRow(row, database: database)
            }
        }
        .task(id: "\(database)|\(connectionToken)") {
            await treeService.loadSchemas(connectionId: connectionId, database: database)
        }
    }

    private func schemaRows(for database: String) -> [SchemaTreeRow] {
        switch treeService.schemaListState(connectionId: connectionId, database: database) {
        case .idle, .loading:
            return [.loading]
        case .failed(let message):
            return [.error(message)]
        case .loaded(let schemas):
            let visible = visibleSchemas(database: database, all: schemas)
            guard !visible.isEmpty else { return [.empty] }
            return visible.map { .schema(DatabaseTreeSchemaRef(database: database, schema: $0)) }
        }
    }

    @ViewBuilder
    private func schemaRow(_ row: SchemaTreeRow, database: String) -> some View {
        switch row {
        case .loading:
            loadingRow(String(localized: "Loading schemas\u{2026}"))
        case .empty:
            emptyRow(String(localized: "No schemas"))
        case .error(let message):
            errorRow(message)
        case .schema(let ref):
            DisclosureGroup(isExpanded: schemaExpansionBinding(database: ref.database, schema: ref.schema)) {
                objectsContent(database: ref.database, schema: ref.schema)
            } label: {
                schemaHeader(database: ref.database, schema: ref.schema)
            }
        }
    }

    @ViewBuilder
    private func objectsContent(database: String, schema: String?) -> some View {
        Group {
            ForEach(objectRows(database: database, schema: schema)) { row in
                objectRow(row, database: database, schema: schema)
            }
        }
        .task(id: "tables|\(database)|\(schema ?? "")|\(connectionToken)") {
            await treeService.loadTables(connectionId: connectionId, database: database, schema: schema)
        }
        .task(id: "routines|\(database)|\(schema ?? "")|\(connectionToken)") {
            await treeService.loadRoutines(connectionId: connectionId, database: database, schema: schema)
        }
    }

    private func objectRows(database: String, schema: String?) -> [ObjectTreeRow] {
        switch treeService.tablesLoadState(connectionId: connectionId, database: database, schema: schema) {
        case .idle, .loading:
            return [.loading]
        case .failed(let message):
            return [.error(message)]
        case .loaded:
            let tables = filteredTables(database: database, schema: schema)
            let routines = filteredRoutines(database: database, schema: schema)
            let routinesState = treeService.routinesLoadState(
                connectionId: connectionId, database: database, schema: schema
            )
            guard !tables.isEmpty || !routines.isEmpty else {
                switch routinesState {
                case .failed(let message): return [.error(message)]
                case .loaded: return [.empty]
                case .idle, .loading: return [.loading]
                }
            }
            var rows: [ObjectTreeRow] = tables.map {
                .table(DatabaseTreeTableRef(database: database, schema: schema, table: $0))
            }
            rows += routines.map {
                .routine(DatabaseTreeRoutineRef(database: database, schema: schema, routine: $0))
            }
            if case .failed(let message) = routinesState {
                rows.append(.error(message))
            }
            return rows
        }
    }

    @ViewBuilder
    private func objectRow(_ row: ObjectTreeRow, database: String, schema: String?) -> some View {
        switch row {
        case .loading:
            loadingRow(String(localized: "Loading\u{2026}"))
        case .empty:
            emptyRow(String(localized: "No items"))
        case .error(let message):
            errorRow(message)
        case .table(let ref):
            TableRow(
                table: ref.table,
                isPendingTruncate: pendingTruncates.contains(ref.table.name),
                isPendingDelete: pendingDeletes.contains(ref.table.name)
            )
            .tag(ref)
        case .routine(let ref):
            RoutineRowView(routine: ref.routine)
                .contextMenu {
                    RoutineContextMenu(routine: ref.routine) { selected in
                        coordinator?.showRoutineDDL(selected)
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

    private var isFilterHidingEverything: Bool {
        DatabaseTreeVisibility.isFiltering(selected: sidebarState.databaseFilterSelected)
            && filteredDatabases.isEmpty
    }

    private var filteredEmptyState: some View {
        ContentUnavailableView {
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

    // MARK: - Selection actions

    @MainActor
    private func activate(_ ref: DatabaseTreeTableRef?) async {
        guard let ref else { return }
        if ref.database != activeDatabase {
            await coordinator?.switchDatabase(to: ref.database)
        }
        if let schema = ref.schema,
           schema != coordinator?.toolbarState.currentSchema,
           PluginManager.shared.supportsSchemaSwitching(for: databaseType) {
            await coordinator?.switchSchema(to: schema)
        }
    }

    private func setActiveDatabase(_ database: String) {
        guard database != activeDatabase else { return }
        Task { await coordinator?.switchDatabase(to: database) }
    }

    private func setActiveSchema(database: String, schema: String) {
        Task {
            if database != activeDatabase {
                await coordinator?.switchDatabase(to: database)
            }
            if schema != coordinator?.toolbarState.currentSchema {
                await coordinator?.switchSchema(to: schema)
            }
        }
    }

    private func openTable(_ table: TableInfo, in database: String, schema: String?, activateGridFocus: Bool = false) {
        Task { @MainActor in
            if database != activeDatabase {
                await coordinator?.switchDatabase(to: database)
            }
            if let schema,
               schema != coordinator?.toolbarState.currentSchema,
               PluginManager.shared.supportsSchemaSwitching(for: databaseType) {
                await coordinator?.switchSchema(to: schema)
            }
            coordinator?.openTableTab(table, activateGridFocus: activateGridFocus)
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

    // MARK: - Expansion

    private func databaseExpansionBinding(for database: String) -> Binding<Bool> {
        Binding(
            get: { !searchText.isEmpty || windowState.expandedTreeDatabases.contains(database) },
            set: { isExpanded in
                if isExpanded {
                    windowState.expandedTreeDatabases.insert(database)
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
                } else {
                    windowState.expandedTreeDatabaseSchemas.remove(key)
                }
            }
        )
    }

    // MARK: - Search filtering

    private func tables(database: String, schema: String?) -> [TableInfo] {
        treeService.tables(connectionId: connectionId, database: database, schema: schema)
    }

    private func routines(database: String, schema: String?) -> [RoutineInfo] {
        treeService.routines(connectionId: connectionId, database: database, schema: schema)
    }

    private var filteredDatabases: [DatabaseMetadata] {
        DatabaseTreeVisibility.visible(databases: databases, selected: sidebarState.databaseFilterSelected)
    }

    private var visibleDatabases: [DatabaseMetadata] {
        let matched = searchText.isEmpty ? filteredDatabases : filteredDatabases.filter { databaseMatchesSearch($0) }
        var seen = Set<String>()
        return matched.filter { seen.insert($0.id).inserted }
    }

    private func databaseMatchesSearch(_ db: DatabaseMetadata) -> Bool {
        if FuzzyMatcher.matches(query: searchText, candidate: db.name) { return true }
        if case .loaded(let list) = treeService.schemaListState(connectionId: connectionId, database: db.name) {
            if list.contains(where: { FuzzyMatcher.matches(query: searchText, candidate: $0) }) { return true }
            for schema in list where schemaContentMatchesSearch(database: db.name, schema: schema) {
                return true
            }
        }
        return schemaContentMatchesSearch(database: db.name, schema: nil)
    }

    private func schemaContentMatchesSearch(database: String, schema: String?) -> Bool {
        if let schema, FuzzyMatcher.matches(query: searchText, candidate: schema) { return true }
        if tables(database: database, schema: schema).contains(where: { FuzzyMatcher.matches(query: searchText, candidate: $0.name) }) {
            return true
        }
        return routines(database: database, schema: schema).contains { FuzzyMatcher.matches(query: searchText, candidate: $0.name) }
    }

    private func visibleSchemas(database: String, all: [String]) -> [String] {
        let nonSystem = all.filter { !systemSchemas.contains($0) }
        let matched = searchText.isEmpty
            ? nonSystem
            : nonSystem.filter { schema in
                FuzzyMatcher.matches(query: searchText, candidate: schema)
                    || schemaContentMatchesSearch(database: database, schema: schema)
            }
        var seen = Set<String>()
        return matched.filter { seen.insert($0).inserted }
    }

    private func filteredTables(database: String, schema: String?) -> [TableInfo] {
        let all = tables(database: database, schema: schema)
        let matched = searchText.isEmpty
            ? all
            : all.filter { FuzzyMatcher.matches(query: searchText, candidate: $0.name) }
        var seen = Set<String>()
        return matched.filter { seen.insert($0.id).inserted }
    }

    private func filteredRoutines(database: String, schema: String?) -> [RoutineInfo] {
        let all = routines(database: database, schema: schema)
        let matched = searchText.isEmpty
            ? all
            : all.filter { FuzzyMatcher.matches(query: searchText, candidate: $0.name) }
        var seen = Set<String>()
        return matched.filter { seen.insert($0.id).inserted }
    }
}
