//
//  TableTransferSheet.swift
//  TablePro
//

import AppKit
import os
import SwiftUI
import TableProPluginKit

/// Copies rows from the open connection into another one, with no file in between.
///
/// Rows only: the destination table has to exist. Creating it would mean translating one engine's
/// DDL into another's, which is a different problem, and getting it half right would leave tables
/// whose column types quietly disagree with the data now in them.
struct TableTransferSheet: View {
    @ObservedObject private var databaseManager = DatabaseManager.shared
    private static let logger = Logger(subsystem: "com.TablePro", category: "TableTransferSheet")

    @Binding var isPresented: Bool
    let sourceConnection: DatabaseConnection
    let preselectedTables: Set<String>
    // Without it the sheet listed whichever schema the session was browsing and matched the bare names there.
    var preselectedSchema: String?
    var sheetWork: SheetWorkScope?

    @StateObject private var service = TableTransferService()
    @State private var destinationConnectionId: UUID?
    @State private var destinationDatabase = ""
    @State private var availableDestinations: [DatabaseConnection] = []
    @State private var destinationDatabases: [String] = []
    @State private var destinationSchemas: [String] = []
    @State private var destinationSchema = ""
    // Loads of the destination's databases and schemas still running: until they end, the scope is not known.
    @State private var resolvingDestination = 0
    @State private var sourceTables: [ExportObjectItem] = []
    @State private var deleteExistingRows = false
    @State private var wrapInTransaction = true
    @State private var isLoading = true
    @State private var isRunning = false
    @State private var errorMessage: String?
    @State private var hostWindow: NSWindow?

    /// Source and destination columns per table, plus the user's overrides, so the sheet can show
    /// what will map before anything is written.
    @State private var sourceColumns: [String: [String]] = [:]
    @State private var destinationColumns: [String: [String]] = [:]
    @State private var overrides: [String: [String: String?]] = [:]
    @State private var inspectedTable: String?
    @State private var isMatching = false

    private var destinationConnection: DatabaseConnection? {
        guard let destinationConnectionId else { return nil }
        return availableDestinations.first { $0.id == destinationConnectionId }
    }

    private var selectedTables: [ExportObjectItem] {
        sourceTables.filter(\.isSelected)
    }

    private var canTransfer: Bool {
        !isRunning && !selectedTables.isEmpty && destinationScope != nil && !hasContestedMapping
    }

    /// Two source columns mapped to one destination column build an INSERT naming it twice, which
    /// the server refuses only after "Delete existing rows first" has emptied the table.
    private var hasContestedMapping: Bool {
        selectedTables.contains { !resolvedMatch(for: $0.name).contestedDestinations.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if isLoading {
                loadingView
            } else {
                content
                    .disabled(isRunning)
            }

            Divider()

            footer
        }
        .frame(minWidth: 460, minHeight: 420, idealHeight: 460, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            WindowAccessor { window in hostWindow = window }
        }
        .task { await load() }
        .onExitCommand {
            guard !isRunning else { return }
            isPresented = false
        }
        .sheet(isPresented: $isRunning) {
            TransferProgressSheet(progress: transferProgress) { service.cancel() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Transfer Tables")
                .font(.headline)
            Text("Rows are copied into tables that already exist on the destination.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Destination", selection: $destinationConnectionId) {
                Text("Choose a connection").tag(UUID?.none)
                ForEach(availableDestinations) { connection in
                    Text(connection.name).tag(UUID?.some(connection.id))
                }
            }
            .onChange(of: destinationConnectionId) { _ in
                resolvingDestination += 1
                Task {
                    defer { resolvingDestination -= 1 }
                    await loadDestinationDatabases()
                    await loadDestinationSchemas()
                    await reloadDestinationColumns()
                }
            }

            if !destinationDatabases.isEmpty {
                Picker("Database", selection: Binding(
                    get: { destinationDatabase },
                    set: { database in
                        destinationDatabase = database
                        resolvingDestination += 1
                        Task {
                            defer { resolvingDestination -= 1 }
                            await loadDestinationSchemas()
                            await reloadDestinationColumns()
                        }
                    }
                )) {
                    ForEach(destinationDatabases, id: \.self) { database in
                        Text(database).tag(database)
                    }
                }
            }

            if !destinationSchemas.isEmpty {
                Picker("Schema", selection: Binding(
                    get: { destinationSchema },
                    set: { schema in
                        destinationSchema = schema
                        Task { await reloadDestinationColumns() }
                    }
                )) {
                    ForEach(destinationSchemas, id: \.self) { schema in
                        Text(schema).tag(schema)
                    }
                }
            }

            Text("Tables")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            List {
                ForEach(sourceTables) { table in
                    HStack(spacing: 6) {
                        Toggle(table.name, isOn: binding(for: table))
                            .toggleStyle(.checkbox)

                        Spacer(minLength: 4)

                        if table.isSelected {
                            mappingSummary(for: table.name)
                        }
                    }
                }
            }
            .listStyle(.bordered)
            .frame(maxHeight: .infinity)

            Toggle("Delete existing rows first", isOn: $deleteExistingRows)
                .toggleStyle(.checkbox)
            Toggle("Wrap each table in a transaction", isOn: $wrapInTransaction)
                .toggleStyle(.checkbox)

            if let errorMessage {
                Label {
                    RevealedTextView(errorMessage)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: NoticeSeverity.error.symbolName)
                        .foregroundStyle(NoticeSeverity.error.tint)
                        .accessibilityHidden(true)
                }
                .font(.subheadline)
            }
        }
        .padding(16)
    }

