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
    @State private var showActivationSheet = false

    // MARK: - User Preferences

    @AppStorage("hideExportSuccessDialog") private var hideSuccessDialog = false

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
        if case .queryResults(_, let rowBuffer, _) = mode {
            return rowBuffer.rows.count
        }
        return 0
    }

    private var preselectedTables: Set<String> {
        if case .tables(_, let tables) = mode {
            return tables
        }
        return []
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Content
            HStack(spacing: 0) {
                if !isQueryResultsMode {
                    // Left: Table tree view
                    tableSelectionView
                        .frame(width: leftPanelWidth)

                    Divider()
                }

                // Right: Export options
                exportOptionsView
                    .frame(width: 280)
            }
            .frame(height: 420)

            Divider()

            // Footer
            footerView
        }
        .frame(width: dialogWidth)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showActivationSheet) {
            LicenseActivationSheet()
        }
        .onAppear {
            let available = availableFormats
            if !available.contains(where: { type(of: $0).formatId == config.formatId }) {
                if let first = available.first {
                    config.formatId = type(of: first).formatId
                }
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
        }
        .sheet(isPresented: $showSuccessDialog) {
            ExportSuccessView(
                onOpenFolder: {
                    openContainingFolder()
                    showSuccessDialog = false
                    isPresented = false
                },
                onClose: {
                    showSuccessDialog = false
                    isPresented = false
                }
            )
        }
    }

    // MARK: - Plugin Helpers

    private var availableFormats: [any ExportFormatPlugin] {
        let dbTypeId = connection.type.rawValue
        return PluginManager.shared.exportPlugins.values
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
        PluginManager.shared.exportPlugins[config.formatId]
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
            // Header with title and selection count
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

            // Tree view or loading indicator
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
            // Format picker with selection count
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
                                if let plugin = PluginManager.shared.exportPlugins[formatId] {
                                    if isProGatedFormat(formatId) {
                                        Text("\(type(of: plugin).formatDisplayName) (Pro)").tag(formatId)
                                    } else {
                                        Text(type(of: plugin).formatDisplayName).tag(formatId)
                                    }
                                }
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 180)

                        Spacer()
                    }

                    let description = formatDescription(for: config.formatId)
                    if !description.isEmpty {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                // Selection count or Pro gate message
                VStack(spacing: 2) {
                    if isProGatedFormat(config.formatId) {
                        Text(String(localized: "XLSX export requires a Pro license."))
                            .font(.subheadline)
                            .foregroundStyle(Color(nsColor: .systemOrange))
                        Button(String(localized: "Activate License...")) {
                            showActivationSheet = true
                        }
                        .font(.subheadline)
                        .buttonStyle(.link)
                    } else if case .streamingQuery = mode {
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
                                .foregroundStyle(Color(nsColor: .systemOrange))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // Format-specific options
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let settable = currentPlugin as? any SettablePluginDiscoverable,
                       let optionsView = settable.settingsView() {
                        optionsView
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            Spacer(minLength: 0)

            Divider()

            // File name section
            VStack(alignment: .leading, spacing: 6) {
                Text("File name")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    TextField("export", text: $config.fileName)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)

                    Text(".\(fileExtension)")
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .fixedSize()
                }

                // Show validation error if filename is invalid
                if let validationError = fileNameValidationError {
                    Text(validationError)
                        .font(.subheadline)
                        .foregroundStyle(Color(nsColor: .systemRed))
                }
            }
            .padding(16)
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
            .keyboardShortcut(.return, modifiers: [])
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
        if isExporting || !isFileNameValid || availableFormats.isEmpty || isProGatedFormat(config.formatId) {
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
    private static let proFormatIds: Set<String> = ["xlsx"]

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

    private func isProGatedFormat(_ formatId: String) -> Bool {
        Self.proFormatIds.contains(formatId) && !LicenseManager.shared.isFeatureAvailable(.xlsxExport)
    }

    /// Windows reserved device names (case-insensitive)
    private static let windowsReservedNames: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
    ]

    /// Returns a validation error message if the filename is invalid, nil if valid
    private var fileNameValidationError: String? {
        let name = config.fileName.trimmingCharacters(in: .whitespaces)

        if name.isEmpty {
            return String(localized: "Filename cannot be empty")
        }

        // Invalid filesystem characters (covers macOS, Windows, and Linux)
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        if name.rangeOfCharacter(from: invalidChars) != nil {
            return String(localized: "Filename contains invalid characters: / \\ : * ? \" < > |")
        }

        // Prevent path traversal attempts and special directory names
        if name == "." || name == ".." ||
            name.hasPrefix("../") || name.hasPrefix("..\\") ||
            name.hasSuffix("/..") || name.hasSuffix("\\..") ||
            name.contains("/../") || name.contains("\\..\\") {
            return String(localized: "Filename cannot be '.' or '..' or contain path traversal")
        }

        // Check for Windows reserved device names (case-insensitive)
        let baseName = name.components(separatedBy: ".").first ?? name
        if Self.windowsReservedNames.contains(baseName.uppercased()) {
            return String(format: String(localized: "'%@' is a reserved Windows device name"), baseName)
        }

        // Check filename length (255 bytes is common limit on most filesystems)
        if name.utf8.count > 255 {
            return String(localized: "Filename is too long (max 255 bytes)")
        }

        return nil
    }

    /// Validates that the filename is not empty and contains no invalid filesystem characters
    private var isFileNameValid: Bool {
        fileNameValidationError == nil
    }

    private func resetOptionValues() {
        let defaults = currentPlugin?.defaultTableOptionValues() ?? []
        for dbIndex in databaseItems.indices {
            for tableIndex in databaseItems[dbIndex].tables.indices {
                databaseItems[dbIndex].tables[tableIndex].optionValues = defaults
            }
        }
    }

    // MARK: - Actions

    /// Instantly populate the current database from sidebar tables (no network).
    private func populateFromSidebarTables() {
        guard !sidebarTables.isEmpty else { return }
        let dbName = connection.database
        let tableItems = sidebarTables.map { table in
            ExportTableItem(
                name: table.name,
                databaseName: dbName,
                type: table.type,
                isSelected: preselectedTables.contains(table.name)
            )
        }
        let item = ExportDatabaseItem(
            name: dbName.isEmpty ? "Tables" : dbName,
            tables: tableItems,
            isExpanded: true
        )
        databaseItems = [item]
        isLoading = false
    }

    /// Build a lookup of user-toggled selection state from current `databaseItems`.
    private func currentSelectionState() -> [String: Bool] {
        var state: [String: Bool] = [:]
        for db in databaseItems {
            for table in db.tables {
                state["\(db.name).\(table.name)"] = table.isSelected
            }
        }
        return state
    }

    @MainActor
    private func loadDatabaseItems() async {
        guard let driver = DatabaseManager.shared.driver(for: connection.id) else {
            isLoading = false
            AlertHelper.showErrorSheet(
                title: String(localized: "Export Error"),
                message: String(localized: "Not connected to database"),
                window: nil
            )
            return
        }

        // Snapshot user-toggled selections before replacing items
        let priorSelections = currentSelectionState()

        do {
            var items: [ExportDatabaseItem] = []

            let dbType = connection.type
            let grouping = PluginManager.shared.databaseGroupingStrategy(for: dbType)
            switch grouping {
            case .bySchema:
                let schemas = try await driver.fetchSchemas()
                let defaultSchema = PluginManager.shared.defaultSchemaName(for: dbType)
                for schema in schemas {
                    let tables = try await fetchTablesForSchema(schema, driver: driver)
                    let isDefaultSchema = schema.caseInsensitiveCompare(defaultSchema) == .orderedSame
                    let tableItems = tables.map { table in
                        let key = "\(schema).\(table.name)"
                        let selected = priorSelections[key]
                            ?? (isDefaultSchema && preselectedTables.contains(table.name))
                        return ExportTableItem(
                            name: table.name,
                            databaseName: schema,
                            type: table.type,
                            isSelected: selected
                        )
                    }
                    if !tableItems.isEmpty {
                        items.append(ExportDatabaseItem(
                            name: schema,
                            tables: tableItems,
                            isExpanded: isDefaultSchema
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
                    driver: driver,
                    name: connection.database.isEmpty ? fallbackName : connection.database,
                    priorSelections: priorSelections
                )
                if let dbItem { items.append(dbItem) }
            case .byDatabase:
                let databases = try await driver.fetchDatabases()
                for dbName in databases {
                    let tables = try await fetchTablesForDatabase(dbName, driver: driver)
                    let isCurrentDB = dbName == connection.database
                    let tableItems = tables.map { table in
                        let key = "\(dbName).\(table.name)"
                        let selected = priorSelections[key]
                            ?? (isCurrentDB && preselectedTables.contains(table.name))
                        return ExportTableItem(
                            name: table.name,
                            databaseName: dbName,
                            type: table.type,
                            isSelected: selected
                        )
                    }
                    if !tableItems.isEmpty {
                        items.append(ExportDatabaseItem(
                            name: dbName,
                            tables: tableItems,
                            isExpanded: isCurrentDB
                        ))
                    }
                }
                items.sort { item1, item2 in
                    if item1.name == connection.database { return true }
                    if item2.name == connection.database { return false }
                    return item1.name < item2.name
                }
            }

            databaseItems = items
            isLoading = false

            // Set default filename based on selection
            if preselectedTables.count == 1, let first = preselectedTables.first {
                config.fileName = first
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
        driver: DatabaseDriver,
        name: String,
        priorSelections: [String: Bool] = [:]
    ) async throws -> ExportDatabaseItem? {
        let tables = try await driver.fetchTables()
        let tableItems = tables.map { table in
            let key = "\(name).\(table.name)"
            let selected = priorSelections[key] ?? preselectedTables.contains(table.name)
            return ExportTableItem(
                name: table.name,
                databaseName: "",
                type: table.type,
                isSelected: selected
            )
        }
        guard !tableItems.isEmpty else { return nil }
        return ExportDatabaseItem(name: name, tables: tableItems, isExpanded: true)
    }

    private func fetchTablesForSchema(_ schema: String, driver: DatabaseDriver) async throws -> [TableInfo] {
        // Oracle does not have information_schema — use ALL_TABLES/ALL_VIEWS
        if connection.type.pluginTypeId == "Oracle" {
            let escapedSchema = schema.replacingOccurrences(of: "'", with: "''")
            let query = """
                SELECT TABLE_NAME, 'BASE TABLE' AS TABLE_TYPE FROM ALL_TABLES WHERE OWNER = '\(escapedSchema)'
                UNION ALL
                SELECT VIEW_NAME, 'VIEW' FROM ALL_VIEWS WHERE OWNER = '\(escapedSchema)'
                ORDER BY 1
                """
            let result = try await driver.execute(query: query)
            return result.rows.compactMap { row in
                guard let name = row[safe: 0] ?? nil else { return nil }
                let typeStr = (row[safe: 1] ?? nil) ?? "BASE TABLE"
                let type: TableInfo.TableType = typeStr.uppercased().contains("VIEW") ? .view : .table
                return TableInfo(name: name, type: type, rowCount: nil)
            }
        }

        // MSSQL / PostgreSQL / Redshift: use information_schema
        let query = """
            SELECT table_schema, table_name, table_type
            FROM information_schema.tables
            ORDER BY table_name
            """
        let result = try await driver.execute(query: query)
        return result.rows.compactMap { row in
            // Expect: [table_schema, table_name, table_type]
            guard row.count >= 2,
                  let rowSchema = row[0],
                  rowSchema == schema,
                  let name = row[1] else {
                return nil
            }
            let typeStr = row.count > 2 ? (row[2] ?? "BASE TABLE") : "BASE TABLE"
            let type: TableInfo.TableType = typeStr.uppercased().contains("VIEW") ? .view : .table
            return TableInfo(name: name, type: type, rowCount: nil)
        }
    }

    private func fetchTablesForDatabase(_ database: String, driver: DatabaseDriver) async throws -> [TableInfo] {
        // Fetch tables from information_schema and filter by database in Swift to avoid SQL interpolation.
        // MySQL/MariaDB: information_schema.TABLES contains TABLE_SCHEMA, TABLE_NAME, and TABLE_TYPE.
        let query = """
            SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE
            FROM information_schema.TABLES
            ORDER BY TABLE_NAME
            """
        let result = try await driver.execute(query: query)

        return result.rows.compactMap { row in
            // Expect: [TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE]
            guard row.count >= 2,
                  let rowSchema = row[0],
                  rowSchema == database,
                  let name = row[1] else {
                return nil
            }
            let typeStr = row.count > 2 ? (row[2] ?? "BASE TABLE") : "BASE TABLE"
            let type: TableInfo.TableType = typeStr.uppercased().contains("VIEW") ? .view : .table
            return TableInfo(name: name, type: type, rowCount: nil)
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

    @MainActor
    private func startExport(to url: URL) async {
        guard let driver = DatabaseManager.shared.driver(for: connection.id) else {
            AlertHelper.showErrorSheet(
                title: String(localized: "Export Error"),
                message: String(localized: "Not connected to database"),
                window: nil
            )
            return
        }

        isExporting = true
        exportedFileURL = url

        let service = ExportService(
            driver: driver,
            databaseType: connection.type
        )
        exportService = service

        // Show progress dialog
        showProgressDialog = true

        do {
            try await service.export(
                tables: exportableTables,
                config: config,
                to: url
            )

            showProgressDialog = false
            isExporting = false

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
            AlertHelper.showErrorSheet(
                title: String(localized: "Export Error"),
                message: error.localizedDescription,
                window: nil
            )
        }
    }

    @MainActor
    private func startQueryResultsExport(to url: URL) async {
        isExporting = true
        exportedFileURL = url
        showProgressDialog = true

        do {
            let service: ExportService
            switch mode {
            case .streamingQuery(_, let query, _):
                guard let driver = DatabaseManager.shared.driver(for: connection.id) else { return }
                service = ExportService(driver: driver, databaseType: connection.type)
                exportService = service
                try await service.exportStreamingQuery(query: query, config: config, to: url)
            case .queryResults(_, let rowBuffer, _):
                service = ExportService(databaseType: connection.type)
                exportService = service
                try await service.exportQueryResults(rowBuffer: rowBuffer, config: config, to: url)
            default:
                return
            }

            showProgressDialog = false
            isExporting = false

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
            AlertHelper.showErrorSheet(
                title: String(localized: "Export Error"),
                message: error.localizedDescription,
                window: nil
            )
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
        mode: .tables(connection: connection, preselectedTables: ["users"])
    )
}
