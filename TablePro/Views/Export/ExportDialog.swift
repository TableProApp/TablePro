//
//  ExportDialog.swift
//  TablePro
//
//  Main export dialog for exporting tables using format plugins.
//  Features a split layout with table selection tree on the left and format options on the right.
//

import AppKit
import SwiftUI
import TableProPluginKit
import UniformTypeIdentifiers

/// Main export dialog view
struct ExportDialog: View {
    @Binding var isPresented: Bool
    let mode: ExportMode
    var sidebarTables: [TableInfo] = []

    // MARK: - State

    @State private var config = ExportConfiguration()
    @State private var databaseItems: [ExportDatabaseItem] = []
    @State private var isLoading = true
    @State private var isExporting = false
    @State private var showProgressDialog = false
    @State private var showSuccessDialog = false
    @State private var exportedFileURL: URL?
    @State private var settingsSnapshot: PluginSettingsSnapshot?
    @State private var exportSucceeded = false

    // MARK: - User Preferences

    @AppStorage("hideExportSuccessDialog", store: AppStorageEnvironment.shared.defaults) private var hideSuccessDialog = false

    // MARK: - Export Service

    @State private var exportService: ExportService?

    // MARK: - Mode Helpers

    private var connection: DatabaseConnection {
        switch mode {
        case .tables(let conn, _): return conn
        case .queryResults(let conn, _, _): return conn
        case .streamingQuery(let conn, _, _): return conn
        }
    }

    private var isQueryResultsMode: Bool {
        switch mode {
        case .queryResults, .streamingQuery: return true
        default: return false
        }
    }

    private var queryResultsRowCount: Int {
        if case .queryResults(_, let tableRows, _) = mode {
            return tableRows.count
        }
        return 0
    }

    private var preselection: ExportPreselection {
        if case .tables(_, let preselection) = mode {
            return preselection
        }
        return .tables([])
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if !isQueryResultsMode {
                    tableSelectionView
                        .frame(minWidth: leftPanelWidth)

                    Divider()
                }

                exportOptionsView
                    .frame(width: 280)
            }
            .frame(height: 420)

            Divider()

