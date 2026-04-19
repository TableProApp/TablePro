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
    var warningMessage: String?
}

// MARK: - Export Service

@MainActor @Observable
final class ExportService {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ExportService")

    var state = ExportState()

    private let driver: DatabaseDriver?
    private let databaseType: DatabaseType

    init(driver: DatabaseDriver, databaseType: DatabaseType) {
        self.driver = driver
        self.databaseType = databaseType
    }

    /// Convenience initializer for query results export (no driver needed).
    init(databaseType: DatabaseType) {
        self.driver = nil
        self.databaseType = databaseType
    }

    // MARK: - Cancellation

    var isCancelled: Bool = false

    func cancelExport() {
        isCancelled = true
        currentProgress?.cancel()
    }

    private var currentProgress: PluginExportProgress?

    // MARK: - Public API

    func export(
        tables: [ExportTableItem],
        config: ExportConfiguration,
        to url: URL
    ) async throws {
        guard !tables.isEmpty else {
            throw ExportError.noTablesSelected
        }

        guard let plugin = PluginManager.shared.exportPlugins[config.formatId] else {
            throw ExportError.formatNotFound(config.formatId)
        }

        // Reset state
        state = ExportState(isExporting: true, totalTables: tables.count)
        isCancelled = false

        defer {
            state.isExporting = false
            isCancelled = false
            state.statusMessage = ""
            currentProgress = nil
        }

        guard let driver else {
            throw ExportError.notConnected
        }

        // Fetch total row counts
        state.totalRows = await fetchTotalRowCount(for: tables, driver: driver)

        // Create data source adapter
        let dataSource = ExportDataSourceAdapter(driver: driver, databaseType: databaseType)

        // Create progress tracker
        let nsProgress = Progress(totalUnitCount: Int64(state.totalRows))
        let progress = PluginExportProgress(progress: nsProgress)
        currentProgress = progress

        // Observe NSProgress for UI updates
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

        // Convert ExportTableItems to PluginExportTables
        let pluginTables = tables.map { table in
            PluginExportTable(
                name: table.name,
                databaseName: table.databaseName,
                tableType: table.type == .view ? "view" : "table",
                optionValues: table.optionValues
            )
        }

        let result: ExportFormatResult
        do {
            result = try await plugin.export(
                tables: pluginTables,
                dataSource: dataSource,
                destination: url,
                progress: progress
            )
        } catch {
            state.errorMessage = error.localizedDescription
            throw error
        }

        state.processedRows = progress.processedRows

        if !result.warnings.isEmpty {
            state.warningMessage = result.warnings.joined(separator: "\n")
        }
    }

    // MARK: - Query Results Export

    func exportQueryResults(
        rowBuffer: RowBuffer,
        config: ExportConfiguration,
        to url: URL
    ) async throws {
        guard let plugin = PluginManager.shared.exportPlugins[config.formatId] else {
            throw ExportError.formatNotFound(config.formatId)
        }

        let totalRows = rowBuffer.rows.count
        state = ExportState(isExporting: true, totalTables: 1, totalRows: totalRows)
        isCancelled = false

        defer {
            state.isExporting = false
            isCancelled = false
            state.statusMessage = ""
            currentProgress = nil
        }

        let dataSource = QueryResultExportDataSource(
            rowBuffer: rowBuffer,
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

        let exportTable = PluginExportTable(
            name: config.fileName,
            databaseName: "",
            tableType: "query",
            optionValues: plugin.defaultTableOptionValues()
        )

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

        if !result.warnings.isEmpty {
            state.warningMessage = result.warnings.joined(separator: "\n")
        }
    }

    func exportStreamingQuery(
        query: String,
        config: ExportConfiguration,
        to url: URL
    ) async throws {
        guard let plugin = PluginManager.shared.exportPlugins[config.formatId] else {
            throw ExportError.formatNotFound(config.formatId)
        }
        guard let driver else {
            throw ExportError.exportFailed("No database connection")
        }

        let estimatedRows = 0
        state = ExportState(isExporting: true, totalTables: 1, totalRows: estimatedRows)
        isCancelled = false

        defer {
            state.isExporting = false
            isCancelled = false
            state.statusMessage = ""
            currentProgress = nil
        }

        let dataSource = StreamingQueryExportDataSource(
            query: query,
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

        let exportTable = PluginExportTable(
            name: config.fileName,
            databaseName: "",
            tableType: "query",
            optionValues: plugin.defaultTableOptionValues()
        )

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

        if !result.warnings.isEmpty {
            state.warningMessage = result.warnings.joined(separator: "\n")
        }
    }

    // MARK: - Row Count Fetching

    private func qualifiedTableRef(for table: ExportTableItem, driver: DatabaseDriver) -> String {
        if table.databaseName.isEmpty {
            return driver.quoteIdentifier(table.name)
        }
        let quotedDb = driver.quoteIdentifier(table.databaseName)
        let quotedTable = driver.quoteIdentifier(table.name)
        return "\(quotedDb).\(quotedTable)"
    }

    private func fetchTotalRowCount(for tables: [ExportTableItem], driver: DatabaseDriver) async -> Int {
        guard !tables.isEmpty else { return 0 }

        var total = 0
        var failedCount = 0

        if PluginManager.shared.editorLanguage(for: databaseType) != .sql {
            for table in tables {
                do {
                    if let count = try await driver.fetchApproximateRowCount(table: table.name) {
                        total += count
                    }
                } catch {
                    failedCount += 1
                    Self.logger.warning("Failed to get approximate row count for \(table.qualifiedName): \(error.localizedDescription)")
                }
            }
            if failedCount > 0 {
                Self.logger.warning("\(failedCount) table(s) failed row count - progress indicator may be inaccurate")
                state.statusMessage = String(format: String(localized: "Progress estimated (%d table(s) could not be counted)"), failedCount)
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
                    if let countStr = row.first, let count = Int(countStr ?? "0") {
                        total += count
                    }
                }
            } catch {
                for table in batch {
                    do {
                        let tableRef = qualifiedTableRef(for: table, driver: driver)
                        let result = try await driver.execute(query: "SELECT COUNT(*) FROM \(tableRef)")
                        if let countStr = result.rows.first?.first, let count = Int(countStr ?? "0") {
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
            Self.logger.warning("\(failedCount) table(s) failed row count - progress indicator may be inaccurate")
            state.statusMessage = String(format: String(localized: "Progress estimated (%d table(s) could not be counted)"), failedCount)
        }
        return total
    }
}
