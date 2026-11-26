//
//  ExportService.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProPluginKit

// MARK: - Export Error

enum ExportError: LocalizedError {
    case notConnected
    case noTablesSelected
    case exportFailed(String)
    case compressionFailed
    case fileWriteFailed(String)
    case encodingFailed
    case formatNotFound(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Not connected to database")
        case .noTablesSelected:
            return String(localized: "No tables selected for export")
        case .exportFailed(let message):
            return String(format: String(localized: "Export failed: %@"), message)
        case .compressionFailed:
            return String(localized: "Failed to compress data")
        case .fileWriteFailed(let path):
            return String(format: String(localized: "Failed to write file: %@"), path)
        case .encodingFailed:
            return String(localized: "Failed to encode content as UTF-8")
        case .formatNotFound(let formatId):
            return String(format: String(localized: "Export format '%@' not found"), formatId)
        }
    }
}

// MARK: - Export State

struct ExportState {
    var isExporting: Bool = false
    var currentTable: String = ""
    var currentTableIndex: Int = 0
    var totalTables: Int = 0
    var processedRows: Int = 0
    var totalRows: Int = 0
    var statusMessage: String = ""
    var errorMessage: String?
    var warnings: [String] = []

    // False for an export that writes no rows, which then reports its progress in objects.
    var readsRows = true

    // Set when the row total came from the catalog's statistics.
    var rowTotalIsEstimate = false

    /// What the export wrote, as opposed to what went wrong with it. Kept apart from `warnings`
    /// because the success alert reads a non-empty `warnings` as a problem: it retitles itself,
    /// takes the caution icon, and drops its "Do not show this again" checkbox.
    var notes: [String] = []
}

// MARK: - Export Service

@MainActor
final class ExportService: ObservableObject {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ExportService")

    @Published var state = ExportState()

    private let driver: DatabaseDriver?
    private let databaseType: DatabaseType?
    private let effectiveQueryTimeoutSeconds: Int
    private let exportPlugin: @MainActor (String) -> (any ExportFormatPlugin)?
    var executionGate: any ExecutionGate = ExecutionGateProvider.shared

    init(
        driver: DatabaseDriver,
        databaseType: DatabaseType,
        exportPlugin: @escaping @MainActor (String) -> (any ExportFormatPlugin)? = ExportService.installedExportPlugin
    ) {
        self.driver = driver
        self.databaseType = databaseType
        self.effectiveQueryTimeoutSeconds = driver.sessionQueryTimeoutSeconds
            ?? ConnectionTimeoutPolicy.effectiveQueryTimeoutSeconds(
                configuredSeconds: driver.connection.queryTimeoutSeconds,
                globalSeconds: AppSettingsManager.shared.general.queryTimeoutSeconds
            )
        self.exportPlugin = exportPlugin
    }

    /// Rows already in memory still need the engine that produced them: a SQL export has to quote
    /// identifiers and escape literals the way that engine reads them back. The driver is asked for
    /// nothing but those two pure functions here, so an installed handle is enough and no lease is
    /// taken. It is optional only because a connection can be gone by the time the sheet runs, and
    /// the formats that carry no SQL still export fine without one.
    init(queryResultsDriver driver: DatabaseDriver?, databaseType: DatabaseType) {
        self.driver = driver
        self.databaseType = databaseType
        self.effectiveQueryTimeoutSeconds = driver.map { driver in
            driver.sessionQueryTimeoutSeconds
                ?? ConnectionTimeoutPolicy.effectiveQueryTimeoutSeconds(
                    configuredSeconds: driver.connection.queryTimeoutSeconds,
                    globalSeconds: AppSettingsManager.shared.general.queryTimeoutSeconds
                )
        } ?? Self.effectiveGlobalQueryTimeoutSeconds
        self.exportPlugin = Self.installedExportPlugin
    }

    init(exportPlugin: @escaping @MainActor (String) -> (any ExportFormatPlugin)? = ExportService.installedExportPlugin) {
        self.driver = nil
        self.databaseType = nil
        self.effectiveQueryTimeoutSeconds = Self.effectiveGlobalQueryTimeoutSeconds
        self.exportPlugin = exportPlugin
    }

    private static var effectiveGlobalQueryTimeoutSeconds: Int {
        ConnectionTimeoutPolicy.effectiveQueryTimeoutSeconds(
            configuredSeconds: nil,
            globalSeconds: AppSettingsManager.shared.general.queryTimeoutSeconds
        )
    }

    static func installedExportPlugin(forFormat formatId: String) -> (any ExportFormatPlugin)? {
        PluginManager.shared.exportPlugin(forFormat: formatId)
    }

