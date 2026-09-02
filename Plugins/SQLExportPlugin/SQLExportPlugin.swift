//
//  SQLExportPlugin.swift
//  SQLExportPlugin
//

import Foundation
import os
import SwiftUI
import TableProPluginKit

@Observable
final class SQLExportPlugin: ExportFormatPlugin, SettablePlugin, @unchecked Sendable {
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

    /// The tables a foreign key cycle left the ordering unable to place. They keep the order the
    /// export tree gave them, which is the only order left once no parent-first one exists, and
    /// the dump says so rather than reading as if it were restorable with the checks on.
    var tablesUnorderedByCycle: [String] = []

    /// A dump refers to its tables unqualified whenever every selected table lives in one
    /// container, which is what makes it restorable into any database. Qualifying became necessary
    /// only once an export could span two containers holding the same table name: unqualified there
    /// means one schema's rows land in the other's table. The CREATE statements come back from the
    /// driver verbatim and cannot be qualified without rewriting engine DDL, so a spanning export
    /// says so rather than shipping a dump whose three phases disagree.
    var exportSpansContainers = false

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

    @MainActor
    func settingsView() -> AnyView? {
        AnyView(SQLExportOptionsView(plugin: self))
    }

    func resetSettingsToDefaults() {
        settings = SQLExportOptions()
    }

