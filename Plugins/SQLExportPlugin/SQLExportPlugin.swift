//
//  SQLExportPlugin.swift
//  SQLExportPlugin
//

import Foundation
import os
import SwiftUI
import TableProPluginKit

@Observable
final class SQLExportPlugin: ExportFormatPlugin, SettablePlugin {
    static let pluginName = "SQL Export"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Export data to SQL format"
    static let formatId = "sql"
    static let formatDisplayName = "SQL"
    static let defaultFileExtension = "sql"
    static let iconName = "text.page"
    static let excludedDatabaseTypeIds = ["MongoDB", "Redis"]

    static let perTableOptionColumns: [PluginExportOptionColumn] = [
        PluginExportOptionColumn(id: "structure", label: "Structure", width: 56),
        PluginExportOptionColumn(id: "drop", label: "Drop", width: 44),
        PluginExportOptionColumn(id: "data", label: "Data", width: 44)
    ]

    typealias Settings = SQLExportOptions
    static let settingsStorageId = "sql"

    var settings = SQLExportOptions() {
        didSet { saveSettings() }
    }

    var ddlFailures: [String] = []

    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLExportPlugin")

    required init() { loadSettings() }

    func defaultTableOptionValues() -> [Bool] {
        [true, true, true]
    }

    func isTableExportable(optionValues: [Bool]) -> Bool {
        optionValues.contains(true)
    }

    var currentFileExtension: String {
        settings.compressWithGzip ? "sql.gz" : "sql"
    }

    var warnings: [String] {
        guard !ddlFailures.isEmpty else { return [] }
        let failedTables = ddlFailures.joined(separator: ", ")
        return ["Could not fetch table structure for: \(failedTables)"]
    }

    func settingsView() -> AnyView? {
        AnyView(SQLExportOptionsView(plugin: self))
    }

    func export(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        destination: URL,
        progress: PluginExportProgress
    ) async throws {
        ddlFailures = []

        // For gzip, write to temp file first then compress
        let targetURL: URL
        let tempFileURL: URL?

        if settings.compressWithGzip {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".sql")
            tempFileURL = tempURL
            targetURL = tempURL
        } else {
            tempFileURL = nil
            targetURL = destination
        }

        let fileHandle = try PluginExportUtilities.createFileHandle(at: targetURL)

        do {
            let dateFormatter = ISO8601DateFormatter()
            try fileHandle.write(contentsOf: "-- TablePro SQL Export\n".toUTF8Data())
            try fileHandle.write(contentsOf: "-- Generated: \(dateFormatter.string(from: Date()))\n".toUTF8Data())
            try fileHandle.write(contentsOf: "-- Database Type: \(dataSource.databaseTypeId)\n\n".toUTF8Data())

            // Collect dependent sequences and enum types (PostgreSQL)
            var emittedSequenceNames: Set<String> = []
            var emittedTypeNames: Set<String> = []
            let structureTables = tables.filter { optionValue($0, at: 0) }

            for table in structureTables {
                do {
                    let sequences = try await dataSource.fetchDependentSequences(
                        table: table.name,
                        databaseName: table.databaseName
                    )
                    for seq in sequences where !emittedSequenceNames.contains(seq.name) {
                        emittedSequenceNames.insert(seq.name)
                        let quotedName = "\"\(seq.name.replacingOccurrences(of: "\"", with: "\"\""))\""
                        try fileHandle.write(contentsOf: "DROP SEQUENCE IF EXISTS \(quotedName) CASCADE;\n".toUTF8Data())
                        try fileHandle.write(contentsOf: "\(seq.ddl)\n\n".toUTF8Data())
                    }
                } catch {
                    Self.logger.warning("Failed to fetch dependent sequences for table \(table.name): \(error)")
                }

