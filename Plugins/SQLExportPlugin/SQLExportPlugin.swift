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

    static let supportedObjectKinds: [PluginExportObjectKind] = [
        .userType, .sequence, .table, .foreignTable, .view, .materializedView,
        .routine, .trigger, .event, .grant
    ]

    /// A routine has no rows, and a grant is a statement rather than an object with a definition to
    /// drop, so those columns are blank slots for those kinds. The positions never move, because
    /// `optionValues` stays aligned with the full column list for every kind.
    static func supportsOption(columnId: String, for kind: PluginExportObjectKind) -> Bool {
        switch columnId {
        case "data": return kind.carriesRows
        case "drop": return kind != .grant
        default: return true
        }
    }

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

    /// Sequence names already written this export. A sequence can be reached twice, once as an
    /// object the user ticked and once as a dependency of a table that defaults from it, and
    /// `CREATE SEQUENCE` a second time fails the restore.
    private var emittedSequenceNames: Set<String> = []

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

    private func ddlRewriter(for dataSource: any PluginExportDataSource) -> SQLExportDDLRewriter {
        SQLExportDDLRewriter(
            dialect: SqlDialect.from(databaseTypeId: dataSource.databaseTypeId),
            excludesAutoIncrementValue: settings.excludeAutoIncrementValue,
            excludesDefiner: settings.excludeDefiner)
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
        emittedSequenceNames = []

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

        /// Compression runs over one file, so a compressed export never splits. Saying so beats
        /// silently gzipping the first part and dropping the rest.
        let splitSize = settings.compressWithGzip ? 0 : settings.splitSizeMegabytes
        if settings.compressWithGzip, settings.splitSizeMegabytes > 0 {
            metadataWarnings.append(String(localized:
                "A compressed export is written as one file, so the split size was not applied."))
        }
        let writer = try SQLExportFileWriter(destination: actualDestination, splitSizeMegabytes: splitSize)
        var committed = false
        defer {
            if !committed { writer.rollback() }
        }

        let snapshot = settings.consistentSnapshot
            ? SQLExportSnapshot(dialect: SqlDialect.from(databaseTypeId: dataSource.databaseTypeId))
            : nil

        do {
            if let snapshot {
                try await snapshot.begin(on: dataSource)
            }
            let rowObjects = tables.filter { $0.kind.carriesRows }
            let definitionObjects = tables.filter { !$0.kind.carriesRows }

            try writeHeader(to: writer, dataSource: dataSource)
            let columnsByTable = await prefetchColumns(tables: rowObjects, dataSource: dataSource)
            let fkMap = await prefetchForeignKeys(tables: rowObjects, dataSource: dataSource)
            let sortedTables = topologicallySort(rowObjects, fkMap: fkMap)
            noteContainerSpan(of: tables)
            try writeDependencyCycleNote(to: writer)

            try writeDropPhase(
                sortedTables: sortedTables, definitionObjects: definitionObjects,
                dataSource: dataSource, to: writer)
            try await writeObjectCreatePhase(
                objects: definitionObjects, kinds: [.userType, .sequence],
                dataSource: dataSource, to: writer, progress: progress)
            try await writeDependentTypesAndSequences(
                tables: rowObjects, dataSource: dataSource, to: writer)
            try await writeCreatePhase(
                sortedTables: sortedTables, dataSource: dataSource, to: writer, progress: progress)
            try await writeDataPhase(
                sortedTables: sortedTables, columnsByTable: columnsByTable,
                dataSource: dataSource, to: writer, progress: progress)
            try writeFinalizationPhase(
                sortedTables: sortedTables, fkMap: fkMap, columnsByTable: columnsByTable,
                dataSource: dataSource, to: writer)
            try await writeObjectCreatePhase(
                objects: definitionObjects,
                kinds: [.view, .materializedView, .routine, .trigger, .event],
                dataSource: dataSource, to: writer, progress: progress)
            try await writeGrantPhase(
                objects: definitionObjects, dataSource: dataSource, to: writer)

            if let snapshot {
                await snapshot.end(on: dataSource)
            }
            try writer.commit()
            committed = true
            if writer.didSplit {
                metadataWarnings.append(String(
                    format: String(localized: "The dump was written as %lld numbered parts. Restore them in order."),
                    Int64(writer.partCount)))
            }
        } catch {
            if let snapshot {
                await snapshot.end(on: dataSource)
            }
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
        to writer: SQLExportFileWriter,
        dataSource: any PluginExportDataSource
    ) throws {
        let dateFormatter = ISO8601DateFormatter()
        try writer.write("-- TablePro SQL Export\n")
        try writer.write("-- Generated: \(dateFormatter.string(from: Date()))\n")
        try writer.write("-- Database Type: \(dataSource.databaseTypeId)\n\n")
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
    private func writeDependencyCycleNote(to writer: SQLExportFileWriter) throws {
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
        try writer.write(note)
    }

    /// Drops run in the reverse of the order the objects are created in, so a dependent goes before
    /// what it depends on: triggers and routines first, then views, then the tables in reverse
    /// topological order, then the sequences and types those tables referenced.
    private func writeDropPhase(
        sortedTables: [PluginExportTable],
        definitionObjects: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        to writer: SQLExportFileWriter
    ) throws {
        let afterTables = definitionObjects
            .filter { $0.kind.dumpOrder > PluginExportObjectKind.table.dumpOrder }
            .sorted { $0.kind.dumpOrder > $1.kind.dumpOrder }
        let beforeTables = definitionObjects
            .filter { $0.kind.dumpOrder < PluginExportObjectKind.table.dumpOrder }
            .sorted { $0.kind.dumpOrder > $1.kind.dumpOrder }
        let dropTargets = (afterTables + Array(sortedTables.reversed()) + beforeTables)
            .filter { optionValue($0, at: 1) && $0.kind != .grant }
        guard !dropTargets.isEmpty else { return }
        for object in dropTargets {
            guard let statement = dropStatement(for: object, dataSource: dataSource) else { continue }
            try writer.write("\(statement)\n")
        }
        try writer.write("\n")
    }

    /// The engine spells its own DROP for the kinds where dialects disagree: PostgreSQL's
    /// `DROP TRIGGER` takes an `ON <table>` clause where MySQL's does not, and MySQL has no
    /// `DROP ROUTINE` at all. Only the table-shaped kinds, which every SQL engine spells the same
    /// way, fall through to the generic form here.
    private func dropStatement(
        for object: PluginExportTable,
        dataSource: any PluginExportDataSource
    ) -> String? {
        if let driverStatement = dataSource.dropStatement(for: object) {
            return driverStatement.hasSuffix(";") ? driverStatement : "\(driverStatement);"
        }
        let keyword = object.kind.dropKeyword
        guard !keyword.isEmpty else { return nil }
        let ref = qualifiedRef(
            schema: object.databaseName, table: object.name, dataSource: dataSource)
        switch object.kind {
        case .trigger, .event, .routine:
            return "\(keyword) IF EXISTS \(dataSource.quoteIdentifier(object.name));"
        default:
            return "\(keyword) IF EXISTS \(ref) CASCADE;"
        }
    }

    private func writeDependentTypesAndSequences(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        to writer: SQLExportFileWriter
    ) async throws {
        var emittedTypeNames: Set<String> = []
        let structureTables = tables.filter { optionValue($0, at: 0) }

        for table in structureTables {
            do {
                let sequences = try await dataSource.fetchDependentSequences(
                    table: table.name, databaseName: table.databaseName)
                for seq in sequences where !emittedSequenceNames.contains(seq.name) {
                    emittedSequenceNames.insert(seq.name)
                    let quotedName = "\"\(seq.name.replacingOccurrences(of: "\"", with: "\"\""))\""
                    try writer.write("DROP SEQUENCE IF EXISTS \(quotedName) CASCADE;\n")
                    try writer.write("\(seq.ddl)\n\n")
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
                    try writer.write("DROP TYPE IF EXISTS \(quotedName) CASCADE;\n")
                    let quotedLabels = enumType.labels.map { "'\(dataSource.escapeStringLiteral($0))'" }
                    try writer.write("CREATE TYPE \(quotedName) AS ENUM (\(quotedLabels.joined(separator: ", ")));\n\n")
                }
            } catch {
                Self.logger.warning("Failed to fetch dependent types for table \(table.name): \(error)")
            }
        }
    }

    private func writeCreatePhase(
        sortedTables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        to writer: SQLExportFileWriter,
        progress: PluginExportProgress
    ) async throws {
        let rewriter = ddlRewriter(for: dataSource)
        for (index, table) in sortedTables.enumerated() where optionValue(table, at: 0) {
            try progress.checkCancellation()
            progress.setCurrentTable(table.qualifiedName, index: index + 1)
            let sanitizedName = PluginExportUtilities.sanitizeForSQLComment(table.name)
            try writer.write("-- --------------------------------------------------------\n")
            try writer.write("-- Table: \(sanitizedName)\n")
            try writer.write("-- --------------------------------------------------------\n\n")
            do {
                let ddl = rewriter.rewrite(
                    try await dataSource.fetchTableDDL(
                        table: table.name, databaseName: table.databaseName))
                try writer.write(ddl)
                if !ddl.hasSuffix(";") {
                    try writer.write(";")
                }
                try writer.write("\n\n")
            } catch {
                ddlFailures.append(sanitizedName)
                let ddlWarning = "Warning: failed to fetch DDL for table \(sanitizedName): \(error)"
                Self.logger.warning("Failed to fetch DDL for table \(sanitizedName): \(error)")
                try writer.write("-- \(PluginExportUtilities.sanitizeForSQLComment(ddlWarning))\n\n")
            }
        }
    }

    /// Writes the definition of every object of the named kinds, in dump order within the group so
    /// a view that another view selects from is created first. A kind the driver cannot produce a
    /// definition for is recorded as a failure and commented into the file rather than aborting the
    /// export: one unreadable routine must not cost the user the whole dump.
    private func writeObjectCreatePhase(
        objects: [PluginExportTable],
        kinds: [PluginExportObjectKind],
        dataSource: any PluginExportDataSource,
        to writer: SQLExportFileWriter,
        progress: PluginExportProgress
    ) async throws {
        let wanted = Set(kinds)
        let targets = objects
            .filter { wanted.contains($0.kind) && optionValue($0, at: 0) }
            .sorted { ($0.kind.dumpOrder, $0.name) < ($1.kind.dumpOrder, $1.name) }
        guard !targets.isEmpty else { return }

        for object in targets {
            try progress.checkCancellation()
            let sanitizedName = PluginExportUtilities.sanitizeForSQLComment(object.name)
            let label = objectCommentLabel(for: object.kind)
            try writer.write("-- --------------------------------------------------------\n")
            try writer.write("-- \(label): \(sanitizedName)\n")
            try writer.write("-- --------------------------------------------------------\n\n")
            if object.kind == .sequence {
                guard emittedSequenceNames.insert(object.name).inserted else { continue }
            }
            do {
                let ddl = ddlRewriter(for: dataSource).rewrite(try await dataSource.fetchObjectDDL(object))
                try writer.write(ddl)
                if !ddl.hasSuffix(";") {
                    try writer.write(";")
                }
                try writer.write("\n\n")
            } catch {
                ddlFailures.append(sanitizedName)
                Self.logger.warning("Failed to fetch DDL for \(sanitizedName): \(error)")
                let warning = "Warning: failed to fetch definition for \(label.lowercased()) \(sanitizedName): \(error)"
                try writer.write("-- \(PluginExportUtilities.sanitizeForSQLComment(warning))\n\n")
            }
        }
    }

    /// Grants come last, because every object they name has to exist first.
    private func writeGrantPhase(
        objects: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        to writer: SQLExportFileWriter
    ) async throws {
        let principals = objects
            .filter { $0.kind == .grant && optionValue($0, at: 0) }
            .sorted { $0.name < $1.name }
        guard !principals.isEmpty else { return }

        try writer.write("-- --------------------------------------------------------\n")
        try writer.write("-- Privileges\n")
        try writer.write("-- --------------------------------------------------------\n\n")

        for principal in principals {
            do {
                let statements = try await dataSource.fetchGrantStatements(
                    principal: principal.name, host: principal.identity)
                guard !statements.isEmpty else { continue }
                for statement in statements {
                    let terminated = statement.hasSuffix(";") ? statement : "\(statement);"
                    try writer.write("\(terminated)\n")
                }
            } catch {
                let sanitized = PluginExportUtilities.sanitizeForSQLComment(principal.name)
                ddlFailures.append(sanitized)
                Self.logger.warning("Failed to fetch grants for \(sanitized): \(error)")
                let warning = "Warning: failed to fetch privileges for \(sanitized): \(error)"
                try writer.write("-- \(PluginExportUtilities.sanitizeForSQLComment(warning))\n")
            }
        }
        try writer.write("\n")
    }

    private func objectCommentLabel(for kind: PluginExportObjectKind) -> String {
        switch kind {
        case .view: return "View"
        case .materializedView: return "Materialized view"
        case .routine: return "Routine"
        case .trigger: return "Trigger"
        case .event: return "Event"
        case .sequence: return "Sequence"
        case .userType: return "Type"
        case .foreignTable: return "Foreign table"
        case .grant: return "Privileges"
        default: return "Table"
        }
    }

    private func writeDataPhase(
        sortedTables: [PluginExportTable],
        columnsByTable: [String: [PluginColumnInfo]],
        dataSource: any PluginExportDataSource,
        to writer: SQLExportFileWriter,
        progress: PluginExportProgress
    ) async throws {
        for table in sortedTables where optionValue(table, at: 2) && table.kind.carriesRows {
            try progress.checkCancellation()
            try await writeTableData(
                table: table,
                columnInfo: columnsByTable[node(for: table).identifier] ?? [],
                dataSource: dataSource,
                to: writer,
                progress: progress)
        }
    }

    private func writeFinalizationPhase(
        sortedTables: [PluginExportTable],
        fkMap: [String: [PluginForeignKeyInfo]],
        columnsByTable: [String: [PluginColumnInfo]],
        dataSource: any PluginExportDataSource,
        to writer: SQLExportFileWriter
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
                    try writer.write("\(alter)\n")
                    emittedAnything = true
                }
            }
        }

        /// `setval` and `pg_get_serial_sequence` are PostgreSQL's own, so the sequence is only
        /// rewound on PostgreSQL. Every other engine reports its identity columns the same way and
        /// would take the statement as a syntax error.
        if SqlDialect.from(databaseTypeId: dataSource.databaseTypeId) == .postgres {
            for table in sortedTables where optionValue(table, at: 2) && table.kind.carriesRows {
                let columns = columnsByTable[node(for: table).identifier] ?? []
                for column in columns where column.isIdentity {
                    let setval = renderIdentitySetval(
                        table: table, columnName: column.name, dataSource: dataSource)
                    try writer.write("\(setval)\n")
                    emittedAnything = true
                }
            }
        }

        if emittedAnything {
            try writer.write("\n")
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
        to writer: SQLExportFileWriter,
        progress: PluginExportProgress
    ) async throws {
        let batchSize = settings.batchSize
        var wroteAnyRows = false
        var columns: [String] = []
        var columnTypeNames: [String] = []
        var rowBatch: [[PluginCellValue]] = []

        let generatedColumnNames = Set(columnInfo.filter { $0.isGenerated }.map { $0.name })
        let primaryKeyColumns = columnInfo.filter(\.isPrimaryKey).map(\.name)
        let usesOverridingSystemValue = SqlDialect.from(databaseTypeId: dataSource.databaseTypeId) == .postgres
            && columnInfo.contains { $0.identityKind == .always }
        let tableRef = qualifiedRef(
            schema: table.databaseName, table: table.name, dataSource: dataSource)
        /// SQL Server refuses an explicit value for an IDENTITY column unless the table is opened
        /// for it first. The rows are exported with their keys, so without this the dump restores
        /// nothing: every INSERT for the table is rejected while the export itself reported success.
        let needsIdentityInsert = dataSource.databaseTypeId == "SQL Server"
            && columnInfo.contains(where: \.isIdentity)

        if !table.rowScope.isUnrestricted {
            let scopeNote = PluginExportUtilities.sanitizeForSQLComment(table.rowScope.summary)
            try writer.write("-- Rows narrowed to: \(scopeNote)\n")
        }
        if table.rowScope.hasRejectedFilter {
            metadataWarnings.append(String(
                format: String(localized:
                    "The row filter on %@ was not a single expression, so every row was exported."),
                table.name))
        }
        let stream = dataSource.streamRows(for: table)
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
                            try writer.write("SET IDENTITY_INSERT \(tableRef) ON;\n")
                        }
                        try writeInsertStatements(
                            tableRef: tableRef,
                            columns: columns,
                            columnTypeNames: columnTypeNames,
                            rows: rowBatch,
                            batchSize: batchSize,
                            excludedColumnNames: generatedColumnNames,
                            primaryKeyColumns: primaryKeyColumns,
                            usesOverridingSystemValue: usesOverridingSystemValue,
                            dataSource: dataSource,
                            to: writer,
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
                try writer.write("SET IDENTITY_INSERT \(tableRef) ON;\n")
            }
            try writeInsertStatements(
                tableRef: tableRef,
                columns: columns,
                columnTypeNames: columnTypeNames,
                rows: rowBatch,
                batchSize: batchSize,
                excludedColumnNames: generatedColumnNames,
                primaryKeyColumns: primaryKeyColumns,
                usesOverridingSystemValue: usesOverridingSystemValue,
                dataSource: dataSource,
                to: writer,
                progress: progress
            )
            wroteAnyRows = true
        }

        if wroteAnyRows, needsIdentityInsert {
            try writer.write("SET IDENTITY_INSERT \(tableRef) OFF;\n")
        }

        if wroteAnyRows {
            try writer.write("\n")
        }
    }

    private func writeInsertStatements(
        tableRef: String,
        columns: [String],
        columnTypeNames: [String],
        rows: [[PluginCellValue]],
        batchSize: Int,
        excludedColumnNames: Set<String>,
        primaryKeyColumns: [String],
        usesOverridingSystemValue: Bool,
        dataSource: any PluginExportDataSource,
        to writer: SQLExportFileWriter,
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
        let rendered = SQLExportInsertRenderer(
            dialect: SqlDialect.from(databaseTypeId: dataSource.databaseTypeId),
            quoteIdentifier: dataSource.quoteIdentifier
        ).render(
            mode: settings.insertMode,
            tableRef: tableRef,
            quotedColumns: quotedColumns,
            overriding: overriding,
            columnNames: includedColumnIndices.map { columns[$0] },
            primaryKeyColumns: primaryKeyColumns
        )
        if let warning = rendered.warning, !metadataWarnings.contains(warning) {
            metadataWarnings.append(warning)
        }
        let insertPrefix = rendered.prefix
        let insertSuffix = rendered.suffix

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
                let statement = insertPrefix + valuesBatch.joined(separator: ",\n") + insertSuffix + ";\n\n"
                try writer.write(statement)
                valuesBatch.removeAll(keepingCapacity: true)
            }

            progress.incrementRow()
        }

        if !valuesBatch.isEmpty {
            let statement = insertPrefix + valuesBatch.joined(separator: ",\n") + insertSuffix + ";\n\n"
            try writer.write(statement)
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
