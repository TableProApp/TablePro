import SwiftUI
import TableProPluginKit

struct SidebarTreeView: View {
    @Bindable private var schemaService = SchemaService.shared

    let connectionId: UUID
    let viewModel: SidebarViewModel
    let windowState: WindowSidebarState
    @Binding var pendingTruncates: Set<String>
    @Binding var pendingDeletes: Set<String>
    var onDoubleClick: ((TableInfo) -> Void)?
    weak var coordinator: MainContentCoordinator?

    @State private var searchLoadTask: Task<Void, Never>?

    private var systemSchemas: Set<String> {
        Set(PluginManager.shared.systemSchemaNames(for: viewModel.databaseType))
    }

    private var schemas: [String] {
        schemaService.schemas(for: connectionId).filter { !systemSchemas.contains($0) }
    }

    private var searchText: String {
        viewModel.searchText
    }

    private var visibleSchemas: [String] {
        guard !searchText.isEmpty else { return schemas }
        return schemas.filter { schemaIsVisibleDuringSearch($0) }
    }

    private var selectedTablesBinding: Binding<Set<TableInfo>> {
        Binding(
            get: { windowState.selectedTables },
            set: { windowState.selectedTables = $0 }
        )
    }

    var body: some View {
        Group {
            if schemas.isEmpty {
                emptyDatasetsState
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

    private var treeList: some View {
        List(selection: selectedTablesBinding) {
            ForEach(visibleSchemas, id: \.self) { schema in
                Section(isExpanded: expansionBinding(for: schema)) {
                    datasetContent(for: schema)
                } header: {
                    datasetHeader(schema)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: TableInfo.self) { _ in
            EmptyView()
        } primaryAction: { selection in
            guard let table = selection.first else { return }
            onDoubleClick?(table)
        }
        .onExitCommand {
            windowState.selectedTables.removeAll()
        }
    }

    @ViewBuilder
    private func datasetContent(for schema: String) -> some View {
        switch schemaService.schemaState(for: connectionId, schema: schema) {
        case .idle, .loading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "Loading tables\u{2026}"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.vertical, 4)
        case .loaded:
            let tables = tablesToShow(for: schema)
            if tables.isEmpty {
                Text(String(localized: "No tables"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(tables) { table in
                    tableRow(table)
                }
            }
        }
    }

    private func tableRow(_ table: TableInfo) -> some View {
        TableRow(
            table: table,
            isPendingTruncate: pendingTruncates.contains(table.name),
            isPendingDelete: pendingDeletes.contains(table.name)
        )
        .tag(table)
        .contextMenu {
            SidebarContextMenu(
                clickedTable: table,
                selectedTables: windowState.selectedTables,
                isReadOnly: coordinator?.safeModeLevel.blocksAllWrites ?? false,
                onBatchToggleTruncate: { viewModel.batchToggleTruncate(tableNames: $0) },
                onBatchToggleDelete: { viewModel.batchToggleDelete(tableNames: $0) },
                coordinator: coordinator
            )
        }
    }

    private func datasetHeader(_ schema: String) -> some View {
        Text(schema)
            .contextMenu {
                Button(String(localized: "Refresh")) {
                    reloadTables(for: schema)
                }
            }
    }

    private var emptyDatasetsState: some View {
        ContentUnavailableView(
            String(localized: "No Datasets"),
            systemImage: "tablecells",
            description: Text(String(localized: "This project has no datasets yet."))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchState: some View {
        ContentUnavailableView.search(text: searchText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func expansionBinding(for schema: String) -> Binding<Bool> {
        Binding(
            get: { !searchText.isEmpty || windowState.expandedTreeSchemas.contains(schema) },
            set: { isExpanded in
                if isExpanded {
                    windowState.expandedTreeSchemas.insert(schema)
                    loadTables(for: schema)
                } else {
                    windowState.expandedTreeSchemas.remove(schema)
                }
            }
        )
    }

    private func tablesToShow(for schema: String) -> [TableInfo] {
        let tables = schemaService.tables(for: connectionId, schema: schema)
        guard !searchText.isEmpty, !FuzzyMatcher.matches(query: searchText, candidate: schema) else {
            return tables
        }
        return tables.filter { FuzzyMatcher.matches(query: searchText, candidate: $0.name) }
    }

    private func schemaIsVisibleDuringSearch(_ schema: String) -> Bool {
        if FuzzyMatcher.matches(query: searchText, candidate: schema) { return true }
        switch schemaService.schemaState(for: connectionId, schema: schema) {
        case .loaded:
            return !tablesToShow(for: schema).isEmpty
        case .idle, .loading, .failed:
            return true
        }
    }

    private func loadTables(for schema: String) {
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return }
        Task {
            await schemaService.loadSchemaTables(connectionId: connectionId, schema: schema, driver: driver)
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
                loadTables(for: schema)
            }
        }
    }

    private func reloadTables(for schema: String) {
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return }
        Task {
            await schemaService.reloadSchemaTables(connectionId: connectionId, schema: schema, driver: driver)
        }
    }
}
