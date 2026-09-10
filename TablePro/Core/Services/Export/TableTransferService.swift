//
//  TableTransferService.swift
//  TablePro
//

import Foundation
import Observation
import os
import TableProPluginKit

enum TableTransferError: LocalizedError {
    case notConnected(connectionName: String)
    case noTablesSelected
    case sameConnectionAndContainer
    case targetMissing(table: String)
    case noMatchingColumns(table: String)
    case transferFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected(let connectionName):
            return String(format: String(localized: "Not connected to %@"), connectionName)
        case .noTablesSelected:
            return String(localized: "No tables selected to transfer")
        case .sameConnectionAndContainer:
            return String(localized: "The source and the destination are the same database.")
        case .targetMissing(let table):
            return String(format: String(localized: "The destination has no table named %@"), table)
        case .noMatchingColumns(let table):
            return String(
                format: String(localized: "No column of %@ matches a column on the destination table."),
                table)
        case .transferFailed(let message):
            return String(format: String(localized: "Transfer failed: %@"), message)
        }
    }
}

struct TableTransferState {
    var isTransferring = false
    var currentTable = ""
    var currentTableIndex = 0
    var totalTables = 0
    var transferredRows = 0
    var errorMessage: String?
    var warnings: [String] = []
}

/// Copies rows straight from one connection into another, with no file in between.
///
/// The two halves of the file-based flow already exist and already fit together: an export data
/// source streams rows out of one connection, an import sink writes rows into another. This joins
/// them, so a transfer costs one read and one write rather than a dump the user has to name, save,
/// find and import.
///
/// It moves rows, not structure. The destination table has to exist, because inventing DDL that
/// crosses engines is a different problem from copying rows and getting it half right would create
/// tables whose types quietly do not match.
@MainActor
@Observable
final class TableTransferService {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "TableTransfer")

    /// The batch a transfer accumulates before writing. The sink chunks again by bind-parameter
    /// count, so this only bounds how many rows are held at once.
    static let batchSize = 500

    var state = TableTransferState()

    private var isCancelled = false

    /// Cleared once, before the run's first cancellable step. The sheet reads both sides' columns
    /// before `transfer()` is reached, and a Stop pressed during that read has to survive into it.
    func prepareForRun() {
        isCancelled = false
    }

    func cancel() {
        isCancelled = true
    }

    struct Request {
        let objects: [ExportObjectItem]
        let sourceType: DatabaseType
        let destinationType: DatabaseType
        let destinationSchema: String?
        let columnMapping: [String: [String: String]]

        /// The source columns per table, so a mapping can be matched by name without re-reading the
        /// source schema mid-transfer.
        let sourceColumns: [String: [String]]

        let deleteExistingRows: Bool
        let wrapInTransaction: Bool

        init(
            objects: [ExportObjectItem],
            sourceType: DatabaseType,
            destinationType: DatabaseType,
            destinationSchema: String? = nil,
            columnMapping: [String: [String: String]] = [:],
            sourceColumns: [String: [String]] = [:],
            deleteExistingRows: Bool = false,
            wrapInTransaction: Bool = true
        ) {
            self.objects = objects
            self.sourceType = sourceType
            self.destinationType = destinationType
            self.destinationSchema = destinationSchema
            self.columnMapping = columnMapping
            self.sourceColumns = sourceColumns
            self.deleteExistingRows = deleteExistingRows
            self.wrapInTransaction = wrapInTransaction
        }
    }

    /// Runs the whole transfer inside leases on both drivers, so every statement lands on the
    /// database the sheet named rather than wherever either shared driver was last parked.
    func transfer(
        request: Request,
        sourceDriver: DatabaseDriver,
        destinationDriver: DatabaseDriver
    ) async throws {
        let rowObjects = request.objects.filter { $0.kind.carriesRows }
        guard !rowObjects.isEmpty else { throw TableTransferError.noTablesSelected }

        /// The flag is cleared on the way out, never on the way in. A Stop pressed while the sheet
        /// was still reading both sides' columns arrives before this line, and clearing it here
        /// threw that press away and started the transfer the user had just stopped.
        state = TableTransferState(isTransferring: true, totalTables: rowObjects.count)
        defer {
            state.isTransferring = false
            isCancelled = false
        }

        let source = ExportDataSourceAdapter(driver: sourceDriver, databaseType: request.sourceType)

        for (index, object) in rowObjects.enumerated() {
            try checkCancellation()
            state.currentTable = object.name
            state.currentTableIndex = index + 1

            let mapping = try await resolveMapping(
                for: object, request: request, destinationDriver: destinationDriver)
            let sink = ImportDataSinkAdapter(
                driver: destinationDriver,
                databaseType: request.destinationType,
                targetTable: object.name,
                columnMapping: mapping
            )
            try await transferOne(object: object, from: source, into: sink, request: request)
        }
    }

    /// The sink writes by column name and skips any field the mapping does not name, so an empty
    /// mapping writes nothing and reports every row as unmapped. A caller that supplies no mapping
    /// gets one matched by name, and a table whose columns match nothing is refused by name here
    /// rather than failing on its first batch with the sink's generic message.
    private func resolveMapping(
        for object: ExportObjectItem,
        request: Request,
        destinationDriver: DatabaseDriver
    ) async throws -> [String: String] {
        if let supplied = request.columnMapping[object.name], !supplied.isEmpty {
            return supplied
        }
        guard let pluginDriver = (destinationDriver as? PluginDriverAdapter)?.schemaPluginDriver else {
            throw TableTransferError.targetMissing(table: object.name)
        }
        let destinationColumns: [String]
        do {
            destinationColumns = try await pluginDriver
                .fetchColumns(table: object.name, schema: request.destinationSchema)
                .map(\.name)
        } catch {
            throw TableTransferError.targetMissing(table: object.name)
        }
        guard !destinationColumns.isEmpty else {
            throw TableTransferError.targetMissing(table: object.name)
        }

        let sourceColumns = request.sourceColumns[object.name] ?? []
        let match = TableColumnMatcher.match(source: sourceColumns, destination: destinationColumns)
        guard !match.isEmpty else {
            throw TableTransferError.noMatchingColumns(table: object.name)
        }
        if !match.unmatchedSource.isEmpty {
            state.warnings.append(String(
                format: String(localized: "%1$@: %2$@ had no column of that name on the destination."),
                object.name,
                match.unmatchedSource.joined(separator: ", ")))
        }
        return match.mapping
    }

    private func transferOne(
        object: ExportObjectItem,
        from source: ExportDataSourceAdapter,
        into sink: ImportDataSinkAdapter,
        request: Request
    ) async throws {
        let exportTable = PluginExportTable(
            name: object.name,
            databaseName: object.databaseName,
            tableType: object.kind.rawValue,
            optionValues: object.optionValues,
            schema: source.exportSchema(for: object.databaseName),
            kind: object.kind,
            identity: object.identity,
            parentTable: object.parentTable,
            rowScope: object.rowScope
        )

        var columns: [String] = []
        var batch: [[String: PluginCellValue]] = []
        var wroteAnything = false

        if request.wrapInTransaction {
            try await sink.beginTransaction()
        }
        do {
            if request.deleteExistingRows {
                try await sink.deleteAllRowsFromTargetTable()
            }
            for try await element in source.streamRows(for: exportTable) {
                try checkCancellation()
                switch element {
                case .header(let header):
                    columns = header.columns
                case .rows(let rows):
                    for row in rows {
                        batch.append(Self.dictionary(columns: columns, row: row))
                        guard batch.count >= Self.batchSize else { continue }
                        try await sink.insertRows(batch)
                        state.transferredRows += batch.count
                        wroteAnything = true
                        batch.removeAll(keepingCapacity: true)
                    }
                }
            }
            if !batch.isEmpty {
                try await sink.insertRows(batch)
                state.transferredRows += batch.count
                wroteAnything = true
            }
            if request.wrapInTransaction {
                try await sink.commitTransaction()
            }
        } catch {
            if request.wrapInTransaction {
                do {
                    try await sink.rollbackTransaction()
                } catch {
                    Self.logger.warning("Rollback after a failed transfer also failed: \(error.localizedDescription)")
                }
            }
            state.errorMessage = error.localizedDescription
            throw TableTransferError.transferFailed(error.localizedDescription)
        }

        if !wroteAnything {
            state.warnings.append(String(
                format: String(localized: "%@ had no rows to transfer."), object.name))
        }
    }

    /// A row arrives as positional values and the sink writes by column name, so the two are
    /// zipped here. A row shorter than its header is padded with nulls rather than dropped: a
    /// driver that omits trailing nulls would otherwise lose whole rows silently.
    nonisolated static func dictionary(columns: [String], row: [PluginCellValue]) -> [String: PluginCellValue] {
        var values: [String: PluginCellValue] = [:]
        values.reserveCapacity(columns.count)
        for (index, column) in columns.enumerated() {
            values[column] = index < row.count ? row[index] : .null
        }
        return values
    }

    private func checkCancellation() throws {
        guard isCancelled else { return }
        throw PluginImportCancellationError()
    }
}
