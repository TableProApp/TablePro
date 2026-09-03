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
        .frame(width: 460, height: 460)
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
                Task { await loadDestinationDatabases() }
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
                    Toggle(table.name, isOn: binding(for: table))
                        .toggleStyle(.checkbox)
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
        HStack {
            Button("Cancel") {
                if isRunning {
                    service.cancel()
                } else {
                    isPresented = false
                }
            }

            Spacer()

            if isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text(progressLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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

    private func binding(for table: ExportObjectItem) -> Binding<Bool> {
        Binding(
            get: { sourceTables.first { $0.id == table.id }?.isSelected ?? false },
            set: { isOn in
                guard let index = sourceTables.firstIndex(where: { $0.id == table.id }) else { return }
                sourceTables[index].isSelected = isOn
            }
        )
    }

    // MARK: - Loading

    /// A transfer needs two live sessions, so only connections that are already open are offered.
    /// Opening one from here would mean a connect, a possible prompt and a possible failure inside
    /// a sheet that is about to start writing rows.
    @MainActor
    private func load() async {
        availableDestinations = DatabaseManager.shared.activeSessions.values
            .filter { $0.id != sourceConnection.id && $0.isConnected }
            .map { $0.effectiveConnection ?? $0.connection }
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

    private var sourceScope: DatabaseScope {
        DatabaseManager.shared.resolvedScope(
            database: sourceConnection.database, schema: nil, for: sourceConnection.id
        ) ?? DatabaseScope(connectionId: sourceConnection.id, database: sourceConnection.database, schema: nil)
    }

    // MARK: - Running

    @MainActor
    private func runTransfer() async {
        guard let destinationConnection,
              let destinationDriver = DatabaseManager.shared.driver(for: destinationConnection.id) else {
            errorMessage = TableTransferError.notConnected(connectionName: "").localizedDescription
            return
        }
        errorMessage = nil
        isRunning = true
        defer { isRunning = false }

        let request = TableTransferService.Request(
            objects: selectedTables,
            sourceType: sourceConnection.type,
            destinationType: destinationConnection.type,
            deleteExistingRows: deleteExistingRows,
            wrapInTransaction: wrapInTransaction
        )

        do {
            try await DatabaseManager.shared.withMetadataDriver(
                scope: sourceScope, workload: .bulk
            ) { sourceDriver in
                try await service.transfer(
                    request: request,
                    sourceDriver: sourceDriver,
                    destinationDriver: destinationDriver
                )
            }
            isPresented = false
        } catch is PluginImportCancellationError {
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