    func export(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        destination: URL,
        progress: PluginExportProgress
    ) async throws -> ExportFormatResult {
        ddlFailures = []
        metadataWarnings = []
        exportSpansContainers = false
        tablesUnorderedByCycle = []

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
            let columnsByTable = await prefetchColumns(tables: tables, dataSource: dataSource)
            let fkMap = await prefetchForeignKeys(tables: tables, dataSource: dataSource)
            let sortedTables = topologicallySort(tables, fkMap: fkMap)
            noteContainerSpan(of: sortedTables)
            try writeDependencyCycleNote(to: fileHandle)

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
            warnings.append(String(
                format: String(localized: "Could not fetch table structure for: %@"), failedTables))
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

    private struct ExportGroup {
        let databaseName: String
        let container: String?
    }

    private func exportGroups(in tables: [PluginExportTable]) -> [ExportGroup] {
        var seen: Set<String> = []
        return tables
            .filter { seen.insert($0.databaseName).inserted }
            .map { ExportGroup(databaseName: $0.databaseName, container: $0.containerName) }
    }

    private func node(for table: PluginExportTable) -> ForeignKeyTopologicalSort.Table {
        ForeignKeyTopologicalSort.Table(name: table.name, schema: table.containerName)
    }

    private func metadataKey(_ tableName: String, in group: ExportGroup) -> String {
        ForeignKeyTopologicalSort.Table(name: tableName, schema: group.container).identifier
    }

    private func prefetchForeignKeys(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource
    ) async -> [String: [PluginForeignKeyInfo]] {
        var merged: [String: [PluginForeignKeyInfo]] = [:]
        var anyGroupFailed = false
        for group in exportGroups(in: tables) {
            do {
                let fetched = try await dataSource.fetchAllForeignKeys(databaseName: group.databaseName)
                for (tableName, foreignKeys) in fetched {
                    merged[metadataKey(tableName, in: group)] = foreignKeys
                }
            } catch {
                Self.logger.warning("Failed to fetch foreign keys: \(error.localizedDescription)")
                anyGroupFailed = true
            }
        }
        if anyGroupFailed {
            metadataWarnings.append(String(localized:
                "Could not fetch foreign keys, so foreign key constraints may be missing from the export."))
        }
        return merged
    }

    private func prefetchColumns(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource
    ) async -> [String: [PluginColumnInfo]] {
        var merged: [String: [PluginColumnInfo]] = [:]
        var anyGroupFailed = false
        for group in exportGroups(in: tables) {
            do {
                let fetched = try await dataSource.fetchAllColumns(databaseName: group.databaseName)
                for (tableName, columns) in fetched {
                    merged[metadataKey(tableName, in: group)] = columns
                }
            } catch {
                Self.logger.warning("Failed to fetch columns: \(error.localizedDescription)")
                anyGroupFailed = true
            }
        }
        if anyGroupFailed {
            metadataWarnings.append(String(localized:
                "Could not fetch column metadata, so identity and generated columns may not round-trip correctly."))
        }
        return merged
    }

    private func topologicallySort(
        _ tables: [PluginExportTable],
        fkMap: [String: [PluginForeignKeyInfo]]
    ) -> [PluginExportTable] {
        let byIdentifier = Dictionary(
            tables.map { (node(for: $0).identifier, $0) },
            uniquingKeysWith: { first, _ in first })
        let ordering = ForeignKeyTopologicalSort.order(tables.map { node(for: $0) }, foreignKeysByTable: fkMap)
        tablesUnorderedByCycle = ordering.unorderedByCycle.map { $0.identifier }
        return ordering.tables.compactMap { byIdentifier[$0.identifier] }
    }

    /// The warning states what the file is rather than prescribing a remedy, because the remedy is
    /// not the same everywhere: `foreignKeyDisableStatements` is nil on SQL Server, Oracle,
    /// Snowflake and DuckDB, so telling every user to import with the checks off would be wrong on
    /// the engines that cannot turn them off.
    private func writeDependencyCycleNote(to fileHandle: FileHandle) throws {
        guard !tablesUnorderedByCycle.isEmpty else { return }
        let names = tablesUnorderedByCycle.joined(separator: ", ")
        metadataWarnings.append(String(
            format: String(localized: """
                Foreign keys between %@ reference each other, so no order puts every parent before \
                its children. Those tables are written in the order they were listed, and the dump \
                cannot be restored while foreign keys are enforced.
                """),
            names))
        let note = "-- Warning: \(PluginExportUtilities.sanitizeForSQLComment(names)) reference each other.\n"
            + "-- No parent-first order exists, so they are written in the order they were listed.\n\n"
        try fileHandle.write(contentsOf: note.toUTF8Data())
    }

    private func writeDropPhase(
        sortedTables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        to fileHandle: FileHandle
    ) throws {
        let dropTargets = sortedTables.reversed().filter { optionValue($0, at: 1) }
        guard !dropTargets.isEmpty else { return }
        for table in dropTargets {
            let tableRef = qualifiedRef(
                schema: table.databaseName, table: table.name, dataSource: dataSource)
            let keyword = dropStatementKeyword(for: table.tableType)
            try fileHandle.write(contentsOf: "\(keyword) IF EXISTS \(tableRef) CASCADE;\n".toUTF8Data())
        }
        try fileHandle.write(contentsOf: "\n".toUTF8Data())
    }

    private func dropStatementKeyword(for tableType: String) -> String {
        switch tableType {
        case "view": return "DROP VIEW"
        case "materialized view": return "DROP MATERIALIZED VIEW"
        case "foreign table": return "DROP FOREIGN TABLE"
        default: return "DROP TABLE"
        }
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
                columnInfo: columnsByTable[node(for: table).identifier] ?? [],
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
        /// A driver that hands back the server's own CREATE statement has already declared these
        /// constraints inline, so adding them again names each one twice: MySQL and SQL Server
        /// reject the duplicate, and SQLite has no ADD CONSTRAINT to reject it with. The phase
        /// exists for the drivers whose DDL leaves foreign keys out, PostgreSQL and Oracle.
        if !dataSource.tableDDLIncludesForeignKeys {
            for table in sortedTables where optionValue(table, at: 0) {
                let fks = fkMap[node(for: table).identifier] ?? []
                let grouped = groupForeignKeysByConstraint(fks)
                for group in grouped {
                    let alter = renderAddConstraintFK(table: table, group: group, dataSource: dataSource)
                    try fileHandle.write(contentsOf: "\(alter)\n".toUTF8Data())
                    emittedAnything = true
                }
            }
        }

        /// `setval` and `pg_get_serial_sequence` are PostgreSQL's own, so the sequence is only
        /// rewound on PostgreSQL. Every other engine reports its identity columns the same way and
        /// would take the statement as a syntax error.
        if SqlDialect.from(databaseTypeId: dataSource.databaseTypeId) == .postgres {
            for table in sortedTables where optionValue(table, at: 2) && table.tableType != "view" {
                let columns = columnsByTable[node(for: table).identifier] ?? []
                for column in columns where column.isIdentity {
                    let setval = renderIdentitySetval(
                        table: table, columnName: column.name, dataSource: dataSource)
                    try fileHandle.write(contentsOf: "\(setval)\n".toUTF8Data())
                    emittedAnything = true
                }
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

    private func noteContainerSpan(of tables: [PluginExportTable]) {
        let containers = Set(tables.map { $0.containerName ?? "" })
        exportSpansContainers = containers.count > 1
        guard exportSpansContainers else { return }
        metadataWarnings.append(String(
            format: String(localized: """
                This export spans %lld databases or schemas. Table references are qualified, but \
                CREATE TABLE comes from the server unqualified, so restore it into the matching \
                database or schema.
                """),
            Int64(containers.count)))
    }

    private func qualifiedRef(
        schema: String,
        table: String,
        dataSource: any PluginExportDataSource
    ) -> String {
        let quotedTable = dataSource.quoteIdentifier(table)
        guard exportSpansContainers, !schema.isEmpty else { return quotedTable }
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
        var rowBatch: [[PluginCellValue]] = []

        let generatedColumnNames = Set(columnInfo.filter { $0.isGenerated }.map { $0.name })
        let usesOverridingSystemValue = SqlDialect.from(databaseTypeId: dataSource.databaseTypeId) == .postgres
            && columnInfo.contains { $0.identityKind == .always }
        let tableRef = qualifiedRef(
            schema: table.databaseName, table: table.name, dataSource: dataSource)
        /// SQL Server refuses an explicit value for an IDENTITY column unless the table is opened
        /// for it first. The rows are exported with their keys, so without this the dump restores
        /// nothing: every INSERT for the table is rejected while the export itself reported success.
        let needsIdentityInsert = dataSource.databaseTypeId == "SQL Server"
            && columnInfo.contains(where: \.isIdentity)

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
                        if needsIdentityInsert, !wroteAnyRows {
                            try fileHandle.write(contentsOf: "SET IDENTITY_INSERT \(tableRef) ON;\n".toUTF8Data())
                        }
                        try writeInsertStatements(
                            tableRef: tableRef,
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
            if needsIdentityInsert, !wroteAnyRows {
                try fileHandle.write(contentsOf: "SET IDENTITY_INSERT \(tableRef) ON;\n".toUTF8Data())
            }
            try writeInsertStatements(
                tableRef: tableRef,
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

        if wroteAnyRows, needsIdentityInsert {
            try fileHandle.write(contentsOf: "SET IDENTITY_INSERT \(tableRef) OFF;\n".toUTF8Data())
        }

        if wroteAnyRows {
            try fileHandle.write(contentsOf: "\n".toUTF8Data())
        }
    }

    private func writeInsertStatements(
        tableRef: String,
        columns: [String],
        columnTypeNames: [String],
        rows: [[PluginCellValue]],
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

        let quotedColumns = includedColumnIndices
            .map { dataSource.quoteIdentifier(columns[$0]) }
            .joined(separator: ", ")
        let overriding = usesOverridingSystemValue ? " OVERRIDING SYSTEM VALUE" : ""
        let insertPrefix = "INSERT INTO \(tableRef) (\(quotedColumns))\(overriding) VALUES\n"

        let numericIndices: Set<Int> = Set(includedColumnIndices.filter { idx in
            idx < columnTypeNames.count && PluginExportUtilities.isNumericColumnType(columnTypeNames[idx])
        })

        let effectiveBatchSize = batchSize <= 1 ? 1 : batchSize
        var valuesBatch: [String] = []
        valuesBatch.reserveCapacity(effectiveBatchSize)

        for row in rows {
            try progress.checkCancellation()

            let values = includedColumnIndices.map { colIndex -> String in
                guard colIndex < row.count else { return "NULL" }
                let cell = row[colIndex]
                switch cell {
                case .null:
                    return "NULL"
                case .bytes(let data):
                    let hex = data.map { String(format: "%02X", $0) }.joined()
                    return "X'\(hex)'"
                case .text(let val):
                    if numericIndices.contains(colIndex) && PluginNumericLiteral.isValid(val) {
                        return val
                    }
                    let escaped = dataSource.escapeStringLiteral(val)
                    return "'\(escaped)'"
                }
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
