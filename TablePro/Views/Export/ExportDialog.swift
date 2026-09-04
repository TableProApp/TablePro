//
//  ExportDialog.swift
//  TablePro
//

import AppKit
import os
import SwiftUI
import TableProPluginKit
import UniformTypeIdentifiers

struct ExportDialog: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ExportDialog")

    @Binding var isPresented: Bool
    let mode: ExportMode
    var sidebarTables: [TableInfo] = []

    // MARK: - State

    @State private var config = ExportConfiguration()
    @State private var databaseItems: [ExportDatabaseItem] = []
    @State private var isLoading = true
    @State private var isExporting = false
    @State private var exportStartedAt: ContinuousClock.Instant?
    @State private var showProgressDialog = false
    @State private var showSuccessDialog = false
    @State private var exportedFileURL: URL?
    @State private var settingsSnapshot: PluginSettingsSnapshot?
    @State private var exportSucceeded = false

    /// Which object kinds the last load actually read, so a format switch knows whether the tree it
    /// already holds can answer for the new format without another round trip.
    @State private var loadedObjectKinds: Set<PluginExportObjectKind> = []

    @State private var profiles: [ExportProfile] = []
    @State private var profileName = ""
    @State private var isNamingProfile = false

    /// The window this dialog is hosted in, used for presenting its alerts and panels.
    /// Avoids `NSApp.keyWindow`, which when a result is presented is the progress sheet being
    /// torn down in the same transaction, and AppKit ends a sheet's children with it (#2314).
    @State private var hostWindow: NSWindow?

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

    /// The name the progress sheet puts in front of the user. A streaming query has no current
    /// table, so it is named by the file it is being written to instead of by an empty string.
    private var progressSubject: String {
        let currentTable = exportService?.state.currentTable ?? ""
        guard currentTable.isEmpty else { return currentTable }
        return config.fileName.isEmpty
            ? String(localized: "Query results")
            : config.fileName
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
                        .frame(minWidth: leftPanelWidth, maxWidth: .infinity)

                    Divider()
                }

                exportOptionsView
                    .frame(width: Self.optionsPanelWidth)
            }
            .frame(minHeight: 320, idealHeight: 420, maxHeight: .infinity)

            Divider()

            footerView
        }
        .frame(
            minWidth: dialogWidth,
            idealWidth: dialogWidth,
            maxWidth: isQueryResultsMode ? dialogWidth : .infinity
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            WindowAccessor { window in
                hostWindow = window
            }
        }
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
            profiles = ExportProfileStorage.shared.profiles(for: connection.id)
        }
        .onDisappear {
            if !exportSucceeded {
                restoreSettingsSnapshot()
            }
        }
        .onChange(of: config.formatId) {
            resetOptionValues()
            Task { await reconcileObjectKindsForFormat() }
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
                subject: progressSubject,
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
            TransferResultAlert.presentExportSuccess(
                warnings: exportService?.state.warnings ?? [],
                window: hostWindow
            ) { choice in
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
        let supported = PluginManager.shared.allExportPlugins()
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
        return ExportFormatCatalog.sorted(supported)
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

    /// The options column is an inspector: it holds one control per option and gains nothing from
    /// being wider. The tree beside it takes every point the user drags the sheet out to.
    private static let optionsPanelWidth: CGFloat = 280

    private var leftPanelWidth: CGFloat {
        guard let plugin = currentPlugin else { return 240 }
        return type(of: plugin).perTableOptionColumns.isEmpty ? 240 : 380
    }

    private var dialogWidth: CGFloat {
        isQueryResultsMode ? Self.optionsPanelWidth : leftPanelWidth + Self.optionsPanelWidth
    }

    // MARK: - Table Selection View

    private var tableSelectionView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Items")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                profileMenu

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
                    Text("Loading databases…")
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
                ExportObjectTreeView(
                    databaseItems: $databaseItems,
                    formatId: config.formatId,
                    loadColumns: { await columnNames(for: $0) }
                )
                .frame(minHeight: 300, maxHeight: .infinity)
            }
        }
    }

    /// Saves and reapplies a selection. A profile that names objects the database no longer holds
    /// says how many it still matches rather than quietly selecting fewer rows than its name
    /// implies.
    private var profileMenu: some View {
        Menu {
            if profiles.isEmpty {
                Text("No saved selections")
            }
            ForEach(profiles) { profile in
                Button {
                    applyProfile(profile)
                } label: {
                    Text(profileLabel(profile))
                }
            }
            Divider()
            Button("Save Selection…") { isNamingProfile = true }
                .disabled(selectedObjects.isEmpty)
            if !profiles.isEmpty {
                Menu("Delete") {
                    ForEach(profiles) { profile in
                        Button(profile.name) {
                            ExportProfileStorage.shared.delete(id: profile.id, for: connection.id)
                            profiles = ExportProfileStorage.shared.profiles(for: connection.id)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "bookmark")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(String(localized: "Saved selections"))
        .popover(isPresented: $isNamingProfile, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Name this selection")
                    .font(.headline)
                TextField("Nightly tables", text: $profileName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                HStack {
                    Spacer()
                    Button("Cancel") { isNamingProfile = false }
                    Button("Save") { saveProfile() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(14)
        }
    }

    private func profileLabel(_ profile: ExportProfile) -> String {
        let matched = ExportProfileStorage.matchCount(profile, in: databaseItems)
        guard matched < profile.entries.count else { return profile.name }
        return String(
            format: String(localized: "%1$@ (%2$lld of %3$lld still present)"),
            profile.name,
            Int64(matched),
            Int64(profile.entries.count)
        )
    }

    private func applyProfile(_ profile: ExportProfile) {
        config.formatId = profile.formatId
        databaseItems = normalizedForCurrentFormat(
            ExportProfileStorage.apply(profile, to: databaseItems))
    }

    private func saveProfile() {
        let trimmed = profileName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let profile = ExportProfileStorage.makeProfile(
            name: trimmed, formatId: config.formatId, databases: databaseItems)
        ExportProfileStorage.shared.save(profile, for: connection.id)
        profiles = ExportProfileStorage.shared.profiles(for: connection.id)
        profileName = ""
        isNamingProfile = false
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

                        Picker(String(localized: "Format"), selection: $config.formatId) {
                            ForEach(availableFormatIds, id: \.self) { formatId in
                                if let plugin = PluginManager.shared.exportPlugin(forFormat: formatId) {
                                    Text(type(of: plugin).formatDisplayName).tag(formatId)
                                }
                            }
                        }
                        .labelsHidden()

                        Spacer()
                    }

                    if let plugin = currentPlugin {
                        let description = ExportFormatCatalog.description(for: plugin)
                        if !description.isEmpty {
                            Text(description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                VStack(spacing: 2) {
                    if case .streamingQuery = mode {
                        Text("All rows")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if isQueryResultsMode {
                        Text("\(queryResultsRowCount) ^[row](inflect: true) to export")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(exportableCount) ^[table](inflect: true) to export")
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
                            .buttonStyle(.borderless)
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
        DialogFooter {
            if isExporting {
                ProgressView()
                    .scaleEffect(0.7)

                Text(exportService?.state.currentTable ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } actions: {
            Button("Cancel") {
                isPresented = false
            }
            .disabled(isExporting)

            Button("Export…") {
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

    private var selectedObjects: [ExportObjectItem] {
        databaseItems.flatMap { $0.selectedObjects }
    }

    private var exportableObjects: [ExportObjectItem] {
        let objects = selectedObjects
        guard let plugin = currentPlugin else { return objects }
        return objects.filter { plugin.isExportable(optionValues: $0.optionValues, kind: $0.kind) }
    }

    /// The kinds the chosen format can write, narrowed to the kinds a driver can actually list. A
    /// format that declares none of its own receives tables and views, which is what every format
    /// written before object scope expects.
    private var supportedObjectKinds: Set<PluginExportObjectKind> {
        guard let plugin = currentPlugin else { return [.table, .view] }
        return Set(type(of: plugin).supportedObjectKinds)
            .intersection(ExportObjectLoader.loadableKinds)
    }

    private var exportableCount: Int {
        exportableObjects.count
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

    /// A format change changes which object kinds can be written. Kinds the new format cannot
    /// write are dropped from the tree, and a format that reaches further than the last load did is
    /// what makes a reload worth its round trips.
    @MainActor
    private func reconcileObjectKindsForFormat() async {
        guard !isQueryResultsMode else { return }
        let wanted = supportedObjectKinds
        guard !loadedObjectKinds.isEmpty else { return }
        guard wanted.isSubset(of: loadedObjectKinds) else {
            await loadDatabaseItems()
            return
        }
        databaseItems = databaseItems.compactMap { database in
            var filtered = database
            filtered.objects = database.objects.filter { wanted.contains($0.kind) }
            return filtered.objects.isEmpty ? nil : filtered
        }
    }

    private func resetOptionValues() {
        databaseItems = normalizedForCurrentFormat(
            databaseItems.resettingOptionValues(to: currentDefaultOptionValues))
    }

    /// Aligns every row's option values with the chosen format's columns and clears the ones the
    /// row's kind does not support, so a routine never carries a `Data` flag that would count it as
    /// exportable for a phase it has no rows for.
    private func normalizedForCurrentFormat(_ items: [ExportDatabaseItem]) -> [ExportDatabaseItem] {
        let normalized = items.normalizingOptionValues(
            optionColumnCount: currentOptionColumnCount,
            defaultOptionValues: currentDefaultOptionValues
        )
        guard let plugin = currentPlugin else { return normalized }
        let pluginType = type(of: plugin)
        return normalized.maskingUnsupportedOptions(columns: pluginType.perTableOptionColumns) { columnId, kind in
            pluginType.supportsOption(columnId: columnId, for: kind)
        }
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
        reportExportFinished(.succeeded(OperationSummary(fileURL: exportedFileURL)))
    }

    /// Both export entry points converge here, so the completion is reported once whichever route
    /// ran. Cancellation is caught separately by each and deliberately reports nothing.
    private func reportExportFinished(_ outcome: OperationOutcome) {
        guard let startedAt = exportStartedAt else { return }
        exportStartedAt = nil
        OperationCompletionReporter.shared.report(
            OperationCompletion(
                kind: .dataExport,
                owner: .connection(connection.id),
                connectionId: connection.id,
                connectionName: connection.name,
                databaseName: exportScope?.database,
                elapsed: startedAt.duration(to: .now),
                outcome: outcome
            )
        )
    }

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
        let objectItems = sidebarTables.map { table in
            let kind = PluginExportObjectKind.from(tableType: table.type.rawValue)
            return ExportObjectItem(
                name: table.name,
                databaseName: "",
                kind: kind,
                isSelected: preselection.selects(
                    object: table.name,
                    kind: kind,
                    inContainer: .database(dbName),
                    isCurrentContainer: true
                )
            )
        }
        let item = ExportDatabaseItem(
            name: dbName.isEmpty ? "Tables" : dbName,
            objects: objectItems,
            isExpanded: true
        )
        databaseItems = normalizedForCurrentFormat([item])
        isLoading = false
    }

    private struct ExportRowSnapshot {
        let isSelected: Bool
        let optionValues: [Bool]
    }

    /// Keyed by kind too, so a routine and a table that share a name do not inherit each other's
    /// checkboxes when the format changes and the tree reloads.
    private func priorRowSnapshots() -> [String: ExportRowSnapshot] {
        var snapshots: [String: ExportRowSnapshot] = [:]
        for database in databaseItems {
            for object in database.objects {
                snapshots[Self.snapshotKey(container: database.name, object: object.name, kind: object.kind)] =
                    ExportRowSnapshot(isSelected: object.isSelected, optionValues: object.optionValues)
            }
        }
        return snapshots
    }

    private static func snapshotKey(container: String, object: String, kind: PluginExportObjectKind) -> String {
        "\(container).\(kind.rawValue).\(object)"
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
                    let loaded = await loadObjects(
                        containerName: schema,
                        schema: schema,
                        tables: tables,
                        includesPrincipals: isDefaultSchema
                    )
                    let objectItems = loaded.map { object in
                        restoring(
                            object,
                            priorRows: priorRows,
                            container: schema,
                            containerRef: .schema(database: exportDatabaseName, schema: schema),
                            isCurrentContainer: isDefaultSchema
                        )
                    }
                    if !objectItems.isEmpty {
                        items.append(ExportDatabaseItem(
                            name: schema,
                            objects: objectItems,
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
                    let loaded = await loadObjects(
                        containerName: dbName,
                        schema: isCurrentDB ? nil : dbName,
                        tables: tables,
                        includesPrincipals: isCurrentDB
                    )
                    let objectItems = loaded.map { object in
                        restoring(
                            object,
                            priorRows: priorRows,
                            container: dbName,
                            containerRef: .database(dbName),
                            isCurrentContainer: isCurrentDB
                        )
                    }
                    if !objectItems.isEmpty {
                        items.append(ExportDatabaseItem(
                            name: dbName,
                            objects: objectItems,
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

            loadedObjectKinds = supportedObjectKinds
            databaseItems = normalizedForCurrentFormat(items)
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
                window: hostWindow
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
        let loaded = await loadObjects(
            containerName: "", schema: nil, tables: tables, includesPrincipals: true)
        let objectItems = loaded.map { object in
            restoring(
                object,
                priorRows: priorRows,
                container: name,
                containerRef: .database(name),
                isCurrentContainer: true
            )
        }
        guard !objectItems.isEmpty else { return nil }
        return ExportDatabaseItem(name: name, objects: objectItems, isExpanded: true)
    }

    /// Reads one container's objects for the kinds the chosen format can write. Principals are
    /// server-wide, so only the container the dialog opened on offers them: listing them under
    /// every schema would offer the same GRANT statements several times over.
    private func loadObjects(
        containerName: String,
        schema: String?,
        tables: [TableInfo],
        includesPrincipals: Bool
    ) async -> [ExportObjectItem] {
        var kinds = supportedObjectKinds
        if !includesPrincipals { kinds.remove(.grant) }
        guard !kinds.isEmpty else { return [] }
        let request = ExportObjectLoader.Request(
            containerName: containerName, schema: schema, kinds: kinds)
        do {
            return try await withExportDriver { driver in
                await ExportObjectLoader.loadObjects(request: request, tables: tables, driver: driver)
            }
        } catch {
            Self.logger.warning("Failed to load export objects: \(error.localizedDescription)")
            return []
        }
    }

    /// The column names the row-scope popover offers. Read on demand, because a tree of forty
    /// tables would otherwise pay for forty column lists nobody opens.
    @MainActor
    private func columnNames(for object: ExportObjectItem) async -> [String] {
        guard object.kind.carriesRows else { return [] }
        do {
            return try await withExportDriver(workload: .interactive) { driver in
                guard let pluginDriver = (driver as? PluginDriverAdapter)?.schemaPluginDriver else { return [] }
                let schema = object.databaseName.isEmpty ? nil : object.databaseName
                return try await pluginDriver.fetchColumns(table: object.name, schema: schema).map(\.name)
            }
        } catch {
            Self.logger.warning("Failed to read columns for the export scope: \(error.localizedDescription)")
            return []
        }
    }

    /// Carries a row's checkboxes across a reload, falling back to what the preselection asked for.
    private func restoring(
        _ object: ExportObjectItem,
        priorRows: [String: ExportRowSnapshot],
        container: String,
        containerRef: DatabaseContainerRef,
        isCurrentContainer: Bool
    ) -> ExportObjectItem {
        let priorRow = priorRows[
            Self.snapshotKey(container: container, object: object.name, kind: object.kind)]
        return ExportObjectItem(
            name: object.name,
            databaseName: object.databaseName,
            kind: object.kind,
            identity: object.identity,
            parentTable: object.parentTable,
            isSelected: priorRow?.isSelected ?? preselection.selects(
                object: object.name,
                kind: object.kind,
                inContainer: containerRef,
                isCurrentContainer: isCurrentContainer
            ),
            optionValues: priorRow?.optionValues ?? []
        )
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
        guard let window = hostWindow else {
            Self.logger.warning("No host window captured, cannot present the file panel")
            return
        }

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
        savePanel.message = savePanelMessage(formatName: formatName)

        let response = await savePanel.presentAsSheet(for: window)
        guard response == .OK, let url = savePanel.url else { return }

        if isQueryResultsMode {
            await startQueryResultsExport(to: url)
        } else {
            await startExport(to: url)
        }
    }

    /// Counts pick between an explicit singular and plural key. Automatic grammar agreement is a
    /// SwiftUI `Text` facility: `String(localized:)` returns `^[table](inflect: true)` verbatim.
    private func savePanelMessage(formatName: String) -> String {
        if case .streamingQuery = mode {
            return String(format: String(localized: "Export query results to %@"), formatName)
        }
        let count = isQueryResultsMode ? queryResultsRowCount : exportableCount
        let template: String
        if isQueryResultsMode {
            template = count == 1
                ? String(localized: "Export %1$lld row to %2$@")
                : String(localized: "Export %1$lld rows to %2$@")
        } else {
            template = count == 1
                ? String(localized: "Export %1$lld table to %2$@")
                : String(localized: "Export %1$lld tables to %2$@")
        }
        return String(format: template, Int64(count), formatName)
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
        reportExportFinished(.failed(reason: error.localizedDescription))
        AlertHelper.showErrorSheet(
            title: String(localized: "Export Error"),
            message: error.localizedDescription,
            window: hostWindow
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
        exportStartedAt = .now
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

            if hideSuccessDialog, exportService?.state.warnings.isEmpty ?? true {
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
        try await service.export(objects: exportableObjects, config: config, to: url)
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
        exportStartedAt = .now
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
                let service = ExportService(
                    queryResultsDriver: DatabaseManager.shared.driver(for: connection.id),
                    databaseType: connection.type
                )
                exportService = service
                try await service.exportQueryResults(tableRows: tableRows, config: config, to: url)
            default:
                showProgressDialog = false
                isExporting = false
                exportStartedAt = nil
                return
            }

            showProgressDialog = false
            isExporting = false
            recordSuccessfulExport()

            if hideSuccessDialog, exportService?.state.warnings.isEmpty ?? true {
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
