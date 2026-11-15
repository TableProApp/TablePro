//
//  StoragePartsView.swift
//  TablePro
//

import os
import SwiftUI
import TableProPluginKit
import TableProSQLGrammar

internal struct StoragePartsAlert: Equatable {
    let title: String
    let message: String
}

// A failed or refused action never replaces the list it acted on; only a load with nothing shown does.
internal struct StoragePartsPaneState {
    internal enum Display: Equatable {
        case loading
        case loadFailed(String)
        case empty
        case parts
    }

    private(set) var parts: [PluginStoragePart] = []
    private(set) var isLoading = true
    private(set) var loadError: String?
    var alert: StoragePartsAlert?

    var display: Display {
        guard parts.isEmpty else { return .parts }
        if let loadError { return .loadFailed(loadError) }
        return isLoading ? .loading : .empty
    }

    mutating func beginLoad() {
        isLoading = true
        loadError = nil
    }

    mutating func finishLoad(_ parts: [PluginStoragePart]) {
        self.parts = parts
        isLoading = false
    }

    mutating func failLoad(_ message: String) {
        isLoading = false
        guard parts.isEmpty else {
            alert = StoragePartsAlert(title: String(localized: "Couldn't Read the Parts"), message: message)
            return
        }
        loadError = message
    }

    mutating func actionEnded(_ failure: GatedOperationFailure, title: String) {
        guard let message = failure.message else { return }
        alert = StoragePartsAlert(title: title, message: message)
    }
}

