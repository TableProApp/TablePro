//
//  ServerSideExportSheet.swift
//  TablePro
//

import AppKit
import os
import SwiftUI
import TableProPluginKit

/// Asks the server to unload a table to somewhere the server can write.
///
/// Deliberately not the Backup Dump sheet. That one ends in a save panel and hands back a file on
/// this Mac; Oracle, Snowflake and BigQuery write to a directory object, a stage or a bucket and
/// give back nothing local. Sharing one command would mean a Save dialog whose file never appears.
struct ServerSideExportSheet: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ServerSideExport")

    @Binding var isPresented: Bool
    let connection: DatabaseConnection
    let initialTable: String?

    @State private var tables: [String] = []
    @State private var selectedTable = ""
    @State private var destinationText = ""
    @State private var format: ServerSideExport.Format = .csv
    @State private var isLoading = true
    @State private var isRunning = false
    @State private var errorMessage: String?
    @State private var completion: String?
    @State private var hostWindow: NSWindow?

    private var formats: [ServerSideExport.Format] {
        ServerSideExport.supportedFormats(for: connection.type)
    }

    private var destination: ServerSideExport.Destination? {
        let trimmed = destinationText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        switch connection.type {
        case .oracle: return .oracleDirectory(name: trimmed)
        case .bigQuery: return .googleCloudStorage(uri: trimmed)
        default:
            return connection.type == ServerSideExport.snowflake
                ? .snowflakeStage(name: trimmed)
                : nil
        }
    }

    private var destinationLabel: String {
        switch connection.type {
        case .oracle: return String(localized: "Directory object")
        case .bigQuery: return String(localized: "Cloud Storage URI")
        default:
            return connection.type == ServerSideExport.snowflake
                ? String(localized: "Stage")
                : String(localized: "Destination")
        }
    }

    private var destinationPrompt: String {
        switch connection.type {
        case .oracle: return "DATA_PUMP_DIR"
        case .bigQuery: return "gs://bucket/exports/"
        default: return connection.type == ServerSideExport.snowflake ? "@my_stage" : ""
        }
    }

    private var destinationHelp: String {
        switch connection.type {
        case .oracle:
            return String(localized: "The name of a DIRECTORY object, not a path. The DBA who created it chose where it points.")
        case .bigQuery:
            return String(localized: "A gs:// prefix. BigQuery shards its output, so several files are written under it.")
        default:
            guard connection.type == ServerSideExport.snowflake else { return "" }
            return String(localized: "An internal or external stage. The role you are connected as needs write access to it.")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Server-Side Export")
                    .font(.headline)
                Text("The server writes the file, so it lands where the server can reach, not on this Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            Divider()

            if isLoading {
                ProgressView().scaleEffect(0.8).frame(maxWidth: .infinity).padding(30)
            } else {
                form
            }

            Divider()

            footer
        }
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .background { WindowAccessor { window in hostWindow = window } }
        .task { await load() }
        .onExitCommand {
            guard !isRunning else { return }
            isPresented = false
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Table", selection: $selectedTable) {
                ForEach(tables, id: \.self) { table in
                    Text(table).tag(table)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(destinationLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField(destinationPrompt, text: $destinationText)
                    .textFieldStyle(.roundedBorder)
                Text(destinationHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if formats.count > 1 {
                Picker("Format", selection: $format) {
                    ForEach(formats) { option in
                        Text(option.label).tag(option)
                    }
                }
            }

            if let completion {
                Text(completion)
                    .font(.subheadline)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { isPresented = false }
                .disabled(isRunning)
            Spacer()
            if isRunning {
                ProgressView().scaleEffect(0.7)
            }
            Button("Export") {
                Task { await run() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isRunning || destination == nil || selectedTable.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @MainActor
    private func load() async {
        format = formats.first ?? .csv
        do {
            let found = try await DatabaseManager.shared.withMetadataDriver(
                scope: scope, workload: .bulk
            ) { driver in
                try await driver.fetchTables().map(\.name)
            }
            tables = found
            selectedTable = initialTable.flatMap { found.contains($0) ? $0 : nil } ?? found.first ?? ""
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private var scope: DatabaseScope {
        DatabaseManager.shared.resolvedScope(database: connection.database, schema: nil, for: connection.id)
            ?? DatabaseScope(connectionId: connection.id, database: connection.database, schema: nil)
    }

    /// The statement runs on the user's own connection, so it carries their privileges and the
    /// server's own error is what comes back when the destination is not writable.
    @MainActor
    private func run() async {
        guard let destination else { return }
        errorMessage = nil
        completion = nil
        isRunning = true
        defer { isRunning = false }

        guard let driver = DatabaseManager.shared.driver(for: connection.id) else {
            errorMessage = String(localized: "Not connected.")
            return
        }
        let request = ServerSideExport.Request(
            table: selectedTable,
            schema: DatabaseManager.shared.resolvedSchemaName(nil, for: connection.id),
            destination: destination,
            format: format
        )
        guard let statement = ServerSideExport.statement(
            for: request,
            databaseType: connection.type,
            quoteIdentifier: { driver.quoteIdentifier($0) },
            escapeLiteral: { driver.escapeStringLiteral($0) }
        ) else {
            errorMessage = String(localized: "That destination is not valid for this engine.")
            return
        }

        do {
            _ = try await driver.execute(query: statement)
            completion = String(
                format: String(localized: "The server wrote %1$@ to %2$@."),
                selectedTable,
                destinationText)
        } catch {
            Self.logger.warning("Server-side export failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }
}