                do {
                    let enumTypes = try await dataSource.fetchDependentTypes(
                        table: table.name,
                        databaseName: table.databaseName
                    )
                    for enumType in enumTypes where !emittedTypeNames.contains(enumType.name) {
                        emittedTypeNames.insert(enumType.name)
                        let quotedName = "\"\(enumType.name.replacingOccurrences(of: "\"", with: "\"\""))\""
                        try fileHandle.write(contentsOf: "DROP TYPE IF EXISTS \(quotedName) CASCADE;\n".toUTF8Data())
                        let quotedLabels = enumType.labels.map { "'\(dataSource.escapeStringLiteral($0))'" }
                        try fileHandle.write(contentsOf: "CREATE TYPE \(quotedName) AS ENUM (\(quotedLabels.joined(separator: ", ")));\n\n".toUTF8Data())
                    }
                } catch {
                    Self.logger.warning("Failed to fetch dependent types for table \(table.name): \(error)")
                }
            }

            for (index, table) in tables.enumerated() {
                try progress.checkCancellation()

                progress.setCurrentTable(table.qualifiedName, index: index + 1)

                let includeStructure = optionValue(table, at: 0)
                let includeDrop = optionValue(table, at: 1)
                let includeData = optionValue(table, at: 2)

                let tableRef = dataSource.quoteIdentifier(table.name)

                let sanitizedName = PluginExportUtilities.sanitizeForSQLComment(table.name)
                try fileHandle.write(contentsOf: "-- --------------------------------------------------------\n".toUTF8Data())
                try fileHandle.write(contentsOf: "-- Table: \(sanitizedName)\n".toUTF8Data())
                try fileHandle.write(contentsOf: "-- --------------------------------------------------------\n\n".toUTF8Data())

                if includeDrop {
                    try fileHandle.write(contentsOf: "DROP TABLE IF EXISTS \(tableRef);\n\n".toUTF8Data())
                }

                if includeStructure {
                    do {
                        let ddl = try await dataSource.fetchTableDDL(
                            table: table.name,
                            databaseName: table.databaseName
                        )
                        try fileHandle.write(contentsOf: ddl.toUTF8Data())
                        if !ddl.hasSuffix(";") {
                            try fileHandle.write(contentsOf: ";".toUTF8Data())
                        }
                        try fileHandle.write(contentsOf: "\n\n".toUTF8Data())
                    } catch {
                        ddlFailures.append(sanitizedName)
                        let ddlWarning = "Warning: failed to fetch DDL for table \(sanitizedName): \(error)"
                        Self.logger.warning("Failed to fetch DDL for table \(sanitizedName): \(error)")
                        try fileHandle.write(contentsOf: "-- \(PluginExportUtilities.sanitizeForSQLComment(ddlWarning))\n\n".toUTF8Data())
                    }
                }

                if includeData {
                    let batchSize = settings.batchSize
                    var offset = 0
                    var wroteAnyRows = false

                    while true {
                        try progress.checkCancellation()

                        let query = SQLExportHelpers.buildPaginatedQuery(
                            tableRef: tableRef,
                            databaseTypeId: dataSource.databaseTypeId,
                            offset: offset,
                            limit: batchSize
                        )
                        let result = try await dataSource.execute(query: query)

                        if result.rows.isEmpty { break }

                        try writeInsertStatements(
                            tableName: table.name,
                            columns: result.columns,
                            rows: result.rows,
                            batchSize: batchSize,
                            dataSource: dataSource,
                            to: fileHandle,
                            progress: progress
                        )

                        wroteAnyRows = true
                        offset += batchSize
                    }

                    if wroteAnyRows {
                        try fileHandle.write(contentsOf: "\n".toUTF8Data())
                    }
                }
            }

            try fileHandle.close()
        } catch {
            try? fileHandle.close()
            if let tempURL = tempFileURL {
                try? FileManager.default.removeItem(at: tempURL)
            }
            throw error
        }

        // Handle gzip compression
        if settings.compressWithGzip, let tempURL = tempFileURL {
            progress.setStatus("Compressing...")

            do {
                defer {
                    try? FileManager.default.removeItem(at: tempURL)
                }

                try await compressFile(source: tempURL, destination: destination)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }

        progress.finalizeTable()
    }

    // MARK: - Private

    private func optionValue(_ table: PluginExportTable, at index: Int) -> Bool {
        guard index < table.optionValues.count else { return true }
        return table.optionValues[index]
    }

    private func writeInsertStatements(
        tableName: String,
        columns: [String],
        rows: [[String?]],
        batchSize: Int,
        dataSource: any PluginExportDataSource,
        to fileHandle: FileHandle,
        progress: PluginExportProgress
    ) throws {
        let tableRef = dataSource.quoteIdentifier(tableName)
        let quotedColumns = columns
            .map { dataSource.quoteIdentifier($0) }
            .joined(separator: ", ")

        let insertPrefix = "INSERT INTO \(tableRef) (\(quotedColumns)) VALUES\n"

        let effectiveBatchSize = batchSize <= 1 ? 1 : batchSize
        var valuesBatch: [String] = []
        valuesBatch.reserveCapacity(effectiveBatchSize)

        for row in rows {
            try progress.checkCancellation()

            let values = row.map { value -> String in
                guard let val = value else { return "NULL" }
                let escaped = dataSource.escapeStringLiteral(val)
                return "'\(escaped)'"
            }.joined(separator: ", ")

            valuesBatch.append("  (\(values))")

            if valuesBatch.count >= effectiveBatchSize {
                let statement = insertPrefix + valuesBatch.joined(separator: ",\n") + ";\n\n"
                try fileHandle.write(contentsOf: statement.toUTF8Data())
                valuesBatch.removeAll(keepingCapacity: true)
            }

            progress.incrementRow()
        }

        if !valuesBatch.isEmpty {
            let statement = insertPrefix + valuesBatch.joined(separator: ",\n") + ";\n\n"
            try fileHandle.write(contentsOf: statement.toUTF8Data())
        }
    }

    private func compressFile(source: URL, destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let gzipPath = "/usr/bin/gzip"
            guard FileManager.default.isExecutableFile(atPath: gzipPath) else {
                throw PluginExportError.exportFailed(
                    "Compression unavailable: gzip not found at \(gzipPath)"
                )
            }

            guard FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil) else {
                throw PluginExportError.fileWriteFailed(destination.path(percentEncoded: false))
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: gzipPath)

            let sanitizedSourcePath = source.standardizedFileURL.path(percentEncoded: false)

            if sanitizedSourcePath.contains("\0") ||
                sanitizedSourcePath.contains(where: { $0.isNewline }) {
                throw PluginExportError.exportFailed("Invalid source path for compression")
            }

            process.arguments = ["-c", sanitizedSourcePath]
            let outputFile = try FileHandle(forWritingTo: destination)
            defer { try? outputFile.close() }
            process.standardOutput = outputFile

            let errorPipe = Pipe()
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let status = process.terminationStatus
            guard status == 0 else {
                try? outputFile.close()

                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorString = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                let message: String
                if errorString.isEmpty {
                    message = "Compression failed with exit status \(status)"
                } else {
                    message = "Compression failed with exit status \(status): \(errorString)"
                }

                throw PluginExportError.exportFailed(message)
            }
        }.value
    }
}
