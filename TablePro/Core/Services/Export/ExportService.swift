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
    var progress: Double = 0.0
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
    static let logger = Logger(subsystem: "com.TablePro", category: "ExportService")

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

    private let isCancelledLock = NSLock()
    private var _isCancelled: Bool = false
    var isCancelled: Bool {
        get {
            isCancelledLock.lock()
            defer { isCancelledLock.unlock() }
            return _isCancelled
        }
        set {
            isCancelledLock.lock()
            _isCancelled = newValue
            isCancelledLock.unlock()
        }
    }

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
            Task { @MainActor [weak self] in
                guard let self else { return }
                let rows = Int(observed.completedUnitCount)
                let total = Int(observed.totalUnitCount)
                self.state.processedRows = rows
                if total > 0 {
                    self.state.progress = Double(rows) / Double(total)
                }
            }
        }
        defer { observation.invalidate() }

        let descObservation = nsProgress.observe(\.localizedDescription) { [weak self] observed, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state.currentTable = observed.localizedDescription ?? ""
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
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                Self.logger.warning("Failed to clean up export file: \(error.localizedDescription)")
            }
            state.errorMessage = error.localizedDescription
            throw error
        }

        if !result.warnings.isEmpty {
            state.warningMessage = result.warnings.joined(separator: "\n")
        }

        state.progress = 1.0
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
                let rows = Int(observed.completedUnitCount)
                let total = Int(observed.totalUnitCount)
                self.state.processedRows = rows
                if total > 0 {
                    self.state.progress = Double(rows) / Double(total)
                }
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
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                Self.logger.warning("Failed to clean up export file: \(error.localizedDescription)")
            }
            state.errorMessage = error.localizedDescription
            throw error
        }

        if !result.warnings.isEmpty {
            state.warningMessage = result.warnings.joined(separator: "\n")
        }

        state.progress = 1.0
    }

    // MARK: - Row Count Fetching

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
                state.statusMessage = "Progress estimated (\(failedCount) table\(failedCount > 1 ? "s" : "") could not be counted)"
            }
            return total
        }

        let chunkSize = 50

        for chunkStart in stride(from: 0, to: tables.count, by: chunkSize) {
            let end = min(chunkStart + chunkSize, tables.count)
            let batch = tables[chunkStart ..< end]

            let unionParts = batch.map { table -> String in
                let tableRef: String
                if table.databaseName.isEmpty {
                    tableRef = driver.quoteIdentifier(table.name)
                } else {
                    let quotedDb = driver.quoteIdentifier(table.databaseName)
                    let quotedTable = driver.quoteIdentifier(table.name)
                    tableRef = "\(quotedDb).\(quotedTable)"
                }
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
                        let tableRef: String
                        if table.databaseName.isEmpty {
                            tableRef = driver.quoteIdentifier(table.name)
                        } else {
                            let quotedDb = driver.quoteIdentifier(table.databaseName)
                            let quotedTable = driver.quoteIdentifier(table.name)
                            tableRef = "\(quotedDb).\(quotedTable)"
                        }
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
            state.statusMessage = "Progress estimated (\(failedCount) table\(failedCount > 1 ? "s" : "") could not be counted)"
        }
        return total
    }
}
