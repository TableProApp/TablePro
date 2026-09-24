//
//  DataFileController+Transfer.swift
//  TablePro
//

import Foundation
import os
import TableProTabular
import TableProTabularIO

enum DataFileExportScopeID {
    static let all = "all"
    static let filtered = "filtered"
    static let selected = "selected"
}

enum DataFileImportFormat {
    static let formatId = "csv"
}

struct DataFileImportSnapshot: Equatable, Sendable {
    let url: URL
    let formatId: String
}

extension DataFileController {
    func exportRequest(title: String, suggestedFileName: String) -> DataSourceExportRequest? {
        guard let table, loadState == .loaded else { return nil }
        let ids = columnNames.ids
        let names = columnNames.displayNames
        let typeNames = ids.map { DataFileColumnTypes.filterType(for: kind(of: $0)).rawType ?? "" }
        let scope: (String, String, DataFileExportRows) -> DataSourceExportScope = { id, title, rows in
            let count = rows.count(in: table)
            return DataSourceExportScope(
                id: id,
                title: String(format: title, count.formatted()),
                rowCount: count
            ) {
                DataFileExportDataSource(
                    table: table,
                    columns: ids,
                    columnNames: names,
                    columnTypeNames: typeNames,
                    rows: rows
                )
            }
        }
        var scopes = [scope(DataFileExportScopeID.all, String(localized: "All Rows (%@)"), .all)]
        if let displayKeys {
            scopes.append(scope(DataFileExportScopeID.filtered, String(localized: "Filtered Rows (%@)"), .keys(displayKeys)))
        }
        let selected = selectedRowKeys()
        if !selected.isEmpty {
            scopes.append(scope(DataFileExportScopeID.selected, String(localized: "Selected Rows (%@)"), .keys(selected)))
        }
        return DataSourceExportRequest(
            title: title,
            suggestedFileName: suggestedFileName,
            scopes: scopes,
            initialScopeId: displayKeys == nil ? DataFileExportScopeID.all : DataFileExportScopeID.filtered
        )
    }

    func selectedRowKeys() -> [Int] {
        gridSelection.affectedRows.compactMap { key(forPageRow: $0) }
    }

    func prepareImportSnapshot(completion: @escaping @MainActor (DataFileImportSnapshot) -> Void) {
        guard let table, loadState == .loaded, transferTask == nil else { return }
        let names = columnNames.displayNames
        let ids = columnNames.ids
        let activityID = beginActivity(title: String(localized: "Preparing Import…"), isMutation: false)
        let reporter = progressReporter(for: activityID)
        transferTask = Task { [weak self] in
            do {
                let snapshot = try await Self.writeImportSnapshot(table: table, columns: ids, names: names, progress: reporter)
                guard let self else {
                    try? FileManager.default.removeItem(at: snapshot.url)
                    return
                }
                self.finishTransfer(activityID)
                completion(snapshot)
            } catch {
                self?.finishTransfer(activityID)
                guard !error.isDataFileCancellation else { return }
                Self.logger.error("Import snapshot failed: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
                self?.showMessage(error.localizedDescription)
            }
        }
    }

    private func finishTransfer(_ activityID: UUID) {
        endActivity(activityID)
        transferTask = nil
    }

    @concurrent
    nonisolated static func writeImportSnapshot(
        table: TabularTable,
        columns: [TabularColumnID],
        names: [String],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DataFileImportSnapshot {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableProDataFileImports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).csv")
        let writer = DelimitedWriter(dialect: DelimitedDialect(), source: nil)
        let rows = DataFileSnapshotRows(table: table, columns: columns, names: names, progress: progress)
        do {
            try writer.write(to: url, rows: rows, endsWithLineTerminator: true) { Task.isCancelled }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        }
        return DataFileImportSnapshot(url: url, formatId: DataFileImportFormat.formatId)
    }
}

struct DataFileSnapshotRows: Sequence {
    let table: TabularTable
    let columns: [TabularColumnID]
    let names: [String]
    let progress: @Sendable (Double) -> Void

    func makeIterator() -> Iterator {
        Iterator(rows: self)
    }

    struct Iterator: IteratorProtocol {
        private let rows: DataFileSnapshotRows
        private var emittedHeader = false
        private var nextRow = 0
        private var buffered: [[String]] = []
        private var bufferIndex = 0

        init(rows: DataFileSnapshotRows) {
            self.rows = rows
        }

        mutating func next() -> DelimitedOutputRow? {
            if !emittedHeader {
                emittedHeader = true
                return .fields(rows.names)
            }
            if bufferIndex >= buffered.count {
                refill()
            }
            guard bufferIndex < buffered.count else { return nil }
            defer { bufferIndex += 1 }
            return .fields(buffered[bufferIndex])
        }

        private mutating func refill() {
            buffered.removeAll(keepingCapacity: true)
            bufferIndex = 0
            let total = rows.table.rowCount
            guard nextRow < total else { return }
            let end = Swift.min(nextRow + DataFileExportDataSource.batchSize, total)
            var batch: [[String]] = []
            batch.reserveCapacity(end - nextRow)
            rows.table.scan(columns: rows.columns, rows: nextRow..<end) { _, cells in
                batch.append((0..<cells.count).map { cells.string(at: $0) })
                return true
            }
            buffered = batch
            nextRow = end
            rows.progress(Double(end) / Double(Swift.max(total, 1)))
        }
    }
}
