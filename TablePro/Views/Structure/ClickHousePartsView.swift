//
//  ClickHousePartsView.swift
//  TablePro
//
//  Displays ClickHouse partition/part information from system.parts.
//

import os
import SwiftUI
import TableProPluginKit

struct ClickHousePartsView: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ClickHousePartsView")

    let tableName: String

    /// The tab's own scope, not the connection alone. ClickHouse switches database by writing one
    /// field on the shared driver and nothing puts it back, so a statement built from that driver
    /// names whichever database the sidebar last reached rather than the table on screen.
    let scope: DatabaseScope
    let connection: DatabaseConnection
    let reloadToken: Int

    @State private var parts: [ClickHousePartInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selection: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    RevealedTextView(error)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if parts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("No parts found")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                partsToolbar
                partsTable
            }
        }
        .task(id: reloadToken) { await loadParts() }
    }

    private var partsToolbar: some View {
        HStack(spacing: 8) {
            Button(action: optimizeTable) {
                Label(String(localized: "Optimize"), systemImage: "arrow.triangle.merge")
            }
            .help(String(localized: "Optimize table (merge parts)"))

            Button(action: dropSelectedPartition) {
                Label(String(localized: "Drop Partition"), systemImage: "trash")
            }
            .disabled(selection.count != 1)
            .help(String(localized: "Drop selected partition"))

            Button(action: detachSelectedPartition) {
                Label(String(localized: "Detach Partition"), systemImage: "arrow.down.doc")
            }
            .disabled(selection.count != 1)
            .help(String(localized: "Detach selected partition"))

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var partsTable: some View {
        Table(parts, selection: $selection) {
            TableColumn("Partition", value: \.partition)
                .width(min: 80, ideal: 120)
            TableColumn("Name", value: \.name)
                .width(min: 100, ideal: 200)
            TableColumn("Rows") { part in
                Text(formatNumber(part.rows))
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 100)
            TableColumn("Size") { part in
                Text(formatBytes(part.bytesOnDisk))
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 100)
            TableColumn("Modified", value: \.modificationTime)
                .width(min: 100, ideal: 160)
            TableColumn("Active") { part in
                Image(systemName: part.active ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(part.active ? .green : .secondary)
            }
            .width(min: 50, ideal: 60)
        }
    }

    // MARK: - Actions

    private func optimizeTable() {
        Task { @MainActor in
            guard let driver = DatabaseManager.shared.driver(for: scope.connectionId) else { return }
            await run(
                ClickHousePartStatements.optimize(
                    database: scope.database, table: tableName, quote: driver.quoteIdentifier
                ),
                description: String(localized: "Optimize Table"),
                kind: .maintenance
            )
        }
    }

    private func dropSelectedPartition() {
        guard let partitionValue = selectedPartitionValue() else { return }
        Task { @MainActor in
            let confirmed = await AlertHelper.confirmDestructive(
                title: String(localized: "Drop Partition?"),
                message: String(
                    format: String(localized: "This will permanently delete all data in partition '%@'."),
                    partitionValue
                ),
                confirmButton: String(localized: "Drop"),
                cancelButton: String(localized: "Cancel")
            )
            guard confirmed else { return }

            guard let driver = DatabaseManager.shared.driver(for: scope.connectionId) else { return }
            let sql = ClickHousePartStatements.dropPartition(
                database: scope.database,
                table: tableName,
                partition: partitionValue,
                quote: driver.quoteIdentifier,
                escape: driver.escapeStringLiteral
            )
            guard await run(sql, description: String(localized: "Drop Partition"), kind: .destructiveQuery)
            else { return }
            selection.removeAll()
        }
    }

    private func detachSelectedPartition() {
        guard let partitionValue = selectedPartitionValue() else { return }
        Task { @MainActor in
            let confirmed = await AlertHelper.confirmDestructive(
                title: String(localized: "Detach Partition?"),
                message: String(
                    format: String(localized: "This will detach partition '%@'. Data will be preserved but inaccessible until re-attached."),
                    partitionValue
                ),
                confirmButton: String(localized: "Detach"),
                cancelButton: String(localized: "Cancel")
            )
            guard confirmed else { return }

            guard let driver = DatabaseManager.shared.driver(for: scope.connectionId) else { return }
            let sql = ClickHousePartStatements.detachPartition(
                database: scope.database,
                table: tableName,
                partition: partitionValue,
                quote: driver.quoteIdentifier,
                escape: driver.escapeStringLiteral
            )
            guard await run(sql, description: String(localized: "Detach Partition"), kind: .destructiveQuery)
            else { return }
            selection.removeAll()
        }
    }

    /// Every statement here names the tab's own database and runs on a driver leased to it, and goes
    /// through the gate first: a partition drop is data loss, and a connection set to confirm those
    /// was dropping one on the strength of this view's own alert alone.
    /// Answers whether the statement actually ran. A denial, a cancelled confirmation or a failure
    /// leaves the partition where it was, so the caller keeps the user's selection rather than
    /// clearing it as though the action had gone through.
    @MainActor
    @discardableResult
    private func run(_ sql: String, description: String, kind: OperationKind) async -> Bool {
        let scope = scope
        do {
            let decision = await ExecutionGateProvider.shared.authorize(
                OperationRequest(
                    connectionId: scope.connectionId,
                    databaseType: connection.type,
                    sql: sql,
                    kind: kind,
                    caller: .userInterface,
                    capabilities: .interactiveUser,
                    operationDescription: description
                )
            )
            guard case .authorized = decision else {
                errorMessage = decision.deniedReason
                return false
            }
            _ = try await DatabaseManager.shared.withScopedDriver(
                scope: scope,
                route: DatabaseManager.shared.schemaChangeRoute(for: scope),
                cancellation: .protectedWrite
            ) { driver in
                try await driver.execute(query: sql)
            }
            await loadParts()
            return true
        } catch {
            Self.logger.error("\(description, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func selectedPartitionValue() -> String? {
        guard let selectedId = selection.first,
              let part = parts.first(where: { $0.id == selectedId })
        else { return nil }
        return part.partition
    }

    // MARK: - Data Loading

    private func loadParts() async {
        isLoading = true
        errorMessage = nil

        let scope = scope
        let tableName = tableName
        do {
            let result = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
                try await driver.execute(query: ClickHousePartStatements.parts(
                    database: scope.database, table: tableName, escape: driver.escapeStringLiteral
                ))
            }
            parts = result.rows.compactMap { row -> ClickHousePartInfo? in
                guard let name = row[safe: 1]?.asText else { return nil }
                let partition = row[safe: 0]?.asText ?? ""
                let rows = row[safe: 2]?.asText.flatMap { UInt64($0) } ?? 0
                let bytesOnDisk = row[safe: 3]?.asText.flatMap { UInt64($0) } ?? 0
                let modTime = row[safe: 4]?.asText ?? ""
                let active = row[safe: 5]?.asText == "1"
                return ClickHousePartInfo(
                    partition: partition,
                    name: name,
                    rows: rows,
                    bytesOnDisk: bytesOnDisk,
                    modificationTime: modTime,
                    active: active
                )
            }
        } catch {
            Self.logger.error("Failed to load parts: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Formatting

    private func formatNumber(_ number: UInt64) -> String {
        number.formatted(.number.grouping(.automatic))
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteSizeFormatting.string(bytes: bytes)
    }
}