            footerView
        }
        .frame(width: dialogWidth)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            let available = availableFormats
            if let lastFormatId = TransferDialogStorage.shared.loadLastExportFormatId(),
               available.contains(where: { type(of: $0).formatId == lastFormatId }) {
                config.formatId = lastFormatId
            } else if !available.contains(where: { type(of: $0).formatId == config.formatId }),
                      let first = available.first {
                config.formatId = type(of: first).formatId
            }
            captureSettingsSnapshot()
        }
        .onDisappear {
            if !exportSucceeded {
                restoreSettingsSnapshot()
            }
        }
        .onChange(of: config.formatId) {
            resetOptionValues()
        }
        .onExitCommand {
            if !isExporting {
                isPresented = false
            }
        }
        .task {
            if isQueryResultsMode {
                switch mode {
                case .queryResults(_, _, let suggestedFileName):
                    config.fileName = suggestedFileName
                case .streamingQuery(_, _, let suggestedFileName):
                    config.fileName = suggestedFileName
                default:
                    break
                }
                isLoading = false
            } else {
                populateFromSidebarTables()
                await loadDatabaseItems()
            }
        }
        .sheet(isPresented: $showProgressDialog) {
            ExportProgressView(
                tableName: exportService?.state.currentTable ?? "",
                tableIndex: exportService?.state.currentTableIndex ?? 0,
                totalTables: exportService?.state.totalTables ?? 0,
                processedRows: exportService?.state.processedRows ?? 0,
                totalRows: exportService?.state.totalRows ?? 0,
                statusMessage: exportService?.state.statusMessage ?? ""
            ) {
                exportService?.cancelExport()
            }
            .interactiveDismissDisabled()
            .onExitCommand { }
        }
        .onChange(of: showSuccessDialog) { _, isShowing in
            guard isShowing else { return }
            TransferResultAlert.presentExportSuccess(window: NSApp.keyWindow) { choice in
                showSuccessDialog = false
                if choice == .openFolder {
                    openContainingFolder()
                }
                isPresented = false
            }
        }
    }

    // MARK: - Plugin Helpers

    private var availableFormats: [any ExportFormatPlugin] {
        let dbTypeId = connection.type.rawValue
        return PluginManager.shared.allExportPlugins()
            .filter { plugin in
                let pluginType = type(of: plugin)
                if !pluginType.supportedDatabaseTypeIds.isEmpty {
                    return pluginType.supportedDatabaseTypeIds.contains(dbTypeId)
                }
                if pluginType.excludedDatabaseTypeIds.contains(dbTypeId) {
                    return false
                }
                return true
            }
            .sorted { a, b in
                let aIndex = Self.formatDisplayOrder.firstIndex(of: type(of: a).formatId) ?? Int.max
                let bIndex = Self.formatDisplayOrder.firstIndex(of: type(of: b).formatId) ?? Int.max
                return aIndex < bIndex
            }
    }

    private var availableFormatIds: [String] {
        availableFormats.map { type(of: $0).formatId }
    }

    private var currentPlugin: (any ExportFormatPlugin)? {
        PluginManager.shared.exportPlugin(forFormat: config.formatId)
    }

    private var currentOptionColumnCount: Int {
        guard let plugin = currentPlugin else { return 0 }
        return type(of: plugin).perTableOptionColumns.count
    }

    private var currentDefaultOptionValues: [Bool] {
        currentPlugin?.defaultTableOptionValues() ?? []
    }

    // MARK: - Layout Constants

    private var leftPanelWidth: CGFloat {
        guard let plugin = currentPlugin else { return 240 }
        return type(of: plugin).perTableOptionColumns.isEmpty ? 240 : 380
    }

    private var dialogWidth: CGFloat {
        isQueryResultsMode ? 280 : leftPanelWidth + 280
    }

    // MARK: - Table Selection View

    private var tableSelectionView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Items")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()

                if let plugin = currentPlugin {
                    ForEach(type(of: plugin).perTableOptionColumns) { column in
                        Text(column.label)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(width: column.width, alignment: .center)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            if isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading databases...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    Spacer()
                }
            } else if databaseItems.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("No tables found")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(minHeight: 300, maxHeight: .infinity)
            } else {
                ExportTableTreeView(
                    databaseItems: $databaseItems,
                    formatId: config.formatId
                )
                .frame(minHeight: 300, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Export Options View

    private var exportOptionsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                if availableFormats.isEmpty {
                    HStack {
                        Spacer()
                        Text("No export formats available. Enable export plugins in Settings > Plugins.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    HStack {
                        Spacer()

                        Picker("", selection: $config.formatId) {
                            ForEach(availableFormatIds, id: \.self) { formatId in
                                if let plugin = PluginManager.shared.exportPlugin(forFormat: formatId) {
                                    Text(type(of: plugin).formatDisplayName).tag(formatId)
                                }
                            }
                        }
                        .labelsHidden()

                        Spacer()
                    }

                    let description = formatDescription(for: config.formatId)
                    if !description.isEmpty {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 2) {
                    if case .streamingQuery = mode {
                        Text("All rows")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if isQueryResultsMode {
                        Text("\(queryResultsRowCount) row\(queryResultsRowCount == 1 ? "" : "s") to export")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(exportableCount) table\(exportableCount == 1 ? "" : "s") to export")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if let plugin = currentPlugin, !type(of: plugin).perTableOptionColumns.isEmpty, exportableCount < selectedCount {
                            Text("\(selectedCount - exportableCount) skipped (no options)")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let settable = currentPlugin as? any SettablePluginDiscoverable,
                       let optionsView = settable.settingsView() {
                        optionsView

                        HStack {
                            Spacer()
                            Button("Reset to Defaults") {
                                resetCurrentFormatSettings()
                            }
                            .buttonStyle(.link)
                            .font(.callout)
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Button("Cancel") {
                isPresented = false
            }
            .disabled(isExporting)

            Spacer()

            if isExporting {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)

                    Text(exportService?.state.currentTable ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 120)
                }
            }

            Button("Export...") {
                Task {
                    await performExport()
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isExportDisabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Computed Properties

    private var selectedCount: Int {
        databaseItems.reduce(0) { $0 + $1.selectedCount }
    }

    private var selectedTables: [ExportTableItem] {
        databaseItems.flatMap { $0.selectedTables }
    }

    private var exportableTables: [ExportTableItem] {
        let tables = selectedTables
        guard let plugin = currentPlugin else { return tables }
        return tables.filter { plugin.isTableExportable(optionValues: $0.optionValues) }
    }

    /// Count of tables that will actually produce output
    private var exportableCount: Int {
        exportableTables.count
    }

    private var fileExtension: String {
        currentPlugin?.currentFileExtension ?? config.formatId
    }

    private var isExportDisabled: Bool {
        if isExporting || availableFormats.isEmpty {
            return true
        }
        if case .streamingQuery = mode {
            return false
        }
        if isQueryResultsMode {
            return queryResultsRowCount == 0
        }
        return exportableCount == 0
    }

    private static let formatDisplayOrder = ["csv", "json", "sql", "xlsx", "mql"]

    private func formatDescription(for formatId: String) -> String {
        switch formatId {
        case "csv": return String(localized: "Comma-separated values. Compatible with Excel and most tools.")
        case "json": return String(localized: "Structured data format. Ideal for APIs and web applications.")
        case "sql": return String(localized: "SQL INSERT statements. Use to recreate data in another database.")
        case "xlsx": return String(localized: "Excel spreadsheet with formatting support.")
        case "mql": return String(localized: "MongoDB query language. Use to import into MongoDB.")
        default: return ""
        }
    }

    private func resetOptionValues() {
        databaseItems = databaseItems.resettingOptionValues(to: currentDefaultOptionValues)
    }

    // MARK: - Actions

    private func captureSettingsSnapshot() {
        settingsSnapshot = PluginSettingsSnapshot(
            plugins: availableFormats.compactMap { $0 as? any SettablePluginDiscoverable }
        )
    }

    private func restoreSettingsSnapshot() {
        settingsSnapshot?.restore()
        settingsSnapshot = nil
    }

    private func resetCurrentFormatSettings() {
        guard let settable = currentPlugin as? any SettablePluginDiscoverable else { return }
        settable.resetSettingsToDefaults()
        settingsSnapshot?.recapture(settable)
    }

    private func recordSuccessfulExport() {
        exportSucceeded = true
        TransferDialogStorage.shared.saveLastExportFormatId(config.formatId)
        settingsSnapshot = nil
    }

    /// Instantly populate the current database from sidebar tables (no network).
    ///
    /// The sidebar lists exactly what the export scope already points at, so the rows carry
    /// no qualifier. Naming the database here would reach the export data source as a schema
    /// on the engines that group by schema, which is a different container.
    private func populateFromSidebarTables() {
        guard !sidebarTables.isEmpty else { return }
        /// These rows are the sidebar's, so they belong to the database being browsed. When the
        /// dialog is scoped somewhere else they are the wrong tables under the right name, and a
        /// failed load would leave them on screen looking like that database's contents.
        guard preselection.scopedDatabase == nil else { return }
        let dbName = connection.database
        let tableItems = sidebarTables.map { table in
            ExportTableItem(
                name: table.name,
                databaseName: "",
                type: table.type,
                isSelected: preselection.selects(
                    table: table.name,
                    inContainer: .database(dbName),
                    isCurrentContainer: true
                )
            )
        }
        let item = ExportDatabaseItem(
            name: dbName.isEmpty ? "Tables" : dbName,
            tables: tableItems,
            isExpanded: true
        )
        databaseItems = [item].normalizingOptionValues(
            optionColumnCount: currentOptionColumnCount,
            defaultOptionValues: currentDefaultOptionValues
        )
        isLoading = false
    }

    private struct ExportRowSnapshot {
        let isSelected: Bool
        let optionValues: [Bool]
    }

    private func priorRowSnapshots() -> [String: ExportRowSnapshot] {
        var snapshots: [String: ExportRowSnapshot] = [:]
        for database in databaseItems {
            for table in database.tables {
                snapshots["\(database.name).\(table.name)"] = ExportRowSnapshot(
                    isSelected: table.isSelected,
                    optionValues: table.optionValues
                )
            }
        }
        return snapshots
    }

    @MainActor
    private func loadDatabaseItems() async {
        let priorRows = priorRowSnapshots()

        do {
            var items: [ExportDatabaseItem] = []

            let dbType = connection.type
            let grouping = PluginManager.shared.databaseGroupingStrategy(for: dbType)
            switch grouping {
            case .bySchema, .hierarchicalSchema:
                let schemas = try await withExportDriver { driver in
                    try await driver.fetchSchemas()
                }
                let defaultSchema = PluginManager.shared.defaultSchemaName(for: dbType)
                for schema in schemas {
                    let tables = try await fetchTablesForSchema(schema)
                    let isDefaultSchema = schema.caseInsensitiveCompare(defaultSchema) == .orderedSame
                    let tableItems = tables.map { table in
                        let priorRow = priorRows["\(schema).\(table.name)"]
                        let selected = priorRow?.isSelected
                            ?? preselection.selects(
                                table: table.name,
                                inContainer: .schema(database: exportDatabaseName, schema: schema),
                                isCurrentContainer: isDefaultSchema
                            )
                        return ExportTableItem(
                            name: table.name,
                            databaseName: schema,
                            type: table.type,
                            isSelected: selected,
                            optionValues: priorRow?.optionValues ?? []
                        )
                    }
                    if !tableItems.isEmpty {
                        items.append(ExportDatabaseItem(
                            name: schema,
                            tables: tableItems,
                            isExpanded: isDefaultSchema || preselection.containerNames.contains(schema)
                        ))
                    }
                }
                items.sort { item1, item2 in
                    if item1.name.caseInsensitiveCompare(defaultSchema) == .orderedSame { return true }
                    if item2.name.caseInsensitiveCompare(defaultSchema) == .orderedSame { return false }
                    return item1.name < item2.name
                }
            case .flat:
                let fallbackName = PluginManager.shared.defaultGroupName(for: dbType)
                let dbItem = try await buildFlatDatabaseItem(
                    name: connection.database.isEmpty ? fallbackName : connection.database,
                    priorRows: priorRows
                )
                if let dbItem { items.append(dbItem) }
            case .byDatabase:
                let databases = try await withExportDriver { driver in
                    try await driver.fetchDatabases()
                }
                let tablesByDatabase = try await fetchTablesGroupedByDatabase()
                for dbName in databases {
                    let tables = tablesByDatabase[dbName] ?? []
                    let isCurrentDB = dbName == connection.database
                    let tableItems = tables.map { table in
                        let priorRow = priorRows["\(dbName).\(table.name)"]
                        let selected = priorRow?.isSelected
                            ?? preselection.selects(
                                table: table.name,
                                inContainer: .database(dbName),
                                isCurrentContainer: isCurrentDB
                            )
                        return ExportTableItem(
                            name: table.name,
                            databaseName: dbName,
                            type: table.type,
                            isSelected: selected,
                            optionValues: priorRow?.optionValues ?? []
                        )
                    }
                    if !tableItems.isEmpty {
                        items.append(ExportDatabaseItem(
                            name: dbName,
                            tables: tableItems,
                            isExpanded: isCurrentDB || preselection.containerNames.contains(dbName)
                        ))
                    }
                }
                items.sort { item1, item2 in
                    if item1.name == connection.database { return true }
                    if item2.name == connection.database { return false }
                    return item1.name < item2.name
                }
            }

            databaseItems = items.normalizingOptionValues(
                optionColumnCount: currentOptionColumnCount,
                defaultOptionValues: currentDefaultOptionValues
            )
            isLoading = false

            if let singleTable = preselection.singleTableName {
                config.fileName = singleTable
            } else if preselection.containerNames.count == 1, let container = preselection.containerNames.first {
                config.fileName = container
            } else if !connection.database.isEmpty {
                config.fileName = connection.database
            }
        } catch {
            isLoading = false
            AlertHelper.showErrorSheet(
                title: String(localized: "Export Error"),
                message: String(format: String(localized: "Failed to load databases: %@"), error.localizedDescription),
                window: nil
            )
        }
    }

    private func buildFlatDatabaseItem(
        name: String,
        priorRows: [String: ExportRowSnapshot] = [:]
    ) async throws -> ExportDatabaseItem? {
        let tables = try await withExportDriver { driver in
            try await driver.fetchTables()
        }
        let tableItems = tables.map { table in
            let priorRow = priorRows["\(name).\(table.name)"]
            return ExportTableItem(
                name: table.name,
                databaseName: "",
                type: table.type,
                isSelected: priorRow?.isSelected ?? preselection.selects(
                    table: table.name,
                    inContainer: .database(name),
                    isCurrentContainer: true
                ),
                optionValues: priorRow?.optionValues ?? []
            )
        }
        guard !tableItems.isEmpty else { return nil }
        return ExportDatabaseItem(name: name, tables: tableItems, isExpanded: true)
    }

    private func fetchTablesForSchema(_ schema: String) async throws -> [TableInfo] {
        try await withExportDriver { driver in
            try await driver.fetchTables(schema: schema)
        }
    }

    /// One server-wide read for every database. The query carries no WHERE clause, so a
    /// connection per database would return the same rows and only cost a connect, and a
    /// database the user can list but not open becomes an empty group instead of an error
    /// that fails the whole dialog.
    private func fetchTablesGroupedByDatabase() async throws -> [String: [TableInfo]] {
        try await withExportDriver { driver in
            let query = """
                SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE
                FROM information_schema.TABLES
                ORDER BY TABLE_NAME
                """
            let result = try await driver.execute(query: query)

            var grouped: [String: [TableInfo]] = [:]
            for row in result.rows {
                guard row.count >= 2,
                      let rowSchema = row[0].asText,
                      let name = row[1].asText else {
                    continue
                }
                let typeStr = row.count > 2 ? (row[2].asText ?? "BASE TABLE") : "BASE TABLE"
                let type: TableInfo.TableType = typeStr.uppercased().contains("VIEW") ? .view : .table
                grouped[rowSchema, default: []].append(TableInfo(name: name, type: type, rowCount: nil))
            }
            return grouped
        }
    }

    @MainActor
    private func performExport() async {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }

        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        savePanel.showsTagField = false

        let ext = fileExtension
        if ext.contains(".") {
            let lastComponent = ext.components(separatedBy: ".").last ?? ext
            savePanel.allowedContentTypes = [UTType(filenameExtension: lastComponent) ?? .data]
            savePanel.nameFieldStringValue = "\(config.fileName).\(ext)"
        } else {
            let utType = UTType(filenameExtension: ext) ?? .plainText
            savePanel.allowedContentTypes = [utType]
            savePanel.nameFieldStringValue = config.fullFileName
        }

        let formatName = currentPlugin.map { type(of: $0).formatDisplayName } ?? config.formatId.uppercased()
        if case .streamingQuery = mode {
            savePanel.message = String(format: String(localized: "Export query results to %@"), formatName)
        } else if isQueryResultsMode {
            savePanel.message = String(format: String(localized: "Export %d row(s) to %@"), queryResultsRowCount, formatName)
        } else {
            savePanel.message = String(format: String(localized: "Export %d table(s) to %@"), exportableCount, formatName)
        }

        let response = await savePanel.presentAsSheet(for: window)
        guard response == .OK, let url = savePanel.url else { return }

        if isQueryResultsMode {
            await startQueryResultsExport(to: url)
        } else {
            await startExport(to: url)
        }
    }

    /// The database this dialog exports from. Its connection carries the database the sheet
    /// was opened against, and `resolvedScope` falls back to where the user is browsing when
    /// that connection has no database of its own.
    private var exportScope: DatabaseScope? {
        DatabaseManager.shared.resolvedScope(database: connection.database, schema: nil, for: connection.id)
    }

    /// The name of that database, for the container refs the preselection is matched against.
    private var exportDatabaseName: String {
        exportScope?.database ?? connection.database
    }

    /// Every list in this dialog reads from the database it will export from, not from wherever
    /// the sidebar happens to be browsing. Those were the same connection until a container in
    /// another database could be exported, and then the dialog listed one database's schemas while
    /// `exportScope` pointed at another.
    private func withExportDriver<T: Sendable>(
        workload: MetadataConnectionPool.Workload = .bulk,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        guard let scope = exportScope else { throw ExportError.notConnected }
        return try await DatabaseManager.shared.withMetadataDriver(scope: scope, workload: workload, body)
    }

    private func showExportError(_ error: Error) {
        AlertHelper.showErrorSheet(
            title: String(localized: "Export Error"),
            message: error.localizedDescription,
            window: nil
        )
    }

    @MainActor
    private func startExport(to url: URL) async {
        guard let scope = exportScope else {
            showExportError(ExportError.notConnected)
            return
        }
        let route = DatabaseManager.shared.executionRoute(for: scope)

        isExporting = true
        exportedFileURL = url
        showProgressDialog = true

        do {
            try await DatabaseManager.shared.withScopedDriver(
                scope: scope,
                route: route,
                workload: .bulk,
                cancellation: .untracked
            ) { driver in
                try await runTableExport(on: driver, to: url)
            }

            showProgressDialog = false
            isExporting = false
            recordSuccessfulExport()

            if hideSuccessDialog {
                isPresented = false
            } else {
                showSuccessDialog = true
            }
        } catch is PluginExportCancellationError {
            showProgressDialog = false
            isExporting = false
        } catch {
            showProgressDialog = false
            isExporting = false
            showExportError(error)
        }
    }

    /// The whole export runs inside the scoped lease, so every statement it issues lands on
    /// the database the dialog was opened for rather than wherever the shared driver was
    /// last parked by another tab.
    @MainActor
    private func runTableExport(on driver: DatabaseDriver, to url: URL) async throws {
        let service = ExportService(driver: driver, databaseType: connection.type)
        exportService = service
        try await service.export(tables: exportableTables, config: config, to: url)
    }

    @MainActor
    private func runStreamingExport(on driver: DatabaseDriver, query: String, to url: URL) async throws {
        let service = ExportService(driver: driver, databaseType: connection.type)
        exportService = service
        try await service.exportStreamingQuery(query: query, config: config, to: url)
    }

    @MainActor
    private func startQueryResultsExport(to url: URL) async {
        isExporting = true
        exportedFileURL = url
        showProgressDialog = true

        do {
            switch mode {
            case .streamingQuery(_, let query, _):
                guard let scope = exportScope else { throw ExportError.notConnected }
                let route = DatabaseManager.shared.executionRoute(for: scope)
                try await DatabaseManager.shared.withScopedDriver(
                    scope: scope,
                    route: route,
                    workload: .bulk,
                    cancellation: .untracked
                ) { driver in
                    try await runStreamingExport(on: driver, query: query, to: url)
                }
            case .queryResults(_, let tableRows, _):
                let service = ExportService(databaseType: connection.type)
                exportService = service
                try await service.exportQueryResults(tableRows: tableRows, config: config, to: url)
            default:
                showProgressDialog = false
                isExporting = false
                return
            }

            showProgressDialog = false
            isExporting = false
            recordSuccessfulExport()

            if hideSuccessDialog {
                isPresented = false
            } else {
                showSuccessDialog = true
            }
        } catch is PluginExportCancellationError {
            showProgressDialog = false
            isExporting = false
        } catch {
            showProgressDialog = false
            isExporting = false
            showExportError(error)
        }
    }

    private func openContainingFolder() {
        guard let url = exportedFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Preview

#Preview {
    let connection = DatabaseConnection(
        name: "Local MySQL",
        host: "localhost",
        database: "my_database",
        type: .mysql
    )

    return ExportDialog(
        isPresented: .constant(true),
        mode: .tables(connection: connection, preselection: .tables(["users"]))
    )
}