    private var footer: some View {
        DialogFooter {
            if hasContestedMapping {
                NoticeLabel(TableTransferMappingEditor.contestedMappingMessage, severity: .error)
                    .font(.caption)
                    .lineLimit(2)
            }
        } actions: {
            Button(String(localized: "Cancel")) {
                isPresented = false
            }
            .disabled(isRunning)

            Button("Transfer") {
                Task { await runTransfer() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canTransfer)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var transferProgress: TransferProgress {
        let state = service.state
        return TransferProgress(
            job: .tableTransfer(wrapsEachTable: wrapInTransaction),
            item: state.currentTable,
            step: TransferProgress.Step(index: state.currentTableIndex, count: state.totalTables),
            completed: Int64(state.transferredRows),
            unit: .rows
        )
    }

    // A table whose columns match nothing is called out here rather than failing on its first batch.
    @ViewBuilder
    private func mappingSummary(for table: String) -> some View {
        let match = resolvedMatch(for: table)
        let cannotTransfer = match.isEmpty || !match.contestedDestinations.isEmpty
        if isMatching, destinationColumns[table] == nil {
            ProgressView()
                .controlSize(.mini)
        } else if destinationColumns[table] == nil {
            NoticeLabel(String(localized: "No such table"), severity: .error)
                .font(.caption)
        } else {
            Button {
                inspectedTable = table
            } label: {
                HStack(spacing: 3) {
                    Text(mappingLabel(match))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if cannotTransfer {
                        Image(systemName: NoticeSeverity.error.symbolName)
                            .font(.caption)
                            .foregroundStyle(NoticeSeverity.error.tint)
                            .accessibilityHidden(true)
                    }
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.caption)
                }
            }
            .buttonStyle(.borderless)
            .popover(isPresented: Binding(
                get: { inspectedTable == table },
                set: { if !$0 { inspectedTable = nil } }
            )) {
                TableTransferMappingEditor(
                    tableName: table,
                    sourceColumns: sourceColumns[table] ?? [],
                    destinationColumns: destinationColumns[table] ?? [],
                    overrides: overrides[table] ?? [:],
                    onChange: { overrides[table] = $0 },
                    dismiss: { inspectedTable = nil }
                )
            }
        }
    }

    private func mappingLabel(_ match: TableColumnMatcher.Match) -> String {
        guard !match.isEmpty else { return String(localized: "No columns match") }
        let contested = match.contestedDestinations
        guard contested.isEmpty else {
            return String(
                format: String(localized: "%@ mapped more than once"),
                contested.joined(separator: ", "))
        }
        guard match.unmatchedSource.isEmpty else {
            return String(
                format: String(localized: "%1$lld mapped, %2$lld skipped"),
                Int64(match.mapping.count),
                Int64(match.unmatchedSource.count))
        }
        return String(format: String(localized: "%lld mapped"), Int64(match.mapping.count))
    }

    private func resolvedMatch(for table: String) -> TableColumnMatcher.Match {
        TableColumnMatcher.match(
            source: sourceColumns[table] ?? [],
            destination: destinationColumns[table] ?? [],
            overrides: overrides[table] ?? [:])
    }

    private func binding(for table: ExportObjectItem) -> Binding<Bool> {
        Binding(
            get: { sourceTables.first { $0.id == table.id }?.isSelected ?? false },
            set: { isOn in
                guard let index = sourceTables.firstIndex(where: { $0.id == table.id }) else { return }
                sourceTables[index].isSelected = isOn
                guard isOn else { return }
                Task { await loadColumnsForSelection(on: destinationScope) }
            }
        )
    }

    // MARK: - Loading

    /// A transfer needs two live sessions, so only connections that are already open are offered.
    /// Opening one from here would mean a connect, a possible prompt and a possible failure inside
    /// a sheet that is about to start writing rows. A read-only destination is left out rather than
    /// offered and then refused by the execution gate.
    @MainActor
    private func load() async {
        availableDestinations = databaseManager.activeSessions.values
            .filter { $0.id != sourceConnection.id && $0.effectiveStatus.isConnected }
            .map { $0.effectiveConnection ?? $0.connection }
            .filter { !$0.safeModeLevel.blocksAllWrites }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        do {
            let scope = sourceScope
            let tables = try await DatabaseManager.shared.withMetadataDriver(
                scope: scope, workload: .bulk
            ) { driver in
                try await driver.fetchTables(schema: scope.schema)
            }
            sourceTables = tables.filter { $0.type != .sequence }.map { table in
                ExportObjectItem(
                    name: table.name,
                    kind: PluginExportObjectKind.from(tableType: table.type.rawValue),
                    isSelected: preselectedTables.contains(table.name)
                )
            }
            .filter { $0.kind.carriesRows }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func loadDestinationDatabases() async {
        destinationDatabases = []
        destinationDatabase = ""
        guard let destinationConnection else { return }
        guard let driver = DatabaseManager.shared.driver(for: destinationConnection.id) else { return }
        do {
            destinationDatabases = try await driver.fetchDatabases()
            destinationDatabase = destinationDatabases.contains(destinationConnection.database)
                ? destinationConnection.database
                : (destinationDatabases.first ?? "")
        } catch {
            Self.logger.warning("Failed to list destination databases: \(error.localizedDescription)")
        }
    }

    // Without a schema the writes resolved to wherever the destination session was, often another table of that name.
    @MainActor
    private func loadDestinationSchemas() async {
        destinationSchemas = []
        destinationSchema = ""
        guard let destinationConnection,
              PluginManager.shared.supportsSchemaSwitching(for: destinationConnection.type) else { return }
        let database = destinationDatabase.isEmpty ? destinationConnection.database : destinationDatabase
        let scope = DatabaseScope(connectionId: destinationConnection.id, database: database, schema: nil)
        do {
            let schemas = try await DatabaseManager.shared.withMetadataDriver(
                scope: scope, workload: .interactive
            ) { driver in
                try await driver.fetchSchemas()
            }
            guard destinationConnectionId == scope.connectionId, destinationDatabaseName == database else { return }
            destinationSchemas = schemas
            destinationSchema = Self.defaultDestinationSchema(
                source: sourceScope.schema,
                current: DatabaseManager.shared.resolvedScope(
                    database: database, schema: nil, for: destinationConnection.id
                )?.schema,
                engineDefault: PluginManager.shared.defaultSchemaName(for: destinationConnection.type),
                available: schemas
            )
        } catch {
            Self.logger.warning("Failed to list destination schemas: \(error.localizedDescription)")
        }
    }

    // The source's own schema when the destination has one of that name, then where the destination is browsing.
    nonisolated static func defaultDestinationSchema(
        source: String?,
        current: String?,
        engineDefault: String?,
        available: [String]
    ) -> String {
        for candidate in [source, current, engineDefault] {
            if let candidate, available.contains(candidate) { return candidate }
        }
        return available.first ?? ""
    }

    @MainActor
    private func reloadDestinationColumns() async {
        destinationColumns = [:]
        await loadColumnsForSelection(on: Self.destinationScope(
            connection: destinationConnection,
            database: destinationDatabase,
            schema: destinationSchema,
            isResolving: false
        ))
    }

    private func transferTitle(destination: DatabaseConnection) -> String {
        let template = selectedTables.count == 1
            ? String(localized: "Transfer %1$lld table into %2$@?")
            : String(localized: "Transfer %1$lld tables into %2$@?")
        return String(format: template, Int64(selectedTables.count), destination.name)
    }

    /// Emptying the destination's tables cannot be undone, so it is confirmed here in words that say
    /// so. Every other confirmation a transfer needs is the execution gate's, from Safe Mode.
    @MainActor
    private func confirmDeletingExistingRows(destination: DatabaseConnection) async -> Bool {
        await AlertHelper.confirmCritical(
            title: transferTitle(destination: destination),
            message: String(localized: "Every row in each destination table is deleted first. This cannot be undone."),
            confirmButton: String(localized: "Transfer"),
            window: hostWindow
        )
    }

    /// Reads the columns on both sides for every ticked table, so the sheet can say what will map
    /// before anything is written. Only the ticked ones, because a database of four hundred tables
    /// would otherwise pay for four hundred column reads to open a sheet.
    @MainActor
    private func loadColumnsForSelection(on destinationScope: DatabaseScope?) async {
        let tables = selectedTables.map(\.name)
        guard !tables.isEmpty, let destinationConnection else { return }
        isMatching = true
        defer { isMatching = false }

        for table in tables where sourceColumns[table] == nil {
            sourceColumns[table] = await columns(of: table, on: sourceScope)
        }
        guard let destinationScope else { return }
        for table in tables where destinationColumns[table] == nil {
            let found = await columns(of: table, on: destinationScope)
            // A schema or database picked while this read ran owns the columns now.
            guard Self.destinationScope(
                connection: destinationConnection,
                database: destinationDatabase,
                schema: destinationSchema,
                isResolving: false
            ) == destinationScope else { return }
            destinationColumns[table] = found.isEmpty ? nil : found
        }
    }

    @MainActor
    private func columns(of table: String, on scope: DatabaseScope) async -> [String] {
        let schema = scope.schema
        do {
            return try await DatabaseManager.shared.withMetadataDriver(
                scope: scope, workload: .interactive
            ) { driver in
                guard let pluginDriver = driver.plugin else { return [] }
                return try await pluginDriver.fetchColumns(table: table, schema: schema).map(\.name)
            }
        } catch {
            Self.logger.warning("Failed to read source columns: \(error.localizedDescription)")
            return []
        }
    }

    /// An explicit schema wins over the session's current one in `resolvedScope`, which is what
    /// makes the sheet list the rows the user actually right-clicked.
    private var sourceScope: DatabaseScope {
        DatabaseManager.shared.resolvedScope(
            database: sourceConnection.database, schema: preselectedSchema, for: sourceConnection.id
        ) ?? DatabaseScope(
            connectionId: sourceConnection.id,
            database: sourceConnection.database,
            schema: preselectedSchema
        )
    }

    private var destinationScope: DatabaseScope? {
        Self.destinationScope(
            connection: destinationConnection,
            database: destinationDatabase,
            schema: destinationSchema,
            isResolving: resolvingDestination > 0
        )
    }

    private var destinationDatabaseName: String? {
        guard let destinationConnection else { return nil }
        return destinationDatabase.isEmpty ? destinationConnection.database : destinationDatabase
    }

    // The database and schema the user picked, not wherever the destination session was last parked. None while they
    // are still loading: a scope taken then named no schema, and the writes went to the session's own.
    nonisolated static func destinationScope(
        connection: DatabaseConnection?,
        database: String,
        schema: String,
        isResolving: Bool
    ) -> DatabaseScope? {
        guard let connection, !isResolving else { return nil }
        return DatabaseScope(
            connectionId: connection.id,
            database: database.isEmpty ? connection.database : database,
            schema: schema.isEmpty ? nil : schema
        )
    }

    // MARK: - Running

    @MainActor
    private func runTransfer() async {
        guard let destinationConnection, let destinationScope else {
            errorMessage = TableTransferError.notConnected(connectionName: "").localizedDescription
            return
        }
        if deleteExistingRows {
            guard await confirmDeletingExistingRows(destination: destinationConnection) else { return }
        }

        errorMessage = nil
        service.prepareForRun()
        isRunning = true
        let transferService = service
        let job = SheetJob(
            .tableTransfer,
            subject: destinationConnection.name,
            connectionName: sourceConnection.name,
            connectionIds: [sourceConnection.id, destinationConnection.id],
            scope: sheetWork,
            // Closing the destination's last window disconnects it, so that close has to list the transfer too.
            listedOnlyForItsWindow: false
        ) {
            transferService.cancel()
        }
        defer {
            isRunning = false
            job.end()
        }

        await loadColumnsForSelection(on: destinationScope)
        // The mapping is read from the scope this run writes to, or not at all.
        guard Self.destinationScope(
            connection: destinationConnection,
            database: destinationDatabase,
            schema: destinationSchema,
            isResolving: false
        ) == destinationScope else {
            errorMessage = String(localized: "The destination changed while the transfer started. Check it and transfer again.")
            return
        }

        var mappings: [String: [String: String]] = [:]
        var unmapped: [String] = []
        for table in selectedTables.map(\.name) {
            let match = resolvedMatch(for: table)
            guard !match.isEmpty else {
                unmapped.append(table)
                continue
            }
            mappings[table] = match.mapping
        }
        guard unmapped.isEmpty else {
            errorMessage = String(
                format: String(localized: "No column matches the destination for: %@"),
                unmapped.joined(separator: ", "))
            return
        }

        let request = TableTransferService.Request(
            objects: selectedTables,
            sourceType: sourceConnection.type,
            destinationType: destinationConnection.type,
            destinationSchema: destinationScope.schema,
            columnMapping: mappings,
            sourceColumns: sourceColumns,
            deleteExistingRows: deleteExistingRows,
            wrapInTransaction: wrapInTransaction
        )

        let startedAt = ContinuousClock.Instant.now
        do {
            try await service.run(
                request: request,
                source: sourceScope,
                destination: destinationScope,
                operationDescription: transferTitle(destination: destinationConnection),
                confirmedByCaller: deleteExistingRows
            )
            reportFinished(
                .succeeded(OperationSummary(rowsAffected: service.state.transferredRows)),
                destination: destinationConnection,
                since: startedAt)
            presentResult(destination: destinationConnection)
        } catch is PluginImportCancellationError {
            errorMessage = nil
            reportFinished(.cancelled, destination: destinationConnection, since: startedAt)
        } catch ExecutionGateError.cancelledByUser {
            errorMessage = nil
        } catch let refusal as ExecutionGateError {
            errorMessage = refusal.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
            reportFinished(
                .failed(reason: error.localizedDescription),
                destination: destinationConnection,
                since: startedAt)
        }
    }

    // Counted from the run, since the selection is the form's and could differ from what ran.
    @MainActor
    private func presentResult(destination: DatabaseConnection) {
        TransferResultAlert.presentTransferSuccess(
            tableCount: service.state.totalTables,
            rowCount: service.state.transferredRows,
            destinationName: destination.name,
            warnings: service.state.warnings,
            window: hostWindow
        ) {
            isPresented = false
        }
    }

    @MainActor
    private func reportFinished(
        _ outcome: OperationOutcome,
        destination: DatabaseConnection,
        since startedAt: ContinuousClock.Instant
    ) {
        OperationCompletionReporter.shared.report(
            OperationCompletion(
                kind: .dataImport,
                owner: .connection(destination.id),
                connectionId: destination.id,
                connectionName: destination.name,
                databaseName: destinationScope?.database,
                elapsed: startedAt.duration(to: .now),
                outcome: outcome
            )
        )
    }
}
