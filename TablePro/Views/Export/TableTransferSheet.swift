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
    private static let logger = Logger(subsystem: "com.TablePro", category: "TableTransferSheet")

    @Binding var isPresented: Bool
    let sourceConnection: DatabaseConnection
    let preselectedTables: Set<String>

    @State private var service = TableTransferService()
    @State private var destinationConnectionId: UUID?
    @State private var destinationDatabase = ""
    @State private var availableDestinations: [DatabaseConnection] = []
    @State private var destinationDatabases: [String] = []
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
        !isRunning && !selectedTables.isEmpty && destinationConnection != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if isLoading {
                loadingView
            } else {
                content
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
                .scaleEffect(0.8)
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
            .onChange(of: destinationConnectionId) {
                Task {
                    await loadDestinationDatabases()
                    await loadColumnsForSelection()
                }
            }

            if !destinationDatabases.isEmpty {
                Picker("Database", selection: $destinationDatabase) {
                    ForEach(destinationDatabases, id: \.self) { database in
                        Text(database).tag(database)
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
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
    }

    private var footer: some View {
        DialogFooter {
            if isRunning {
                ProgressView()
                    .scaleEffect(0.7)
                Text(progressLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } actions: {
            Button(isRunning ? String(localized: "Stop") : String(localized: "Cancel")) {
                if isRunning {
                    service.cancel()
                } else {
                    isPresented = false
                }
            }

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

    private var progressLabel: String {
        String(
            format: String(localized: "%1$@ (%2$lld of %3$lld), %4$lld rows"),
            service.state.currentTable,
            Int64(service.state.currentTableIndex),
            Int64(service.state.totalTables),
            Int64(service.state.transferredRows)
        )
    }

    /// Says how a table will map before anything is written, and opens the editor. A table whose
    /// columns match nothing is called out here rather than failing on its first batch.
    @ViewBuilder
    private func mappingSummary(for table: String) -> some View {
        let match = resolvedMatch(for: table)
        if isMatching, destinationColumns[table] == nil {
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 16)
        } else if destinationColumns[table] == nil {
            Text("No such table")
                .font(.caption)
                .foregroundStyle(.red)
        } else {
            Button {
                inspectedTable = table
            } label: {
                HStack(spacing: 3) {
                    Text(mappingLabel(match))
                        .font(.caption)
                        .foregroundStyle(match.isEmpty ? Color.red : .secondary)
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
                    overrides: Binding(
                        get: { overrides[table] ?? [:] },
                        set: { overrides[table] = $0 }
                    ),
                    dismiss: { inspectedTable = nil }
                )
            }
        }
    }

    private func mappingLabel(_ match: TableColumnMatcher.Match) -> String {
        guard !match.isEmpty else { return String(localized: "No columns match") }
        guard match.unmatchedSource.isEmpty else {
            return String(
                format: String(localized: "%1$lld mapped, %2$lld skipped"),
                Int64(match.mapping.count),
                Int64(match.unmatchedSource.count))
        }
        return String(format: String(localized: "%lld mapped"), Int64(match.mapping.count))
    }

    private func resolvedMatch(for table: String) -> TableColumnMatcher.Match {
        let destination = destinationColumns[table] ?? []
        let automatic = TableColumnMatcher.match(
            source: sourceColumns[table] ?? [], destination: destination)
        guard let tableOverrides = overrides[table], !tableOverrides.isEmpty else { return automatic }
        return TableColumnMatcher.applying(
            overrides: tableOverrides, to: automatic, destination: destination)
    }

    private func binding(for table: ExportObjectItem) -> Binding<Bool> {
        Binding(
            get: { sourceTables.first { $0.id == table.id }?.isSelected ?? false },
            set: { isOn in
                guard let index = sourceTables.firstIndex(where: { $0.id == table.id }) else { return }
                sourceTables[index].isSelected = isOn
                guard isOn else { return }
                Task { await loadColumnsForSelection() }
            }
        )
    }

    // MARK: - Loading

    /// A transfer needs two live sessions, so only connections that are already open are offered.
    /// Opening one from here would mean a connect, a possible prompt and a possible failure inside
    /// a sheet that is about to start writing rows.
    ///
    /// A read-only destination is left out rather than shown and refused later: this sheet writes
    /// rows through the import sink, which reaches the driver directly rather than through the
    /// execution gate, so the list is where that policy has to hold.
    @MainActor
    private func load() async {
        availableDestinations = DatabaseManager.shared.activeSessions.values
            .filter { $0.id != sourceConnection.id && $0.isConnected }
            .map { $0.effectiveConnection ?? $0.connection }
            .filter { !$0.safeModeLevel.blocksAllWrites }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        do {
            let tables = try await DatabaseManager.shared.withMetadataDriver(
                scope: sourceScope, workload: .bulk
            ) { driver in
                try await driver.fetchTables()
            }
            sourceTables = tables.map { table in
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

    /// Emptying the destination's tables is not undoable, and a connection whose Safe Mode asks
    /// before a write has to be asked here too, because these rows never pass the execution gate.
    @MainActor
    private func confirmIfNeeded(destination: DatabaseConnection) async -> Bool {
        guard deleteExistingRows || destination.safeModeLevel.requiresConfirmation else { return true }
        let template = selectedTables.count == 1
            ? String(localized: "Transfer %1$lld table into %2$@?")
            : String(localized: "Transfer %1$lld tables into %2$@?")
        let title = String(format: template, Int64(selectedTables.count), destination.name)
        guard deleteExistingRows else {
            return await AlertHelper.confirm(
                title: title,
                message: String(localized: "Rows are written into tables that already exist on the destination."),
                confirmButton: String(localized: "Transfer"),
                window: hostWindow
            )
        }
        return await AlertHelper.confirmCritical(
            title: title,
            message: String(localized: "Every row in each destination table is deleted first. This cannot be undone."),
            confirmButton: String(localized: "Transfer"),
            window: hostWindow
        )
    }

    /// Reads the columns on both sides for every ticked table, so the sheet can say what will map
    /// before anything is written. Only the ticked ones, because a database of four hundred tables
    /// would otherwise pay for four hundred column reads to open a sheet.
    @MainActor
    private func loadColumnsForSelection() async {
        let tables = selectedTables.map(\.name)
        guard !tables.isEmpty, let destinationConnection else { return }
        isMatching = true
        defer { isMatching = false }

        for table in tables where sourceColumns[table] == nil {
            sourceColumns[table] = await columns(
                of: table, on: sourceScope, schema: nil)
        }
        guard let destinationScope else { return }
        for table in tables where destinationColumns[table] == nil {
            let found = await columns(of: table, on: destinationScope, schema: nil)
            destinationColumns[table] = found.isEmpty ? nil : found
        }
    }

    @MainActor
    private func columns(of table: String, on scope: DatabaseScope, schema: String?) async -> [String] {
        do {
            return try await DatabaseManager.shared.withMetadataDriver(
                scope: scope, workload: .interactive
            ) { driver in
                guard let pluginDriver = (driver as? PluginDriverAdapter)?.schemaPluginDriver else { return [] }
                return try await pluginDriver.fetchColumns(table: table, schema: schema).map(\.name)
            }
        } catch {
            Self.logger.warning("Failed to read source columns: \(error.localizedDescription)")
            return []
        }
    }

    private var sourceScope: DatabaseScope {
        DatabaseManager.shared.resolvedScope(
            database: sourceConnection.database, schema: nil, for: sourceConnection.id
        ) ?? DatabaseScope(connectionId: sourceConnection.id, database: sourceConnection.database, schema: nil)
    }

    /// The database the user picked, not wherever the destination connection was last parked. Both
    /// the column read and the write go through this: the picker used to bind to a value nothing
    /// read, so choosing a database changed the label and sent the rows somewhere else.
    private var destinationScope: DatabaseScope? {
        guard let destinationConnection else { return nil }
        let database = destinationDatabase.isEmpty
            ? destinationConnection.database
            : destinationDatabase
        return DatabaseScope(
            connectionId: destinationConnection.id, database: database, schema: nil)
    }

    // MARK: - Running

    @MainActor
    private func runTransfer() async {
        guard let destinationConnection, let destinationScope else {
            errorMessage = TableTransferError.notConnected(connectionName: "").localizedDescription
            return
        }
        guard !destinationConnection.safeModeLevel.blocksAllWrites else {
            errorMessage = String(
                format: String(localized: "%@ is read-only, so nothing can be written to it."),
                destinationConnection.name)
            return
        }
        guard await confirmIfNeeded(destination: destinationConnection) else { return }

        errorMessage = nil
        service.prepareForRun()
        isRunning = true
        defer { isRunning = false }

        await loadColumnsForSelection()

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
            columnMapping: mappings,
            sourceColumns: sourceColumns,
            deleteExistingRows: deleteExistingRows,
            wrapInTransaction: wrapInTransaction
        )

        let startedAt = ContinuousClock.Instant.now
        let destinationRoute = DatabaseManager.shared.executionRoute(for: destinationScope)
        do {
            try await DatabaseManager.shared.withMetadataDriver(
                scope: sourceScope, workload: .bulk
            ) { sourceDriver in
                try await DatabaseManager.shared.withScopedDriver(
                    scope: destinationScope,
                    route: destinationRoute,
                    workload: .bulk,
                    cancellation: .untracked
                ) { destinationDriver in
                    try await service.transfer(
                        request: request,
                        sourceDriver: sourceDriver,
                        destinationDriver: destinationDriver
                    )
                }
            }
            reportFinished(
                .succeeded(OperationSummary(rowsAffected: service.state.transferredRows)),
                destination: destinationConnection,
                since: startedAt)
            presentResult(destination: destinationConnection)
        } catch is PluginImportCancellationError {
            errorMessage = nil
            reportFinished(.cancelled, destination: destinationConnection, since: startedAt)
        } catch {
            errorMessage = error.localizedDescription
            reportFinished(
                .failed(reason: error.localizedDescription),
                destination: destinationConnection,
                since: startedAt)
        }
    }

    /// A transfer that finished used to close its sheet and say nothing, so a run that skipped rows
    /// looked identical to a clean one. The alert closes the sheet once the user has read it.
    @MainActor
    private func presentResult(destination: DatabaseConnection) {
        TransferResultAlert.presentTransferSuccess(
            tableCount: selectedTables.count,
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