struct StoragePartsView: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "StoragePartsView")

    let tableName: String

    let scope: DatabaseScope
    let connection: DatabaseConnection
    let reloadToken: Int

    @State private var pane = StoragePartsPaneState()
    @State private var loadedToken: Int?
    @StateObject private var grid = StructureListGridModel<String>(accessibilityLabel: StructurePane.parts.displayName)
    @StateObject private var selection = StructureListSelection<String>()

    var body: some View {
        VStack(spacing: 0) {
            switch pane.display {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .gridStandInBackground()
            case .loadFailed(let message):
                UnavailableStateView {
                    Label(String(localized: "Couldn't Read the Parts"), systemImage: "exclamationmark.triangle")
                } description: {
                    RevealedTextView(message)
                } actions: {
                    Button(String(localized: "Try Again")) {
                        Task { await loadParts() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .gridStandInBackground()
            case .empty:
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
            case .parts:
                partsToolbar
                partsTable
            }
        }
        .alert(
            pane.alert?.title ?? "",
            isPresented: Binding(get: { pane.alert != nil }, set: { if !$0 { pane.alert = nil } }),
            presenting: pane.alert
        ) { _ in
            Button(String(localized: "OK"), role: .cancel) {}
        } message: { alert in
            Text(verbatim: RevealedText(alert.message).plainText)
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
        let selection = selection
        return StructureListGrid(
            model: grid,
            columns: Self.columnTitles,
            defaultWidths: Self.columnWidths,
            minimumWidths: Self.columnMinimumWidths,
            rows: pane.parts.map(Self.gridRow(for:)),
            databaseType: connection.type,
            selectedIDs: selection.ids,
            select: { selection.ids = $0 },
            sortState: nil
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

    // A part's name is unique within its table, active or not.
    static func gridRow(for part: PluginStoragePart) -> StructureListRow<String> {
        StructureListRow(
            id: part.name,
            values: [
                part.partition,
                part.name,
                part.rows.formatted(.number.grouping(.automatic)),
                ByteSizeFormatting.string(bytes: part.bytesOnDisk),
                part.modificationTime,
                part.isActive ? "YES" : "NO",
            ],
            spokenValues: [activeColumn: part.isActive ? String(localized: "Active") : String(localized: "Inactive")]
        )
    }

    // MARK: - Actions

    private var storageParts: (any PluginStorageParts)? {
        DatabaseManager.shared.driver(for: scope.connectionId)?.plugin as? any PluginStorageParts
    }

    private func optimizeTable() {
        Task { @MainActor in
            guard let sql = storageParts?.mergePartsStatement(table: tableName, database: scope.database) else { return }
            await run(
                sql,
                description: String(localized: "Optimize Table"),
                failureTitle: String(localized: "Couldn't Optimize Table"),
                kind: .maintenance
            )
        }
    }

    private func dropSelectedPartition() {
        guard let part = selectedPart() else { return }
        Task { @MainActor in
            let confirmed = await AlertHelper.confirmDestructive(
                title: String(localized: "Drop Partition?"),
                message: String(
                    format: String(localized: "This will permanently delete all data in partition '%@'."),
                    part.partition
                ),
                confirmButton: String(localized: "Drop"),
                cancelButton: String(localized: "Cancel")
            )
            guard confirmed else { return }

            guard let storageParts else { return }
            let failureTitle = String(localized: "Couldn't Drop Partition")
            guard let sql = storageParts.dropPartitionStatement(
                table: tableName, database: scope.database, partitionId: part.partitionId
            ) else {
                pane.alert = StoragePartsAlert(title: failureTitle, message: Self.unusablePartitionIdMessage)
                return
            }
            guard await run(
                sql, description: String(localized: "Drop Partition"), failureTitle: failureTitle, kind: .destructiveQuery
            ) else { return }
            selection.ids.removeAll()
        }
    }

    private func detachSelectedPartition() {
        guard let part = selectedPart() else { return }
        Task { @MainActor in
            let confirmed = await AlertHelper.confirmDestructive(
                title: String(localized: "Detach Partition?"),
                message: String(
                    format: String(localized: "This will detach partition '%@'. Data will be preserved but inaccessible until re-attached."),
                    part.partition
                ),
                confirmButton: String(localized: "Detach"),
                cancelButton: String(localized: "Cancel")
            )
            guard confirmed else { return }

            guard let storageParts else { return }
            let failureTitle = String(localized: "Couldn't Detach Partition")
            guard let sql = storageParts.detachPartitionStatement(
                table: tableName, database: scope.database, partitionId: part.partitionId
            ) else {
                pane.alert = StoragePartsAlert(title: failureTitle, message: Self.unusablePartitionIdMessage)
                return
            }
            guard await run(
                sql, description: String(localized: "Detach Partition"), failureTitle: failureTitle, kind: .destructiveQuery
            ) else { return }
            selection.ids.removeAll()
        }
    }

    private static var unusablePartitionIdMessage: String {
        String(localized: "The server reported a partition ID that cannot be used in a statement, so nothing was run.")
    }

    @MainActor
    @discardableResult
    private func run(_ sql: String, description: String, failureTitle: String, kind: OperationKind) async -> Bool {
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
            if let denial = decision.denialError { throw denial }
            _ = try await DatabaseManager.shared.withScopedDriver(
                scope: scope,
                route: DatabaseManager.shared.schemaChangeRoute(for: scope),
                cancellation: .protectedWrite
            ) { driver in
                try await driver.execute(query: sql)
            }
        } catch {
            let failure = GatedOperationFailure(error)
            if failure.reportsFailure {
                Self.logger.error("\(description, privacy: .public) failed: \(error.publicLogShape, privacy: .public)")
            }
            pane.actionEnded(failure, title: failureTitle)
            return false
        }
        if kind != .maintenance {
            CatalogChangeService.post(
                .changed(CatalogChange(connectionId: scope.connectionId, database: scope.database, kinds: .tables))
            )
        }
        await loadParts()
        return true
    }

    private func selectedPart() -> PluginStoragePart? {
        Self.selectedPart(of: selection.ids, in: pane.parts)
    }

    internal static func selectedPart(of selectedIDs: Set<String>, in parts: [PluginStoragePart]) -> PluginStoragePart? {
        guard selectedIDs.count == 1, let selectedId = selectedIDs.first else { return nil }
        return parts.first { $0.name == selectedId }
    }

    // MARK: - Data Loading

    private func loadPartsIfNeeded() async {
        guard loadedToken != reloadToken else { return }
        await loadParts()
    }

    private func loadParts() async {
        let token = reloadToken
        pane.beginLoad()

        let scope = scope
        let tableName = tableName
        do {
            let parts = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
                guard let storageParts = driver.plugin as? any PluginStorageParts else {
                    throw DatabaseError.unsupportedOperation
                }
                return try await storageParts.fetchStorageParts(table: tableName, database: scope.database)
            }
            guard !Task.isCancelled else { return }
            selection.ids = []
            pane.finishLoad(parts)
            loadedToken = token
        } catch {
            guard !Task.isCancelled else { return }
            Self.logger.error("Failed to load parts: \(error.publicLogShape, privacy: .public)")
            pane.failLoad(error.localizedDescription)
        }
    }
}
