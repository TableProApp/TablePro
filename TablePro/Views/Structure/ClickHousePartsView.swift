//
//  ClickHousePartsView.swift
//  TablePro
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
    @State private var columnLayout = ColumnLayoutState()
    @State private var loadedToken: Int?
    @StateObject private var grid = StructureListGridModel<UUID>(accessibilityLabel: StructureTab.parts.displayName)
    @StateObject private var selection = StructureListSelection<UUID>()

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .gridStandInBackground()
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
                .gridStandInBackground()
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
                .gridStandInBackground()
            } else {
                partsToolbar
                partsTable
            }
        }
        .task(id: reloadToken) { await loadPartsIfNeeded() }
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
            .disabled(selection.ids.count != 1)
            .help(String(localized: "Drop selected partition"))

            Button(action: detachSelectedPartition) {
                Label(String(localized: "Detach Partition"), systemImage: "arrow.down.doc")
            }
            .disabled(selection.ids.count != 1)
            .help(String(localized: "Detach selected partition"))

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var partsTable: some View {
        let parts = parts
        let selection = selection
        var hasher = Hasher()
        for part in parts {
            hasher.combine(part.id)
        }
        return StructureListGrid(
            model: grid,
            columns: Self.columnTitles,
            defaultWidths: Self.columnWidths,
            minimumWidths: Self.columnMinimumWidths,
            contentKey: hasher.finalize(),
            rows: { parts.map(Self.gridRow(for:)) },
            databaseType: connection.type,
            selectedIDs: { selection.ids },
            select: { selection.ids = $0 },
            sortState: nil,
            columnLayout: $columnLayout
        )
    }

    internal static let columnWidths: [CGFloat] = [120, 200, 100, 100, 160, 60]
    internal static let columnMinimumWidths: [CGFloat] = [80, 100, 60, 60, 100, 50]
    internal static let activeColumn = 5

    static var columnTitles: [String] {
        [
            String(localized: "Partition"),
            String(localized: "Name"),
            String(localized: "Rows"),
            String(localized: "Size"),
            String(localized: "Modified"),
            String(localized: "Active"),
        ]
    }

    static func gridRow(for part: ClickHousePartInfo) -> StructureListRow<UUID> {
        StructureListRow(
            id: part.id,
            values: [
                part.partition,
                part.name,
                part.rows.formatted(.number.grouping(.automatic)),
                ByteSizeFormatting.string(bytes: part.bytesOnDisk),
                part.modificationTime,
                part.active ? "YES" : "NO",
            ],
            spokenValues: [activeColumn: part.active ? String(localized: "Active") : String(localized: "Inactive")]
        )
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
            selection.ids.removeAll()
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
            selection.ids.removeAll()
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
            if kind != .maintenance {
                CatalogChangeService.post(
                    .changed(CatalogChange(connectionId: scope.connectionId, database: scope.database, kinds: .tables))
                )
            }
            await loadParts()
            return true
        } catch {
            Self.logger.error("\(description, privacy: .public) failed: \(error.publicLogShape, privacy: .public)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func selectedPartitionValue() -> String? {
        Self.partition(of: selection.ids, in: parts)
    }

    internal static func partition(of selectedIDs: Set<UUID>, in parts: [ClickHousePartInfo]) -> String? {
        guard selectedIDs.count == 1,
              let selectedId = selectedIDs.first,
              let part = parts.first(where: { $0.id == selectedId })
        else { return nil }
        return part.partition
    }

    // MARK: - Data Loading

    /// A connection switch re-parents the pane and SwiftUI re-runs `task(id:)` with the same token,
    /// so only a new token, which Refresh issues, fetches the parts again.
    private func loadPartsIfNeeded() async {
        guard loadedToken != reloadToken else { return }
        await loadParts()
    }

    /// A cancelled load commits nothing and records no token, so the next appearance retries it.
    private func loadParts() async {
        let token = reloadToken
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
            guard !Task.isCancelled else { return }
            selection.ids = []
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
            loadedToken = token
        } catch {
            guard !Task.isCancelled else { return }
            Self.logger.error("Failed to load parts: \(error.publicLogShape, privacy: .public)")
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