    /// The one table a query export writes. `QueryExportOptions` says why it carries no structure.
    private static func queryResultExportTable(
        named name: String,
        plugin: any ExportFormatPlugin
    ) -> PluginExportTable {
        let optionValues = QueryExportOptions.dataOnly(
            columns: type(of: plugin).perTableOptionColumns,
            defaults: plugin.defaultTableOptionValues()
        )
        return PluginExportTable(
            name: name,
            databaseName: "",
            tableType: "query",
            optionValues: optionValues,
            schema: nil,
            kind: .table
        )
    }

    // MARK: - Cancellation

    // Latched, so a Stop during the row count or before the plugin starts is not lost.
    func cancelExport() {
        isStopRequested = true
        currentProgress?.cancel()
    }

    @Published private var currentProgress: PluginExportProgress?
    private var isStopRequested = false

    private func throwIfStopped() throws {
        if isStopRequested || Task.isCancelled {
            throw PluginExportCancellationError()
        }
    }

    /// The status line a plugin writes with `PluginExportProgress.setStatus`. Nothing observed it,
    /// so "Compressing..." never reached a user in any export. The empty guard sits outside the hop
    /// deliberately: the channel is seeded empty and `fetchTotalRowCount` may already have put its
    /// own message in `statusMessage`.
    private func observeStatus(on nsProgress: Progress) -> NSKeyValueObservation {
        nsProgress.observe(\.localizedAdditionalDescription) { [weak self] observed, _ in
            let status = observed.localizedAdditionalDescription ?? ""
            guard !status.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.state.statusMessage = status
            }
        }
    }

    // MARK: - Public API

    func export(
        objects: [ExportObjectItem],
        config: ExportConfiguration,
        to url: URL
    ) async throws {
        guard !objects.isEmpty else {
            throw ExportError.noTablesSelected
        }

        guard let plugin = exportPlugin(config.formatId) else {
            throw ExportError.formatNotFound(config.formatId)
        }

        state = ExportState(isExporting: true, totalTables: objects.count)

        defer {
            state.isExporting = false
            state.statusMessage = ""
            currentProgress = nil
        }

        guard let driver, let databaseType else {
            throw ExportError.notConnected
        }
        try throwIfStopped()

        let rowObjects = objects.filter { plugin.readsRows(optionValues: $0.optionValues, kind: $0.kind) }
        try await ReadOnlyReadGate.authorize(
            ReadOnlyReadGate.rowScopeStatements(rowObjects, databaseType: databaseType) { driver.quoteIdentifier($0) },
            connectionId: driver.connection.id,
            databaseType: databaseType,
            gate: executionGate
        )
        try throwIfStopped()

        let safeModeIsReadOnly = ExecutionGateProvider.runsAtReadOnly(driver.connection.id)
        let dataSource = ExportDataSourceAdapter(
            driver: driver,
            databaseType: databaseType,
            safeModeIsReadOnly: safeModeIsReadOnly
        )

        state.readsRows = !rowObjects.isEmpty
        state.totalRows = await estimateTotalRows(
            for: rowObjects.filter { $0.kind.carriesRows },
            dataSource: dataSource
        )
        try throwIfStopped()

        let nsProgress = Progress(totalUnitCount: Int64(state.totalRows))
        let progress = PluginExportProgress(progress: nsProgress)
        currentProgress = progress

        let observation = nsProgress.observe(\.completedUnitCount) { [weak self] observed, _ in
            let count = Int(observed.completedUnitCount)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state.processedRows = count
            }
        }
        defer { observation.invalidate() }

        let descObservation = nsProgress.observe(\.localizedDescription) { [weak self] observed, _ in
            let tableName = observed.localizedDescription ?? ""
            let tableIndex = progress.currentTableIndex
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state.currentTable = tableName
                self.state.currentTableIndex = tableIndex
            }
        }
        defer { descObservation.invalidate() }

        let statusObservation = observeStatus(on: nsProgress)
        defer { statusObservation.invalidate() }

        let pluginTables = objects.map { object in
            PluginExportTable(
                name: object.name,
                databaseName: dataSource.pluginDatabaseName(for: object.databaseName),
                // A routine's own kind, which picks DROP FUNCTION or DROP PROCEDURE.
                tableType: object.routineKind?.rawValue ?? object.kind.rawValue,
                optionValues: object.optionValues,
                schema: dataSource.exportSchema(for: object.databaseName),
                kind: object.kind,
                identity: object.identity,
                parentTable: object.parentTable,
                rowScope: object.rowScope
            )
        }

        await suppressStatementTimeout(on: driver)
        let result: ExportFormatResult
        do {
            result = try await plugin.export(
                tables: pluginTables,
                dataSource: MaskingExportDataSource.wrapping(dataSource, policy: maskingPolicy(for: driver)),
                destination: url,
                progress: progress
            )
        } catch {
            await restoreStatementTimeout(on: driver)
            state.errorMessage = error.localizedDescription
            throw error
        }
        await restoreStatementTimeout(on: driver)

        state.processedRows = progress.processedRows

        state.warnings = result.warnings + dataSource.cappedTableWarnings
        state.notes = result.notes
    }

    // MARK: - Masking

    // The live session's copy, so a rule saved after the connection opened applies to this export.
    private func maskingPolicy(for driver: DatabaseDriver) -> MaskingPolicy {
        (DatabaseManager.shared.session(for: driver.connection.id)?.connection ?? driver.connection).maskingPolicy
    }

    // MARK: - Statement Timeout

    func suppressStatementTimeout(on driver: DatabaseDriver) async {
        do {
            try await driver.applyQueryTimeout(0)
        } catch {
            Self.logger.warning("Failed to disable statement timeout for export: \(error.localizedDescription)")
        }
    }

    func restoreStatementTimeout(on driver: DatabaseDriver) async {
        do {
            try await driver.applyQueryTimeout(effectiveQueryTimeoutSeconds)
        } catch {
            Self.logger.warning("Failed to restore statement timeout after export: \(error.localizedDescription)")
        }
    }

    // MARK: - Query Results Export

    func exportQueryResults(
        tableRows: TableRows,
        fillUnloaded: UnloadedValueFill? = nil,
        config: ExportConfiguration,
        to url: URL
    ) async throws {
        guard let databaseType else {
            throw ExportError.notConnected
        }
        let dataSource = QueryResultExportDataSource(
            tableRows: tableRows,
            databaseType: databaseType,
            driver: driver,
            fillUnloaded: fillUnloaded
        )
        try await export(dataSource: dataSource, config: config, to: url)
    }

    func export(
        dataSource: any PluginExportDataSource,
        config: ExportConfiguration,
        to url: URL
    ) async throws {
        guard let plugin = exportPlugin(config.formatId) else {
            throw ExportError.formatNotFound(config.formatId)
        }

        let exportTable = Self.queryResultExportTable(named: config.fileName, plugin: plugin)
        state = ExportState(isExporting: true, totalTables: 1)
        let totalRows = await Self.approximateRowCount(of: exportTable, in: dataSource)
        state.totalRows = totalRows

        defer {
            state.isExporting = false
            state.statusMessage = ""
            currentProgress = nil
        }
        try throwIfStopped()

        let nsProgress = Progress(totalUnitCount: Int64(totalRows))
        let progress = PluginExportProgress(progress: nsProgress)
        currentProgress = progress

        let observation = nsProgress.observe(\.completedUnitCount) { [weak self] observed, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state.processedRows = Int(observed.completedUnitCount)
            }
        }
        defer { observation.invalidate() }

        let descObservation = nsProgress.observe(\.localizedDescription) { [weak self] observed, _ in
            let tableName = observed.localizedDescription ?? ""
            let tableIndex = progress.currentTableIndex
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state.currentTable = tableName
                self.state.currentTableIndex = tableIndex
            }
        }
        defer { descObservation.invalidate() }

        let statusObservation = observeStatus(on: nsProgress)
        defer { statusObservation.invalidate() }

        let result: ExportFormatResult
        do {
            result = try await plugin.export(
                tables: [exportTable],
                dataSource: dataSource,
                destination: url,
                progress: progress
            )
        } catch {
            state.errorMessage = error.localizedDescription
            throw error
        }

        state.processedRows = progress.processedRows

        state.warnings = result.warnings
        state.notes = result.notes
    }

    private static func approximateRowCount(
        of table: PluginExportTable,
        in dataSource: any PluginExportDataSource
    ) async -> Int {
        do {
            return try await dataSource.fetchApproximateRowCount(
                table: table.name,
                databaseName: table.databaseName
            ) ?? 0
        } catch {
            logger.warning("Failed to count the rows to export: \(error.localizedDescription)")
            return 0
        }
    }

    func exportStreamingQuery(
        query: String,
        config: ExportConfiguration,
        to url: URL
    ) async throws {
        guard let plugin = exportPlugin(config.formatId) else {
            throw ExportError.formatNotFound(config.formatId)
        }
        guard let driver, let databaseType else {
            throw ExportError.exportFailed("No database connection")
        }

        let estimatedRows = 0
        state = ExportState(isExporting: true, totalTables: 1, totalRows: estimatedRows)

        defer {
            state.isExporting = false
            state.statusMessage = ""
            currentProgress = nil
        }
        try throwIfStopped()
        try await ReadOnlyReadGate.authorize(
            [query], connectionId: driver.connection.id, databaseType: databaseType, gate: executionGate
        )
        try throwIfStopped()

        let dataSource = StreamingQueryExportDataSource(
            query: LeadingRowsStatement.resolve(query, rowCap: nil, databaseType: databaseType).sql,
            driver: driver,
            databaseType: databaseType,
            safeModeIsReadOnly: ExecutionGateProvider.runsAtReadOnly(driver.connection.id)
        )

        let nsProgress = Progress(totalUnitCount: Int64(max(estimatedRows, 1)))
        let progress = PluginExportProgress(progress: nsProgress)
        currentProgress = progress

        let observation = nsProgress.observe(\.completedUnitCount) { [weak self] observed, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state.processedRows = Int(observed.completedUnitCount)
            }
        }
        defer { observation.invalidate() }

        let statusObservation = observeStatus(on: nsProgress)
        defer { statusObservation.invalidate() }

        let exportTable = Self.queryResultExportTable(named: config.fileName, plugin: plugin)

        await suppressStatementTimeout(on: driver)
        let result: ExportFormatResult
        do {
            result = try await plugin.export(
                tables: [exportTable],
                dataSource: MaskingExportDataSource.wrapping(
                    dataSource, policy: maskingPolicy(for: driver), streamsTables: false
                ),
                destination: url,
                progress: progress
            )
        } catch {
            await restoreStatementTimeout(on: driver)
            state.errorMessage = error.localizedDescription
            throw error
        }
        await restoreStatementTimeout(on: driver)

        state.processedRows = progress.processedRows

        let capWarning = Self.leadingRowsCapWarning(
            exportedRows: progress.processedRows,
            pagination: PaginationCapability.of(databaseType),
            driverCut: dataSource.driverRowCut
        )
        state.warnings = result.warnings + [capWarning].compactMap { $0 }
        state.notes = result.notes
    }

    // A file that reached the engine's ceiling, or the limit the driver cut its stream at, is named as partial.
    static func leadingRowsCapWarning(
        exportedRows: Int,
        pagination: PaginationCapability,
        driverCut: Int? = nil
    ) -> String? {
        let engineCut = pagination.maximumRows.flatMap { exportedRows >= $0 ? $0 : nil }
        guard let maximum = engineCut ?? driverCut else { return nil }
        return String(
            format: String(localized: "Only the first %lld rows were exported, the most this database returns from one query."),
            maximum
        )
    }

    // MARK: - Row Total

    // The total only sizes the progress bar, so it comes from the catalog's estimate. An exact COUNT(*) is a full
    // scan on PostgreSQL and InnoDB, and the export would read every table twice before its first row.
    private func estimateTotalRows(
        for tables: [ExportObjectItem],
        dataSource: ExportDataSourceAdapter
    ) async -> Int {
        guard !tables.isEmpty else { return 0 }
        // A filter can keep any share of the rows, so no estimate bounds it, and a partial sum would park the bar.
        guard !tables.contains(where: { ExportRowTotal.isUnknowable($0.rowScope) }) else { return 0 }

        var estimates: [Int: Int] = [:]
        let groups = Dictionary(grouping: tables.indices) { tables[$0].databaseName }
        for (databaseName, indices) in groups.sorted(by: { $0.key < $1.key }) {
            guard !isStopRequested else { return 0 }
            if indices.count > 1, let bulk = await bulkEstimates(databaseName: databaseName, dataSource: dataSource) {
                for index in indices {
                    if let estimate = bulk[tables[index].name] { estimates[index] = estimate }
                }
                continue
            }
            for index in indices {
                guard !isStopRequested else { return 0 }
                let table = tables[index]
                do {
                    if let estimate = try await dataSource.fetchApproximateRowCount(
                        table: table.name, databaseName: table.databaseName
                    ) {
                        estimates[index] = estimate
                    }
                } catch {
                    Self.logger.warning(
                        "Failed to read the row estimate for \(table.qualifiedName): \(error.localizedDescription)"
                    )
                }
            }
        }

        // A table with no estimate still reports its rows, so leaving it out would park the bar at its ceiling.
        var total = 0
        for index in tables.indices {
            guard let rows = ExportRowTotal.rows(estimate: estimates[index], scope: tables[index].rowScope) else {
                return 0
            }
            total = Self.saturatingSum(total, rows)
        }
        state.rowTotalIsEstimate = total > 0
        return total
    }

    // One catalog statement for the whole schema. A failed read falls back to one estimate per table.
    private func bulkEstimates(databaseName: String, dataSource: ExportDataSourceAdapter) async -> [String: Int]? {
        do {
            return try await dataSource.fetchBulkApproximateRowCounts(databaseName: databaseName)
        } catch {
            Self.logger.warning("Failed to read the schema's row estimates: \(error.localizedDescription)")
            return nil
        }
    }

    private static func saturatingSum(_ total: Int, _ count: Int) -> Int {
        let (sum, overflow) = total.addingReportingOverflow(count)
        return overflow ? (count < 0 ? .min : .max) : sum
    }
}
