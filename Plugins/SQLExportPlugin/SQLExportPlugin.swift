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
    var metadataWarnings: [String] = []

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

    func settingsView() -> AnyView? {
        AnyView(SQLExportOptionsView(plugin: self))
    }

    func export(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        destination: URL,
        progress: PluginExportProgress
    ) async throws -> ExportFormatResult {
        ddlFailures = []
        metadataWarnings = []

        let actualDestination: URL
        let gzipTempURL: URL?

        if settings.compressWithGzip {
            let tempSQL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".sql")
            gzipTempURL = tempSQL
            actualDestination = tempSQL
        } else {
            gzipTempURL = nil
            actualDestination = destination
        }

        let (fileHandle, tempURL) = try PluginExportUtilities.beginAtomicWrite(for: actualDestination)
        var committed = false
        defer {
            if !committed {
                PluginExportUtilities.rollbackAtomicWrite(at: tempURL)
            }
        }

        do {
            try writeHeader(to: fileHandle, dataSource: dataSource)
            let databaseName = tables.first?.databaseName ?? ""
            let columnsByTable = await prefetchColumns(databaseName: databaseName, dataSource: dataSource)
            let fkMap = await prefetchForeignKeys(databaseName: databaseName, dataSource: dataSource)
            let sortedTables = topologicallySort(tables, fkMap: fkMap)

            try writeDropPhase(sortedTables: sortedTables, dataSource: dataSource, to: fileHandle)
            try await writeDependentTypesAndSequences(
                tables: tables, dataSource: dataSource, to: fileHandle)
            try await writeCreatePhase(
                sortedTables: sortedTables, dataSource: dataSource, to: fileHandle, progress: progress)
            try await writeDataPhase(
                sortedTables: sortedTables, columnsByTable: columnsByTable,
                dataSource: dataSource, to: fileHandle, progress: progress)
            try writeFinalizationPhase(
                sortedTables: sortedTables, fkMap: fkMap, columnsByTable: columnsByTable,
                dataSource: dataSource, to: fileHandle)

            try fileHandle.close()
            try PluginExportUtilities.commitAtomicWrite(from: tempURL, to: actualDestination)
            committed = true
        } catch {
            try? fileHandle.close()
            throw error
        }

        if settings.compressWithGzip, let gzipSource = gzipTempURL {
            progress.setStatus("Compressing...")

            do {
                defer {
                    try? FileManager.default.removeItem(at: gzipSource)
                }

                try await compressFile(source: gzipSource, destination: destination)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }

        progress.finalizeTable()

        var warnings: [String] = []
        if !ddlFailures.isEmpty {
            let failedTables = ddlFailures.joined(separator: ", ")
            warnings.append("Could not fetch table structure for: \(failedTables)")
        }
        warnings.append(contentsOf: metadataWarnings)
        return ExportFormatResult(warnings: warnings)
    }

    private func writeHeader(
        to fileHandle: FileHandle,
        dataSource: any PluginExportDataSource
    ) throws {
        let dateFormatter = ISO8601DateFormatter()
        try fileHandle.write(contentsOf: "-- TablePro SQL Export\n".toUTF8Data())
        try fileHandle.write(contentsOf: "-- Generated: \(dateFormatter.string(from: Date()))\n".toUTF8Data())
        try fileHandle.write(contentsOf: "-- Database Type: \(dataSource.databaseTypeId)\n\n".toUTF8Data())
    }

    private func prefetchForeignKeys(
        databaseName: String,
        dataSource: any PluginExportDataSource
    ) async -> [String: [PluginForeignKeyInfo]] {
        do {
            return try await dataSource.fetchAllForeignKeys(databaseName: databaseName)
        } catch {
            Self.logger.warning("Failed to fetch foreign keys: \(error.localizedDescription)")
            metadataWarnings.append(
                "Could not fetch foreign keys; FK constraints may be missing from the export.")
            return [:]
        }
    }

    private func prefetchColumns(
        databaseName: String,
        dataSource: any PluginExportDataSource
    ) async -> [String: [PluginColumnInfo]] {
        do {
            return try await dataSource.fetchAllColumns(databaseName: databaseName)
        } catch {
            Self.logger.warning("Failed to fetch columns: \(error.localizedDescription)")
            metadataWarnings.append(
                "Could not fetch column metadata; identity columns and generated columns may not round-trip correctly.")
            return [:]
        }
    }

    private func topologicallySort(
        _ tables: [PluginExportTable],
        fkMap: [String: [PluginForeignKeyInfo]]
    ) -> [PluginExportTable] {
        let nameSet = Set(tables.map { $0.name })
        var indegree: [String: Int] = [:]
        var children: [String: Set<String>] = [:]
        for table in tables { indegree[table.name] = 0 }

        for table in tables {
            let fks = fkMap[table.name] ?? []
            var seenParents: Set<String> = []
            for fk in fks where fk.referencedTable != table.name {
                guard nameSet.contains(fk.referencedTable),
                      !seenParents.contains(fk.referencedTable) else { continue }
                seenParents.insert(fk.referencedTable)
                children[fk.referencedTable, default: []].insert(table.name)
                indegree[table.name, default: 0] += 1
            }
        }

        let byName = Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0) })
        var queue = tables.map { $0.name }.filter { (indegree[$0] ?? 0) == 0 }.sorted()
        var ordered: [String] = []
        while !queue.isEmpty {
            let head = queue.removeFirst()
            ordered.append(head)
            for child in (children[head] ?? []).sorted() {
                indegree[child] = (indegree[child] ?? 0) - 1
                if indegree[child] == 0 {
                    queue.append(child)
                }
            }
        }

        if ordered.count < tables.count {
            let remaining = tables.map { $0.name }
                .filter { name in !ordered.contains(name) }
                .sorted()
            ordered.append(contentsOf: remaining)
        }

        return ordered.compactMap { byName[$0] }
    }

    private func writeDropPhase(
        sortedTables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        to fileHandle: FileHandle
    ) throws {
        let dropTargets = sortedTables.reversed().filter { optionValue($0, at: 1) }
        guard !dropTargets.isEmpty else { return }
        for table in dropTargets {
            let tableRef = dataSource.quoteIdentifier(table.name)
            try fileHandle.write(contentsOf: "DROP TABLE IF EXISTS \(tableRef) CASCADE;\n".toUTF8Data())
        }
        try fileHandle.write(contentsOf: "\n".toUTF8Data())
    }

    private func writeDependentTypesAndSequences(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        to fileHandle: FileHandle
    ) async throws {
        var emittedSequenceNames: Set<String> = []
        var emittedTypeNames: Set<String> = []
        let structureTables = tables.filter { optionValue($0, at: 0) }

        for table in structureTables {
            do {
                let sequences = try await dataSource.fetchDependentSequences(
                    table: table.name, databaseName: table.databaseName)
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
                    table: table.name, databaseName: table.databaseName)
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
    }

    private func writeCreatePhase(
        sortedTables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        to fileHandle: FileHandle,
        progress: PluginExportProgress
    ) async throws {
        for (index, table) in sortedTables.enumerated() where optionValue(table, at: 0) {
            try progress.checkCancellation()
            progress.setCurrentTable(table.qualifiedName, index: index + 1)
            let sanitizedName = PluginExportUtilities.sanitizeForSQLComment(table.name)
            try fileHandle.write(contentsOf: "-- --------------------------------------------------------\n".toUTF8Data())
            try fileHandle.write(contentsOf: "-- Table: \(sanitizedName)\n".toUTF8Data())
            try fileHandle.write(contentsOf: "-- --------------------------------------------------------\n\n".toUTF8Data())
            do {
                let ddl = try await dataSource.fetchTableDDL(
                    table: table.name, databaseName: table.databaseName)
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
    }

    private func writeDataPhase(
        sortedTables: [PluginExportTable],
        columnsByTable: [String: [PluginColumnInfo]],
        dataSource: any PluginExportDataSource,
        to fileHandle: FileHandle,
        progress: PluginExportProgress
    ) async throws {
        for table in sortedTables where optionValue(table, at: 2) && table.tableType != "view" {
            try progress.checkCancellation()
            try await writeTableData(
                table: table,
                columnInfo: columnsByTable[table.name] ?? [],
                dataSource: dataSource,
                to: fileHandle,
                progress: progress)
        }
    }

    private func writeFinalizationPhase(
        sortedTables: [PluginExportTable],
        fkMap: [String: [PluginForeignKeyInfo]],
        columnsByTable: [String: [PluginColumnInfo]],
        dataSource: any PluginExportDataSource,
        to fileHandle: FileHandle
    ) throws {
        var emittedAnything = false
        for table in sortedTables where optionValue(table, at: 0) {
            let fks = fkMap[table.name] ?? []
            let grouped = groupForeignKeysByConstraint(fks)
            for group in grouped {
                let alter = renderAddConstraintFK(table: table, group: group, dataSource: dataSource)
                try fileHandle.write(contentsOf: "\(alter)\n".toUTF8Data())
                emittedAnything = true
            }
        }

        for table in sortedTables where optionValue(table, at: 2) && table.tableType != "view" {
            let columns = columnsByTable[table.name] ?? []
            for column in columns where column.isIdentity {
                let setval = renderIdentitySetval(
                    table: table, columnName: column.name, dataSource: dataSource)
                try fileHandle.write(contentsOf: "\(setval)\n".toUTF8Data())
                emittedAnything = true
            }
        }

        if emittedAnything {
            try fileHandle.write(contentsOf: "\n".toUTF8Data())
        }
    }

    private func renderIdentitySetval(
        table: PluginExportTable,
        columnName: String,
        dataSource: any PluginExportDataSource
    ) -> String {
        let tableRef = qualifiedRef(
            schema: table.databaseName, table: table.name, dataSource: dataSource)
        let columnRef = dataSource.quoteIdentifier(columnName)
        let tableLiteral = dataSource.escapeStringLiteral(tableRef)
        let columnLiteral = dataSource.escapeStringLiteral(columnName)
        return "SELECT pg_catalog.setval("
            + "pg_catalog.pg_get_serial_sequence('\(tableLiteral)', '\(columnLiteral)'), "
            + "GREATEST(COALESCE((SELECT MAX(\(columnRef)) FROM \(tableRef)), 0), 1), "
            + "true);"
    }

    private func groupForeignKeysByConstraint(
        _ fks: [PluginForeignKeyInfo]
    ) -> [[PluginForeignKeyInfo]] {
        var orderedNames: [String] = []
        var groups: [String: [PluginForeignKeyInfo]] = [:]
        for fk in fks {
            if groups[fk.name] == nil {
                orderedNames.append(fk.name)
            }
            groups[fk.name, default: []].append(fk)
        }
        return orderedNames.compactMap { groups[$0] }
    }

    private func qualifiedRef(
        schema: String,
        table: String,
        dataSource: any PluginExportDataSource
    ) -> String {
        let quotedTable = dataSource.quoteIdentifier(table)
        guard !schema.isEmpty else { return quotedTable }
        return "\(dataSource.quoteIdentifier(schema)).\(quotedTable)"
    }

    private func renderAddConstraintFK(
        table: PluginExportTable,
        group: [PluginForeignKeyInfo],
        dataSource: any PluginExportDataSource
    ) -> String {
        let tableRef = qualifiedRef(
            schema: table.databaseName, table: table.name, dataSource: dataSource)
        let constraintName = dataSource.quoteIdentifier(group[0].name)
        let cols = group.map { dataSource.quoteIdentifier($0.column) }.joined(separator: ", ")
        let refCols = group.map { dataSource.quoteIdentifier($0.referencedColumn) }.joined(separator: ", ")
        let refSchema = (group[0].referencedSchema?.isEmpty == false ? group[0].referencedSchema : nil) ?? table.databaseName
        let refTable = qualifiedRef(
            schema: refSchema, table: group[0].referencedTable, dataSource: dataSource)
        let onDelete = group[0].onDelete.uppercased()
        let onUpdate = group[0].onUpdate.uppercased()
        var alter = "ALTER TABLE \(tableRef) ADD CONSTRAINT \(constraintName) FOREIGN KEY (\(cols)) REFERENCES \(refTable) (\(refCols))"
        if onDelete != "NO ACTION" { alter += " ON DELETE \(onDelete)" }
        if onUpdate != "NO ACTION" { alter += " ON UPDATE \(onUpdate)" }
        return alter + ";"
    }

    // MARK: - Private

    private func optionValue(_ table: PluginExportTable, at index: Int) -> Bool {
        guard index < table.optionValues.count else { return true }
        return table.optionValues[index]
    }

    private func writeTableData(
        table: PluginExportTable,
        columnInfo: [PluginColumnInfo],
        dataSource: any PluginExportDataSource,
        to fileHandle: FileHandle,
        progress: PluginExportProgress
    ) async throws {
        let batchSize = settings.batchSize
        var wroteAnyRows = false
        var columns: [String] = []
        var columnTypeNames: [String] = []
        var rowBatch: [[String?]] = []

        let generatedColumnNames = Set(columnInfo.filter { $0.isGenerated }.map { $0.name })
        let usesOverridingSystemValue = columnInfo.contains { $0.identityKind == .always }

        let stream = dataSource.streamRows(table: table.name, databaseName: table.databaseName)
        for try await element in stream {
            try progress.checkCancellation()

            switch element {
            case .header(let header):
                columns = header.columns
                columnTypeNames = header.columnTypeNames ?? []
            case .rows(let rows):
                for row in rows {
                    rowBatch.append(row)
                    if rowBatch.count >= batchSize {
                        try writeInsertStatements(
                            tableName: table.name,
                            columns: columns,
                            columnTypeNames: columnTypeNames,
                            rows: rowBatch,
                            batchSize: batchSize,
                            excludedColumnNames: generatedColumnNames,
                            usesOverridingSystemValue: usesOverridingSystemValue,
                            dataSource: dataSource,
                            to: fileHandle,
                            progress: progress
                        )
                        wroteAnyRows = true
                        rowBatch.removeAll(keepingCapacity: true)
                    }
                }
            }
        }

        if !rowBatch.isEmpty {
            try writeInsertStatements(
                tableName: table.name,
                columns: columns,
                columnTypeNames: columnTypeNames,
                rows: rowBatch,
                batchSize: batchSize,
                excludedColumnNames: generatedColumnNames,
                usesOverridingSystemValue: usesOverridingSystemValue,
                dataSource: dataSource,
                to: fileHandle,
                progress: progress
            )
            wroteAnyRows = true
        }

        if wroteAnyRows {
            try fileHandle.write(contentsOf: "\n".toUTF8Data())
        }
    }

    private func writeInsertStatements(
        tableName: String,
        columns: [String],
        columnTypeNames: [String],
        rows: [[String?]],
        batchSize: Int,
        excludedColumnNames: Set<String>,
        usesOverridingSystemValue: Bool,
        dataSource: any PluginExportDataSource,
        to fileHandle: FileHandle,
        progress: PluginExportProgress
    ) throws {
        let includedColumnIndices = columns.enumerated().compactMap { index, name in
            excludedColumnNames.contains(name) ? nil : index
        }
        guard !includedColumnIndices.isEmpty else { return }

        let tableRef = dataSource.quoteIdentifier(tableName)
        let quotedColumns = includedColumnIndices
            .map { dataSource.quoteIdentifier(columns[$0]) }
            .joined(separator: ", ")
        let overriding = usesOverridingSystemValue ? " OVERRIDING SYSTEM VALUE" : ""
        let insertPrefix = "INSERT INTO \(tableRef) (\(quotedColumns))\(overriding) VALUES\n"

        let numericIndices: Set<Int> = Set(includedColumnIndices.filter { idx in
            idx < columnTypeNames.count && isNumericColumnType(columnTypeNames[idx])
        })

        let effectiveBatchSize = batchSize <= 1 ? 1 : batchSize
        var valuesBatch: [String] = []
        valuesBatch.reserveCapacity(effectiveBatchSize)

        for row in rows {
            try progress.checkCancellation()

            let values = includedColumnIndices.map { colIndex -> String in
                let value = colIndex < row.count ? row[colIndex] : nil
                guard let val = value else { return "NULL" }
                if numericIndices.contains(colIndex) && isNumericLiteral(val) {
                    return val
                }
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

    private func isNumericColumnType(_ typeName: String) -> Bool {
        let numericPrefixes = [
            "int", "bigint", "decimal", "float", "double", "numeric",
            "real", "smallint", "tinyint", "mediumint", "integer", "number"
        ]
        let lower = typeName.lowercased()
        return numericPrefixes.contains { lower.hasPrefix($0) }
    }

    private func isNumericLiteral(_ val: String) -> Bool {
        val.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" || $0 == "e" || $0 == "E" }
    }

    private func compressFile(source: URL, destination: URL) async throws {
        let gzipPath = "/usr/bin/gzip"
        guard FileManager.default.isExecutableFile(atPath: gzipPath) else {
            throw PluginExportError.exportFailed(
                "Compression unavailable: gzip not found at \(gzipPath)"
            )
        }

        let sourcePath = source.standardizedFileURL.path(percentEncoded: false)

        guard FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil) else {
            throw PluginExportError.fileWriteFailed(destination.path(percentEncoded: false))
        }

        let outputHandle: FileHandle
        do {
            outputHandle = try FileHandle(forWritingTo: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        let errorPipe = Pipe()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gzipPath)
        process.arguments = ["-c", sourcePath]
        process.standardOutput = outputHandle
        process.standardError = errorPipe

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    process.terminationHandler = { proc in
                        try? outputHandle.close()
                        let status = proc.terminationStatus
                        if status == 0 {
                            continuation.resume()
                        } else {
                            let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                            let errMsg = String(data: errData, encoding: .utf8)?
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            let message = errMsg.isEmpty
                                ? "Compression failed with exit status \(status)"
                                : "Compression failed with exit status \(status): \(errMsg)"
                            continuation.resume(throwing: PluginExportError.exportFailed(message))
                        }
                    }
                    do {
                        try process.run()
                    } catch {
                        try? outputHandle.close()
                        continuation.resume(throwing: error)
                    }
                }
            } onCancel: {
                process.terminate()
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
