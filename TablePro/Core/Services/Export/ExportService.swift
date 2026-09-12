//
//  ExportService.swift
//  TablePro
//

import Foundation
import Observation
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

    /// What the export wrote, as opposed to what went wrong with it. Kept apart from `warnings`
    /// because the success alert reads a non-empty `warnings` as a problem: it retitles itself,
    /// takes the caution icon, and drops its "Do not show this again" checkbox.
    var notes: [String] = []
}

// MARK: - Export Service

@MainActor @Observable
final class ExportService {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ExportService")

    var state = ExportState()

    private let driver: DatabaseDriver?
    private let databaseType: DatabaseType

    init(driver: DatabaseDriver, databaseType: DatabaseType) {
        self.driver = driver
        self.databaseType = databaseType
    }

    /// Rows already in memory still need the engine that produced them: a SQL export has to quote
    /// identifiers and escape literals the way that engine reads them back. The driver is asked for
    /// nothing but those two pure functions here, so an installed handle is enough and no lease is
    /// taken. It is optional only because a connection can be gone by the time the sheet runs, and
    /// the formats that carry no SQL still export fine without one.
    init(queryResultsDriver driver: DatabaseDriver?, databaseType: DatabaseType) {
        self.driver = driver
        self.databaseType = databaseType
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

    func cancelExport() {
        currentProgress?.cancel()
    }

    private var currentProgress: PluginExportProgress?

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

        guard let plugin = PluginManager.shared.exportPlugin(forFormat: config.formatId) else {
            throw ExportError.formatNotFound(config.formatId)
        }

        state = ExportState(isExporting: true, totalTables: objects.count)

        defer {
            state.isExporting = false
                state.statusMessage = ""
            currentProgress = nil
        }

        guard let driver else {
            throw ExportError.notConnected
        }

        let dataSource = ExportDataSourceAdapter(driver: driver, databaseType: databaseType)

        state.totalRows = await fetchTotalRowCount(
            for: objects.filter { $0.kind.carriesRows }, driver: driver, dataSource: dataSource)

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
                tableType: object.kind.rawValue,
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
                dataSource: dataSource,
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

    // MARK: - Statement Timeout

    func suppressStatementTimeout(on driver: DatabaseDriver) async {
        do {
            try await driver.applyQueryTimeout(0)
        } catch {
            Self.logger.warning("Failed to disable statement timeout for export: \(error.localizedDescription)")
        }
    }

    func restoreStatementTimeout(on driver: DatabaseDriver) async {
        let timeout = AppSettingsManager.shared.general.queryTimeoutSeconds
        do {
            try await driver.applyQueryTimeout(timeout)
        } catch {
            Self.logger.warning("Failed to restore statement timeout after export: \(error.localizedDescription)")
        }
    }

    // MARK: - Query Results Export

    func exportQueryResults(
        tableRows: TableRows,
        config: ExportConfiguration,
        to url: URL
    ) async throws {
        guard let plugin = PluginManager.shared.exportPlugin(forFormat: config.formatId) else {
            throw ExportError.formatNotFound(config.formatId)
        }

        let totalRows = tableRows.count
        state = ExportState(isExporting: true, totalTables: 1, totalRows: totalRows)

        defer {
            state.isExporting = false
                state.statusMessage = ""
            currentProgress = nil
        }

        let dataSource = QueryResultExportDataSource(
            tableRows: tableRows,
            databaseType: databaseType,
            driver: driver
        )

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

        let exportTable = Self.queryResultExportTable(named: config.fileName, plugin: plugin)

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

    func exportStreamingQuery(
        query: String,
        config: ExportConfiguration,
        to url: URL
    ) async throws {
        guard let plugin = PluginManager.shared.exportPlugin(forFormat: config.formatId) else {
            throw ExportError.formatNotFound(config.formatId)
        }
        guard let driver else {
            throw ExportError.exportFailed("No database connection")
        }

        let estimatedRows = 0
        state = ExportState(isExporting: true, totalTables: 1, totalRows: estimatedRows)

        defer {
            state.isExporting = false
                state.statusMessage = ""
            currentProgress = nil
        }

        let dataSource = StreamingQueryExportDataSource(
            query: LeadingRowsStatement.resolve(query, rowCap: nil, databaseType: databaseType).sql,
            driver: driver,
            databaseType: databaseType
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
                dataSource: dataSource,
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
            pagination: PaginationCapability.of(databaseType)
        )
        state.warnings = result.warnings + [capWarning].compactMap { $0 }
        state.notes = result.notes
    }

    /// A query result exported from an engine that returns only its leading rows stops at the
    /// engine's ceiling, so a file that reached it is named as partial rather than passing as whole.
    static func leadingRowsCapWarning(exportedRows: Int, pagination: PaginationCapability) -> String? {
        guard let maximum = pagination.maximumRows, exportedRows >= maximum else { return nil }
        return String(
            format: String(localized: "Only the first %lld rows were exported, the most this database returns from one query."),
            maximum
        )
    }

    // MARK: - Row Count Fetching

    private func qualifiedTableRef(for table: ExportObjectItem, driver: DatabaseDriver) -> String {
        SchemaQualifiedName.render(
            name: table.name,
            schema: table.databaseName,
            databaseType: databaseType,
            quote: driver.quoteIdentifier
        )
    }

    /// The non-SQL count goes through the data source, which knows the container each object was
    /// listed under. Asking the driver directly answers about whichever one it is leased to, so an
    /// export spanning two databases counted one of them twice and reported a total no progress bar
    /// could reach.
    private func fetchTotalRowCount(
        for tables: [ExportObjectItem],
        driver: DatabaseDriver,
        dataSource: ExportDataSourceAdapter
    ) async -> Int {
        guard !tables.isEmpty else { return 0 }

        var total = 0
        var failedCount = 0

        if PluginManager.shared.editorLanguage(for: databaseType) != .sql {
            for table in tables {
                do {
                    let count = try await dataSource.fetchApproximateRowCount(
                        table: table.name, databaseName: table.databaseName
                    )
                    if let count {
                        total += count
                    }
                } catch {
                    failedCount += 1
                    Self.logger.warning("Failed to get approximate row count for \(table.qualifiedName): \(error.localizedDescription)")
                }
            }
            if failedCount > 0 {
                Self.logger.warning("\(failedCount) tables failed row count, the progress indicator may be inaccurate")
                state.statusMessage = Self.estimatedProgressMessage(uncountedTables: failedCount)
            }
            return total
        }

        let chunkSize = 50

        for chunkStart in stride(from: 0, to: tables.count, by: chunkSize) {
            let end = min(chunkStart + chunkSize, tables.count)
            let batch = tables[chunkStart ..< end]

            let unionParts = batch.map { table -> String in
                let tableRef = qualifiedTableRef(for: table, driver: driver)
                return "SELECT COUNT(*) AS c FROM \(tableRef)"
            }
            let batchQuery = unionParts.joined(separator: " UNION ALL ")

            do {
                let result = try await driver.execute(query: batchQuery)
                for row in result.rows {
                    if let cell = row.first, let count = Int(cell.asText ?? "0") {
                        total += count
                    }
                }
            } catch {
                for table in batch {
                    do {
                        let tableRef = qualifiedTableRef(for: table, driver: driver)
                        let result = try await driver.execute(query: "SELECT COUNT(*) FROM \(tableRef)")
                        if let cell = result.rows.first?.first, let count = Int(cell.asText ?? "0") {
                            total += count
                        }
                    } catch {
                        failedCount += 1
                        Self.logger.warning("Failed to get row count for \(table.qualifiedName): \(error.localizedDescription)")
                    }
                }
            }
        }

        if failedCount > 0 {
            Self.logger.warning("\(failedCount) tables failed row count, the progress indicator may be inaccurate")
            state.statusMessage = Self.estimatedProgressMessage(uncountedTables: failedCount)
        }
        return total
    }

    /// Counts pick between an explicit singular and plural key. Automatic grammar agreement is a
    /// SwiftUI `Text` facility: `String(localized:)` returns the markup verbatim.
    private static func estimatedProgressMessage(uncountedTables: Int) -> String {
        let template = uncountedTables == 1
            ? String(localized: "Progress estimated (%lld table could not be counted)")
            : String(localized: "Progress estimated (%lld tables could not be counted)")
        return String(format: template, Int64(uncountedTables))
    }
}
