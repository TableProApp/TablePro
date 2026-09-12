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

    /// Kept apart from `ddlFailures` because the summary that reads it says "table structure", and
    /// a table whose `CREATE TABLE` came back fine and only lost its indexes is a different thing
    /// to tell the user about.
    var indexFailures: [String] = []

    /// Kept apart for the same reason `indexFailures` is: an object whose definition came back fine
    /// and only lost its comments is a different thing to tell the user about.
    var commentFailures: [String] = []
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
        indexFailures = []
        commentFailures = []
        metadataWarnings = []
        exportSpansContainers = false
        tablesUnorderedByCycle = []
        emittedSequenceNames = []

        /// Read once, because `PluginManager` hands every window the same plugin instance and a
        /// second window's options pane can write `settings` while this export is still running. A
        /// cap re-read per table would let one export start at a mebibyte and finish unbounded.
        let options = settings
        var statementTally = SQLExportStatementTally()

        let actualDestination: URL
        let gzipTempURL: URL?

        if options.compressWithGzip {
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
        let splitSize = options.compressWithGzip ? 0 : options.splitSizeMegabytes
        if options.compressWithGzip, options.splitSizeMegabytes > 0 {
            metadataWarnings.append(String(localized:
                "A compressed export is written as one file, so the split size was not applied."))
        }
        let writer = try SQLExportFileWriter(
            destination: actualDestination,
            splitSizeMegabytes: splitSize,
            encodingDeclaration: .forDatabaseType(dataSource.databaseTypeId)
        )
        var committed = false
        defer {
            if !committed { writer.rollback() }
        }

        let snapshot = options.consistentSnapshot
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
            statementTally = try await writeDataPhase(
                sortedTables: sortedTables, columnsByTable: columnsByTable, options: options,
                dataSource: dataSource, to: writer, progress: progress)
            try await writeFinalizationPhase(
                sortedTables: sortedTables, fkMap: fkMap, columnsByTable: columnsByTable,
                dataSource: dataSource, to: writer, progress: progress)
            try await writeObjectCreatePhase(
                objects: definitionObjects,
                kinds: [.view, .materializedView, .routine, .trigger, .event],
                dataSource: dataSource, to: writer, progress: progress)
            /// A materialized view carries its own indexes, and PostgreSQL needs a unique one
            /// before `REFRESH MATERIALIZED VIEW CONCURRENTLY` will run. It holds no rows the
            /// export streams, so it is not in `sortedTables` and gets its own pass here, once the
            /// phase above has created it.
            if try await writeIndexPhase(
                objects: definitionObjects.filter { $0.kind == .materializedView },
                dataSource: dataSource, to: writer, progress: progress) {
                try writer.write("\n")
            }
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

        if options.compressWithGzip, let gzipSource = gzipTempURL {
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
        if !indexFailures.isEmpty {
            warnings.append(String(
                format: String(localized: "Could not fetch indexes for: %@"),
                indexFailures.joined(separator: ", ")))
        }
        if !commentFailures.isEmpty {
            warnings.append(String(
                format: String(localized: "Could not fetch comments for: %@"),
                commentFailures.joined(separator: ", ")))
        }
        if let oversized = Self.oversizedRowWarning(tally: statementTally) {
            warnings.append(oversized)
        }
        warnings.append(contentsOf: metadataWarnings)
        return ExportFormatResult(warnings: warnings, notes: Self.statementSizeNotes(tally: statementTally))
    }

    /// The size a byte limit should be judged against, in the same binary units the limit's own menu
    /// names, so a statement that hit a 1 MB limit reads as 1 MB rather than 1.05 MB.
    private static func formatted(bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private static func statementSizeNotes(tally: SQLExportStatementTally) -> [String] {
        guard tally.largestStatementBytes > 0 else { return [] }
        let template = tally.largestStatementRows == 1
            ? String(localized: "Largest INSERT written: %1$@ (1 row).")
            : String(localized: "Largest INSERT written: %1$@ (%2$lld rows).")
        return [String(
            format: template,
            formatted(bytes: tally.largestStatementBytes),
            Int64(tally.largestStatementRows))]
    }

    /// The limit comes off the tally rather than the settings, so a second window moving the setting
    /// mid-export cannot make this name a size this export never ran under.
    private static func oversizedRowWarning(tally: SQLExportStatementTally) -> String? {
        guard tally.oversizedRowCount > 0, tally.limitBytes > 0 else { return nil }
        let template = tally.oversizedRowCount == 1
            ? String(localized: "1 row does not fit a %1$@ INSERT on its own, so its statement passes that size.")
            : String(localized: "%2$lld rows do not fit a %1$@ INSERT on their own, so their statements pass that size.")
        return String(
            format: template,
            formatted(bytes: tally.limitBytes),
            Int64(tally.oversizedRowCount))
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

    /// `CASCADE` is not portable: PostgreSQL drops dependent objects with it, SQLite and SQL Server
    /// have no such clause and reject the statement, and MySQL parses it and does nothing.
    private func cascadeClause(_ dataSource: any PluginExportDataSource) -> String {
        dataSource.supportsCascadeDrop ? " CASCADE" : ""
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
            return "\(keyword) IF EXISTS \(ref)\(cascadeClause(dataSource));"
        }
    }

    /// The sequences and enum types the selected tables depend on, created before the tables that
    /// reference them.
    ///
    /// Their `DROP` follows the table's own Drop column. It used to be written unconditionally, so
    /// a dump meant to be appended to a live database opened with `DROP TYPE ... CASCADE`, which
    /// takes the enum column out of every other table using that type.
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
                    if optionValue(table, at: 1) {
                        try writer.write(
                            "DROP SEQUENCE IF EXISTS \(quotedName)\(cascadeClause(dataSource));\n")
                    }
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
                    if optionValue(table, at: 1) {
                        try writer.write(
                            "DROP TYPE IF EXISTS \(quotedName)\(cascadeClause(dataSource));\n")
                    }
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
                guard !ddl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw SQLExportObjectError.emptyDefinition
                }
                try writer.write(ddl.hasSuffix(";") ? ddl : ddl + ";")
                try writer.write("\n\n")
            } catch {
                ddlFailures.append(sanitizedName)
                let ddlWarning = "Warning: failed to fetch DDL for table \(sanitizedName): \(error)"
                Self.logger.warning("Failed to fetch DDL for table \(sanitizedName): \(error)")
                try writer.write("-- \(PluginExportUtilities.sanitizeForSQLComment(ddlWarning))\n\n")
                continue
            }
            try await writeComments(for: table, dataSource: dataSource, to: writer)
        }
    }

    /// The kinds whose `CREATE` this dump writes as the object the driver's `COMMENT` keyword names.
    /// A routine, trigger, sequence or type is skipped rather than asked, so a dump of one costs no
    /// round trip.
    ///
    /// A foreign table is left out for a harder reason: the dump writes `CREATE TABLE` for it, so
    /// PostgreSQL's own `COMMENT ON FOREIGN TABLE` fails the restore with `"f_orders" is not a
    /// foreign table`. Measured on PostgreSQL 17.11. Add it back once a foreign table's `CREATE` is
    /// its own.
    private static let commentedKinds: Set<PluginExportObjectKind> = [
        .table, .view, .materializedView
    ]

    /// Writes an object's comments directly after its own `CREATE`, which is where `pg_dump` puts
    /// them, so a comment travels with the object it belongs to rather than with a later phase.
    ///
    /// Only ever called on the success branch: a `COMMENT` on an object whose `CREATE` was not
    /// written fails the restore. An unreadable comment list is recorded and commented into the file
    /// rather than failing the export, exactly as the index phase does.
    private func writeComments(
        for object: PluginExportTable,
        dataSource: any PluginExportDataSource,
        to writer: SQLExportFileWriter
    ) async throws {
        guard Self.commentedKinds.contains(object.kind) else { return }
        let sanitizedName = PluginExportUtilities.sanitizeForSQLComment(object.name)
        do {
            let statements = try await dataSource.fetchCommentDDL(
                table: object.name, databaseName: object.databaseName)
            guard !statements.isEmpty else { return }
            for statement in statements {
                let terminated = statement.hasSuffix(";") ? statement : "\(statement);"
                try writer.write("\(terminated)\n")
            }
            try writer.write("\n")
        } catch {
            commentFailures.append(sanitizedName)
            Self.logger.warning("Failed to fetch comments for \(sanitizedName): \(error)")
            let warning = "Warning: failed to fetch comments for \(sanitizedName): \(error)"
            try writer.write("-- \(PluginExportUtilities.sanitizeForSQLComment(warning))\n\n")
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
                guard !ddl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw SQLExportObjectError.emptyDefinition
                }
                try writer.write(ddl.hasSuffix(";") ? ddl : ddl + ";")
                try writer.write("\n\n")
            } catch {
                ddlFailures.append(sanitizedName)
                Self.logger.warning("Failed to fetch DDL for \(sanitizedName): \(error)")
                let warning = "Warning: failed to fetch definition for \(label.lowercased()) \(sanitizedName): \(error)"
                try writer.write("-- \(PluginExportUtilities.sanitizeForSQLComment(warning))\n\n")
                continue
            }
            try await writeComments(for: object, dataSource: dataSource, to: writer)
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
        options: SQLExportOptions,
        dataSource: any PluginExportDataSource,
        to writer: SQLExportFileWriter,
        progress: PluginExportProgress
    ) async throws -> SQLExportStatementTally {
        var tally = SQLExportStatementTally()
        for table in sortedTables where optionValue(table, at: 2) && table.kind.carriesRows {
            try progress.checkCancellation()
            tally.merge(try await writeTableData(
                table: table,
                columnInfo: columnsByTable[node(for: table).identifier] ?? [],
                options: options,
                dataSource: dataSource,
                to: writer,
                progress: progress))
        }
        return tally
    }

    private func writeFinalizationPhase(
        sortedTables: [PluginExportTable],
        fkMap: [String: [PluginForeignKeyInfo]],
        columnsByTable: [String: [PluginColumnInfo]],
        dataSource: any PluginExportDataSource,
        to writer: SQLExportFileWriter,
        progress: PluginExportProgress
    ) async throws {
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

        if try await writeIndexPhase(
            objects: sortedTables, dataSource: dataSource, to: writer, progress: progress) {
            emittedAnything = true
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

    /// Writes each object's `CREATE INDEX` statements, after its rows and after the deferred
    /// foreign keys.
    ///
    /// That is where every engine's own dump tool puts them, and the reason is that a bulk load
    /// into an indexed table pays to maintain an index it is about to have rebuilt anyway.
    /// A driver whose `CREATE TABLE` already declares its indexes answers nothing here, so a dump
    /// never creates one twice.
    ///
    /// A driver that cannot read them is recorded and commented into the file rather than failing
    /// the export: one unreadable table must not cost the user a dump that is otherwise correct.
    @discardableResult
    private func writeIndexPhase(
        objects: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        to writer: SQLExportFileWriter,
        progress: PluginExportProgress
    ) async throws -> Bool {
        var emittedAnything = false
        for object in objects where optionValue(object, at: 0) {
            try progress.checkCancellation()
            let sanitizedName = PluginExportUtilities.sanitizeForSQLComment(object.name)
            do {
                let statements = try await dataSource.fetchIndexDDL(
                    table: object.name, databaseName: object.databaseName)
                for statement in statements {
                    let terminated = statement.hasSuffix(";") ? statement : "\(statement);"
                    try writer.write("\(terminated)\n")
                    emittedAnything = true
                }
            } catch {
                indexFailures.append(sanitizedName)
                Self.logger.warning("Failed to fetch indexes for \(sanitizedName): \(error)")
                let warning = "Warning: failed to fetch indexes for \(sanitizedName): \(error)"
                try writer.write("-- \(PluginExportUtilities.sanitizeForSQLComment(warning))\n")
                emittedAnything = true
            }
        }
        return emittedAnything
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
        options: SQLExportOptions,
        dataSource: any PluginExportDataSource,
        to writer: SQLExportFileWriter,
        progress: PluginExportProgress
    ) async throws -> SQLExportStatementTally {
        var wroteAnyRows = false
        var tally = SQLExportStatementTally()

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
        var encoder: SQLExportRowValueEncoder?
        var accumulator: SQLExportStatementAccumulator?

        /// The insert mode the engine cannot spell is only worth reporting once a row is actually
        /// written under it. Held until then, because a table whose scope selected nothing still
        /// produces a header, and a warning raised from that alone brands a clean export a failed
        /// one: `warnings` is what retitles the summary alert and takes away its suppression.
        var pendingModeWarning: String?

        /// `SET IDENTITY_INSERT` opens the table and has to precede the first statement that carries
        /// a key, so it is written from whatever hands one over rather than from a row count. The
        /// byte budget can hold rows well past `batchSize` before closing a statement, so a
        /// row-count trigger would write it in the wrong place or not at all.
        func emit(_ statement: String) throws {
            if !wroteAnyRows {
                if needsIdentityInsert {
                    try writer.write("SET IDENTITY_INSERT \(tableRef) ON;\n")
                }
                wroteAnyRows = true
            }
            if let warning = pendingModeWarning {
                if !metadataWarnings.contains(warning) {
                    metadataWarnings.append(warning)
                }
                pendingModeWarning = nil
            }
            try writer.write(statement)
        }

        let stream = dataSource.streamRows(for: table)
        for try await element in stream {
            try progress.checkCancellation()

            switch element {
            case .header(let header):
                /// A second header describes different columns, so the statement built under the
                /// first one is closed before anything is rendered against the new prefix.
                if let statement = accumulator?.finish() {
                    try emit(statement)
                }
                if let accumulator { tally.merge(accumulator.tally) }
                let built = SQLExportRowValueEncoder(
                    columns: header.columns,
                    columnTypeNames: header.columnTypeNames ?? [],
                    excludedColumnNames: generatedColumnNames,
                    databaseTypeId: dataSource.databaseTypeId,
                    escapeStringLiteral: dataSource.escapeStringLiteral
                )
                guard !built.writesNothing else {
                    encoder = nil
                    accumulator = nil
                    continue
                }
                encoder = built
                let statementWriter = makeStatementAccumulator(
                    tableRef: tableRef,
                    columns: header.columns,
                    encoder: built,
                    primaryKeyColumns: primaryKeyColumns,
                    usesOverridingSystemValue: usesOverridingSystemValue,
                    options: options,
                    dataSource: dataSource)
                accumulator = statementWriter.accumulator
                pendingModeWarning = statementWriter.modeWarning
            case .rows(let rows):
                guard let encoder, let accumulator else { continue }
                for row in rows {
                    try progress.checkCancellation()
                    if let statement = accumulator.append(encoder.render(row)) {
                        try emit(statement)
                    }
                    progress.incrementRow()
                }
            }
        }

        /// Stop can land between the last row and the end of the stream, where the loop's own checks
        /// no longer run. Without this, a cancelled export writes its last statement, commits the
        /// file and reports success; the batch path this replaced checked cancellation per row and
        /// so threw instead, which is what makes the writer roll the whole dump back.
        try progress.checkCancellation()

        if let statement = accumulator?.finish() {
            try emit(statement)
        }
        if let accumulator { tally.merge(accumulator.tally) }

        if wroteAnyRows, needsIdentityInsert {
            try writer.write("SET IDENTITY_INSERT \(tableRef) OFF;\n")
        }

        if wroteAnyRows {
            try writer.write("\n")
        }
        return tally
    }

    /// The accumulator for one table, with its prefix and suffix rendered once, and whatever the
    /// insert mode could not spell on this engine. The caller holds that warning until a row is
    /// written under it rather than raising it here.
    private func makeStatementAccumulator(
        tableRef: String,
        columns: [String],
        encoder: SQLExportRowValueEncoder,
        primaryKeyColumns: [String],
        usesOverridingSystemValue: Bool,
        options: SQLExportOptions,
        dataSource: any PluginExportDataSource
    ) -> (accumulator: SQLExportStatementAccumulator, modeWarning: String?) {
        let quotedColumns = encoder.includedColumnIndices
            .map { dataSource.quoteIdentifier(columns[$0]) }
            .joined(separator: ", ")
        let rendered = SQLExportInsertRenderer(
            dialect: SqlDialect.from(databaseTypeId: dataSource.databaseTypeId),
            quoteIdentifier: dataSource.quoteIdentifier
        ).render(
            mode: options.insertMode,
            tableRef: tableRef,
            quotedColumns: quotedColumns,
            overriding: usesOverridingSystemValue ? " OVERRIDING SYSTEM VALUE" : "",
            columnNames: encoder.columnNames(from: columns),
            primaryKeyColumns: primaryKeyColumns
        )
        let accumulator = SQLExportStatementAccumulator(
            prefix: rendered.prefix,
            suffix: rendered.suffix,
            budget: statementBudget(for: dataSource.databaseTypeId, options: options))
        return (accumulator, rendered.warning)
    }

    /// The row ceiling is the user's choice clamped by what the engine can parse, so a dialect that
    /// rejects a multi-row `VALUES` gets one row per statement rather than a dump it cannot read.
    private func statementBudget(
        for databaseTypeId: String,
        options: SQLExportOptions
    ) -> SQLExportStatementBudget {
        SQLExportStatementBudget(
            maxRows: min(
                options.batchSize,
                SQLMultiRowInsert.maximumRowsPerStatement(forDatabaseTypeId: databaseTypeId)),
            maxBytes: options.maxStatementBytes)
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
