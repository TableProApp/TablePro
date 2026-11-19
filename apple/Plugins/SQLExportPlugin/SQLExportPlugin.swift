//
//  SQLExportPlugin.swift
//  SQLExportPlugin
//

import Combine
import Foundation
import os
import TableProPluginKit

nonisolated final class SQLExportPlugin: ObservableObject, ExportFormatPlugin, SettablePlugin, @unchecked Sendable {
    static let pluginName = "SQL Export"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Export data to SQL format"
    static let formatId = "sql"
    static let formatDisplayName = "SQL"
    static let defaultFileExtension = "sql"
    static let iconName = "text.page"
    static let excludedDatabaseTypeIds = ["MongoDB", "Redis"]

    static let perTableOptionColumns: [PluginExportOptionColumn] = [
        PluginExportOptionColumn(id: "structure", label: String(localized: "Structure", bundle: .main), width: 56),
        // The DROP statement, left untranslated: the catalog's "Drop" is the verb that deletes a table.
        PluginExportOptionColumn(id: "drop", label: "Drop", width: 44),
        PluginExportOptionColumn(id: "data", label: String(localized: "Data", bundle: .main), width: 44)
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

    // A nonisolated class cannot hold an @Published property, so the change is announced by hand.
    var settings = SQLExportOptions() {
        willSet { objectWillChange.send() }
        didSet { saveSettings() }
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLExportPlugin")

    required init() { loadSettings() }

    func defaultTableOptionValues() -> [Bool] {
        [true, true, true]
    }

    func isTableExportable(optionValues: [Bool]) -> Bool {
        optionValues.contains(true)
    }

    func readsRows(optionValues: [Bool], kind: PluginExportObjectKind) -> Bool {
        kind.carriesRows && (optionValues.count <= 2 || optionValues[2])
    }

    var currentFileExtension: String {
        settings.compressWithGzip ? "sql.gz" : "sql"
    }

    private func ddlRewriter(
        for dataSource: any PluginExportDataSource,
        options: SQLExportOptions
    ) -> SQLExportDDLRewriter {
        SQLExportDDLRewriter(
            dialect: SqlDialect.from(databaseTypeId: dataSource.databaseTypeId),
            excludesAutoIncrementValue: options.excludeAutoIncrementValue,
            excludesDefiner: options.excludeDefiner)
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
        // Read once: every window shares this plugin, and a cap re-read per table could start at 1 MiB and end unbounded.
        let options = settings
        let run = ExportRun(
            options: options,
            groupReads: groupReads(for: tables, dataSource: dataSource, progress: progress))
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

        // Compression runs over one file, so a compressed export never splits, and says so.
        let splitSize = options.compressWithGzip ? 0 : options.splitSizeMegabytes
        if options.compressWithGzip, options.splitSizeMegabytes > 0 {
            run.metadataWarnings.append(String(localized:
                "A compressed export is written as one file, so the split size was not applied."))
        }
        var readScope = await SQLExportReadScope.open(on: dataSource, for: tables)
        let writer: SQLExportFileWriter
        do {
            writer = try SQLExportFileWriter(
                destination: actualDestination,
                splitSizeMegabytes: splitSize,
                sessionDeclaration: .forDatabaseType(
                    dataSource.databaseTypeId,
                    readTimeZone: readScope.readTimeZone,
                    readsWithANSIQuotes: readScope.readsWithANSIQuotes,
                    literalsEscapeBackslash: dataSource.lexicalFeatures.contains(.backslashEscapesInSingleQuotes))
            )
        } catch {
            await readScope.close(on: dataSource)
            throw error
        }
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
            let columnsByTable = try await prefetchColumns(tables: rowObjects, progress: progress, run: run)
            let fkMap = try await prefetchForeignKeys(tables: rowObjects, progress: progress, run: run)
            let sortedTables = topologicallySort(rowObjects, fkMap: fkMap, run: run)
            noteContainerSpan(of: tables, run: run)
            try writeDependencyCycleNote(to: writer, run: run)

            try writeDropPhase(
                sortedTables: sortedTables, definitionObjects: definitionObjects,
                dataSource: dataSource, to: writer, run: run)
            try await writeObjectCreatePhase(
                objects: definitionObjects, kinds: [.userType, .sequence],
                dataSource: dataSource, to: writer, progress: progress, run: run)
            try await writeDependentTypesAndSequences(
                tables: rowObjects, dataSource: dataSource, to: writer, run: run)
            try await writeCreatePhase(
                sortedTables: sortedTables, dataSource: dataSource, to: writer, progress: progress, run: run)
            statementTally = try await writeDataPhase(
                sortedTables: sortedTables, columnsByTable: columnsByTable,
                dataSource: dataSource, to: writer, progress: progress, run: run)
            let finishing = FinishingSteps(
                progress: progress,
                total: finishingStepCount(sortedTables: sortedTables, definitionObjects: definitionObjects))
            try await writeFinalizationPhase(
                sortedTables: sortedTables, fkMap: fkMap, columnsByTable: columnsByTable,
                dataSource: dataSource, to: writer, progress: progress, run: run, finishing: finishing)
            try await writeObjectCreatePhase(
                objects: definitionObjects,
                kinds: Self.definitionKindsAfterRows,
                dataSource: dataSource, to: writer, progress: progress, run: run, finishing: finishing)
            // PostgreSQL needs a materialized view's unique index for `REFRESH ... CONCURRENTLY`; it is not in `sortedTables`.
            if try await writeIndexPhase(
                objects: definitionObjects.filter { $0.kind == .materializedView },
                dataSource: dataSource, to: writer, progress: progress, run: run, finishing: finishing) {
                try writer.write("\n")
            }
            try await writeGrantPhase(
                objects: definitionObjects, dataSource: dataSource, to: writer, run: run, finishing: finishing)

            if let snapshot {
                await snapshot.end(on: dataSource)
            }
            await readScope.close(on: dataSource)
            // The publication point: a Stop during any phase above, the grant phase included, must not replace the file.
            try progress.checkCancellation()
            let writtenParts = try writer.commit()
            committed = true
            if writer.didSplit, let first = writtenParts.first, let last = writtenParts.last {
                run.metadataWarnings.append(String(
                    format: String(localized: """
                        The dump was written as %1$lld numbered parts, %2$@ through %3$@. Restore \
                        them in order.
                        """),
                    Int64(writtenParts.count),
                    first.lastPathComponent,
                    last.lastPathComponent))
            }
        } catch {
            if let snapshot {
                await snapshot.end(on: dataSource)
            }
            await readScope.close(on: dataSource)
            throw error
        }

        if options.compressWithGzip, let gzipSource = gzipTempURL {
            progress.setStatus(String(localized: "Compressing\u{2026}"))
            defer { try? FileManager.default.removeItem(at: gzipSource) }
            try await SQLExportCompressor.compress(
                source: gzipSource, to: destination, progress: progress)
        }

        progress.finalizeTable()

        var warnings: [String] = []
        if !run.ddlFailures.isEmpty {
            let failedTables = run.ddlFailures.joined(separator: ", ")
            warnings.append(String(
                format: String(localized: "Could not fetch table structure for: %@"), failedTables))
        }
        if !run.dependentObjectFailures.isEmpty {
            warnings.append(String(
                format: String(localized: """
                    Could not fetch the types and sequences needed by: %@. A CREATE TABLE that \
                    names one of them will not restore.
                    """),
                run.dependentObjectFailures.joined(separator: ", ")))
        }
        if !run.indexFailures.isEmpty {
            warnings.append(String(
                format: String(localized: "Could not fetch indexes for: %@"),
                run.indexFailures.joined(separator: ", ")))
        }
        if !run.commentFailures.isEmpty {
            warnings.append(String(
                format: String(localized: "Could not fetch comments for: %@"),
                run.commentFailures.joined(separator: ", ")))
        }
        if let oversized = Self.oversizedRowWarning(tally: statementTally) {
            warnings.append(oversized)
        }
        if let unrepresentable = Self.unrepresentableValueWarning(tally: statementTally) {
            warnings.append(unrepresentable)
        }
        warnings.append(contentsOf: run.metadataWarnings)
        return ExportFormatResult(warnings: warnings, notes: Self.statementSizeNotes(tally: statementTally))
    }

    private static let definitionKindsAfterRows: [PluginExportObjectKind] = [
        .view, .materializedView, .routine, .trigger, .event
    ]

    // What one export records. Every window and scene shares the plugin, so none of it lives on the instance.
    private final class ExportRun {
        let options: SQLExportOptions
        let groupReads: SQLExportGroupReads
        var ddlFailures: [String] = []
        // Apart from ddlFailures, whose summary says "table structure": these tables lost only their indexes.
        var indexFailures: [String] = []
        // Apart for the same reason: the definition came back and only its comments were lost.
        var commentFailures: [String] = []
        // One entry per table. PostgreSQL 17.11 with SELECT revoked on pg_enum still returns the CREATE TABLE,
        // and the restore then stops at `type "order_status" does not exist`.
        var dependentObjectFailures: [String] = []
        var metadataWarnings: [String] = []
        // Kept in the export tree's order, the only one left once no parent-first order exists.
        var tablesUnorderedByCycle: [String] = []
        // A sequence ticked and also a table's default is reached twice, and a second CREATE SEQUENCE fails the restore.
        var emittedSequenceNames: Set<[UInt8]> = []
        // Unqualified names across two containers send one schema's rows into the other's table.
        var exportSpansContainers = false
        private let containerNames = SortNames()
        private var tableNames: [[UInt8]: SortNames] = [:]

        init(options: SQLExportOptions, groupReads: SQLExportGroupReads) {
            self.options = options
            self.groupReads = groupReads
        }

        func noteDependentObjectFailure(_ sanitizedTableName: String) {
            guard !dependentObjectFailures.contains(sanitizedTableName) else { return }
            dependentObjectFailures.append(sanitizedTableName)
        }

        func node(for table: PluginExportTable) -> ForeignKeyTopologicalSort.Table {
            node(named: table.name, in: table.containerName)
        }

        // The key as the sort reads it: the parent it names, in the referencing table's container when it names none.
        func sortKey(_ key: PluginForeignKeyInfo, from table: PluginExportTable) -> PluginForeignKeyInfo {
            let parent = node(named: key.referencedTable, in: key.referencedSchema ?? table.containerName)
            return PluginForeignKeyInfo(
                name: key.name,
                column: key.column,
                referencedTable: parent.name,
                referencedColumn: key.referencedColumn,
                referencedDatabase: key.referencedDatabase,
                referencedSchema: key.referencedSchema == nil ? nil : parent.schema ?? "",
                onDelete: key.onDelete,
                onUpdate: key.onUpdate
            )
        }

        private func node(named name: String, in container: String?) -> ForeignKeyTopologicalSort.Table {
            let container = container ?? ""
            let key = PluginExportSpelling.key(container)
            let names = tableNames[key] ?? SortNames()
            tableNames[key] = names
            return ForeignKeyTopologicalSort.Table(name: names.name(name), schema: containerNames.name(container))
        }
    }

    // ForeignKeyTopologicalSort keys a table by a String, which equates names the server keeps apart (NFC and NFD
    // spellings), so a later spelling of a name already seen gets a name of its own.
    private final class SortNames {
        private var spellings: [String: [[UInt8]]] = [:]

        func name(_ name: String) -> String {
            let bytes = PluginExportSpelling.key(name)
            var known = spellings[name, default: []]
            let index = known.firstIndex(of: bytes) ?? known.count
            if index == known.count {
                known.append(bytes)
                spellings[name] = known
            }
            return index == 0 ? name : "\(name)\u{0}\(index)"
        }
    }

    // Each kind counted over the objects its phase reads, with the filters those phases use.
    private func groupReads(
        for tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        progress: PluginExportProgress
    ) -> SQLExportGroupReads {
        let structure = tables.filter { optionValue($0, at: 0) }
        return SQLExportGroupReads(
            dataSource: dataSource,
            progress: progress,
            tables: structure.filter { $0.kind.carriesRows },
            commentedObjects: structure.filter { Self.commentedKinds.contains($0.kind) },
            indexedObjects: structure.filter { $0.kind.carriesRows || $0.kind == .materializedView },
            everyObject: tables)
    }

    // The phases after the rows read none, so they move the status instead: iOS expires a background task that stalls.
    private final class FinishingSteps {
        private let progress: PluginExportProgress
        private let total: Int
        private var done = 0

        init(progress: PluginExportProgress, total: Int) {
            self.progress = progress
            self.total = total
        }

        func advance() {
            done += 1
            progress.setStatus(String(
                format: String(localized: "Writing definitions: %1$lld of %2$lld"), Int64(done), Int64(total)))
        }
    }

    // One step per object the index, definition and grant phases below fetch, with the filters those loops use.
    private func finishingStepCount(sortedTables: [PluginExportTable], definitionObjects: [PluginExportTable]) -> Int {
        let afterRows = Set(Self.definitionKindsAfterRows)
        let wanted = definitionObjects.filter { optionValue($0, at: 0) }
        return sortedTables.filter { optionValue($0, at: 0) }.count
            + wanted.filter { afterRows.contains($0.kind) || $0.kind == .grant }.count
            + wanted.filter { $0.kind == .materializedView }.count
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

    /// Named rather than left to the restore, because no single-statement form of such a value
    /// exists on this engine: the dump carries the closest thing there is and says so.
    private static func unrepresentableValueWarning(tally: SQLExportStatementTally) -> String? {
        guard tally.unrepresentableValues > 0 else { return nil }
        let ceiling = formatted(bytes: SQLExportBinaryLiteral.oracleLiteralByteCeiling)
        let template = tally.unrepresentableValues == 1
            ? String(localized: """
                1 binary value is larger than the %1$@ this engine allows in one statement, so its \
                INSERT may not restore.
                """)
            : String(localized: """
                %2$lld binary values are larger than the %1$@ this engine allows in one statement, \
                so their INSERTs may not restore.
                """)
        return String(format: template, ceiling, Int64(tally.unrepresentableValues))
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

    private func prefetchForeignKeys(
        tables: [PluginExportTable],
        progress: PluginExportProgress,
        run: ExportRun
    ) async throws -> [String: [PluginForeignKeyInfo]] {
        var foreignKeys: [String: [PluginForeignKeyInfo]] = [:]
        var anyReadFailed = false
        for table in tables {
            do {
                foreignKeys[run.node(for: table).identifier] = try await run.groupReads.foreignKeys(for: table)
            } catch {
                try Self.rethrowIfCancelled(error, progress: progress)
                Self.logger.warning("Failed to fetch foreign keys: \(error.localizedDescription)")
                anyReadFailed = true
            }
        }
        if anyReadFailed {
            run.metadataWarnings.append(String(localized:
                "Could not fetch foreign keys, so foreign key constraints may be missing from the export."))
        }
        return foreignKeys
    }

    private func prefetchColumns(
        tables: [PluginExportTable],
        progress: PluginExportProgress,
        run: ExportRun
    ) async throws -> [String: [PluginColumnInfo]] {
        var columns: [String: [PluginColumnInfo]] = [:]
        var anyReadFailed = false
        for table in tables {
            do {
                columns[run.node(for: table).identifier] = try await run.groupReads.columns(for: table)
            } catch {
                try Self.rethrowIfCancelled(error, progress: progress)
                Self.logger.warning("Failed to fetch columns: \(error.localizedDescription)")
                anyReadFailed = true
            }
        }
        if anyReadFailed {
            run.metadataWarnings.append(String(localized:
                "Could not fetch column metadata, so identity and generated columns may not round-trip correctly."))
        }
        return columns
    }

    private static func rethrowIfCancelled(_ error: Error, progress: PluginExportProgress) throws {
        if error is CancellationError || error is PluginExportCancellationError { throw error }
        try progress.checkCancellation()
    }

    private func topologicallySort(
        _ tables: [PluginExportTable],
        fkMap: [String: [PluginForeignKeyInfo]],
        run: ExportRun
    ) -> [PluginExportTable] {
        let byIdentifier = Dictionary(
            tables.map { (run.node(for: $0).identifier, $0) },
            uniquingKeysWith: { first, _ in first })
        var sortKeys: [String: [PluginForeignKeyInfo]] = [:]
        for table in tables {
            let identifier = run.node(for: table).identifier
            sortKeys[identifier] = fkMap[identifier]?.map { run.sortKey($0, from: table) }
        }
        let ordering = ForeignKeyTopologicalSort.order(tables.map { run.node(for: $0) }, foreignKeysByTable: sortKeys)
        run.tablesUnorderedByCycle = ordering.unorderedByCycle.compactMap { byIdentifier[$0.identifier] }.map {
            ForeignKeyTopologicalSort.Table(name: $0.name, schema: $0.containerName).identifier
        }
        return ordering.tables.compactMap { byIdentifier[$0.identifier] }
    }

    // States what the file is, not a remedy: foreignKeyDisableStatements is nil on SQL Server, Oracle, Snowflake and DuckDB.
    private func writeDependencyCycleNote(to writer: SQLExportFileWriter, run: ExportRun) throws {
        guard !run.tablesUnorderedByCycle.isEmpty else { return }
        let names = run.tablesUnorderedByCycle.joined(separator: ", ")
        run.metadataWarnings.append(String(
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

    // Reverse creation order, so a dependent drops before what it depends on.
    private func writeDropPhase(
        sortedTables: [PluginExportTable],
        definitionObjects: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        to writer: SQLExportFileWriter,
        run: ExportRun
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
            guard let statement = dropStatement(for: object, dataSource: dataSource, run: run) else { continue }
            try writer.write(statement + dataSource.dumpStatementEnd)
        }
        try writer.write("\n")
    }

    /// `CASCADE` is not portable: PostgreSQL drops dependent objects with it, SQLite and SQL Server
    /// have no such clause and reject the statement, and MySQL parses it and does nothing.
    private func cascadeClause(_ dataSource: any PluginExportDataSource) -> String {
        dataSource.supportsCascadeDrop ? " CASCADE" : ""
    }

    // The engine spells its own DROP where dialects disagree, such as PostgreSQL's `DROP TRIGGER ... ON <table>`.
    private func dropStatement(
        for object: PluginExportTable,
        dataSource: any PluginExportDataSource,
        run: ExportRun
    ) -> String? {
        if let driverStatement = dataSource.dropStatement(for: object) {
            return dataSource.scriptText(for: driverStatement)
        }
        // Only PostgreSQL has `DROP ROUTINE`, and MySQL, SQL Server, Oracle and DuckDB stop the restore at one.
        guard object.kind != .routine else { return nil }
        let keyword = object.kind.dropKeyword
        guard !keyword.isEmpty else { return nil }
        let ref = qualifiedRef(
            schema: object.databaseName, table: object.name, dataSource: dataSource, run: run)
        switch object.kind {
        case .trigger, .event:
            return "\(keyword) IF EXISTS \(dataSource.quoteIdentifier(object.name));"
        default:
            return "\(keyword) IF EXISTS \(ref)\(cascadeClause(dataSource));"
        }
    }

    // The DROP follows the table's Drop column: an unconditional DROP TYPE ... CASCADE took the enum column out of every
    // other table using that type when the dump was appended to a live database.
    private func writeDependentTypesAndSequences(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        to writer: SQLExportFileWriter,
        run: ExportRun
    ) async throws {
        var emittedTypeNames: Set<[UInt8]> = []
        let structureTables = tables.filter { optionValue($0, at: 0) }
        let statementEnd = dataSource.dumpStatementEnd

        for table in structureTables {
            do {
                let sequences = try await run.groupReads.dependentSequences(for: table)
                for seq in sequences where !run.emittedSequenceNames.contains(PluginExportSpelling.key(seq.name)) {
                    run.emittedSequenceNames.insert(PluginExportSpelling.key(seq.name))
                    let quotedName = dataSource.quoteIdentifier(seq.name)
                    if optionValue(table, at: 1) {
                        try writer.write(
                            "DROP SEQUENCE IF EXISTS \(quotedName)\(cascadeClause(dataSource));\(statementEnd)")
                    }
                    try writer.write("\(seq.ddl)\(statementEnd)\n")
                }
            } catch {
                let sanitizedName = PluginExportUtilities.sanitizeForSQLComment(table.name)
                run.noteDependentObjectFailure(sanitizedName)
                Self.logger.warning("Failed to fetch dependent sequences for table \(table.name): \(error)")
                let warning = "Warning: failed to fetch dependent sequences for \(sanitizedName): \(error)"
                try writer.write("-- \(PluginExportUtilities.sanitizeForSQLComment(warning))\n\n")
            }

            do {
                let enumTypes = try await run.groupReads.dependentTypes(for: table)
                for enumType in enumTypes where !emittedTypeNames.contains(PluginExportSpelling.key(enumType.name)) {
                    emittedTypeNames.insert(PluginExportSpelling.key(enumType.name))
                    let quotedName = dataSource.quoteIdentifier(enumType.name)
                    if optionValue(table, at: 1) {
                        try writer.write(
                            "DROP TYPE IF EXISTS \(quotedName)\(cascadeClause(dataSource));\(statementEnd)")
                    }
                    let quotedLabels = enumType.labels.map { "'\(dataSource.escapeStringLiteral($0))'" }
                    let labels = quotedLabels.joined(separator: ", ")
                    try writer.write("CREATE TYPE \(quotedName) AS ENUM (\(labels));\(statementEnd)\n")
                }
            } catch {
                let sanitizedName = PluginExportUtilities.sanitizeForSQLComment(table.name)
                run.noteDependentObjectFailure(sanitizedName)
                Self.logger.warning("Failed to fetch dependent types for table \(table.name): \(error)")
                let warning = "Warning: failed to fetch dependent types for \(sanitizedName): \(error)"
                try writer.write("-- \(PluginExportUtilities.sanitizeForSQLComment(warning))\n\n")
            }
        }
    }

    private func writeCreatePhase(
        sortedTables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        to writer: SQLExportFileWriter,
        progress: PluginExportProgress,
        run: ExportRun
    ) async throws {
        let rewriter = ddlRewriter(for: dataSource, options: run.options)
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
                try writer.write(dataSource.scriptText(for: ddl) + dataSource.dumpStatementEnd)
                try writer.write("\n")
            } catch {
                run.ddlFailures.append(sanitizedName)
                let ddlWarning = "Warning: failed to fetch DDL for table \(sanitizedName): \(error)"
                Self.logger.warning("Failed to fetch DDL for table \(sanitizedName): \(error)")
                try writer.write("-- \(PluginExportUtilities.sanitizeForSQLComment(ddlWarning))\n\n")
                continue
            }
            try await writeComments(for: table, dataSource: dataSource, to: writer, run: run)
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

    // Right after the object's own CREATE, as pg_dump writes them. Never for an object whose CREATE was not written:
    // that COMMENT fails the restore.
    private func writeComments(
        for object: PluginExportTable,
        dataSource: any PluginExportDataSource,
        to writer: SQLExportFileWriter,
        run: ExportRun
    ) async throws {
        guard Self.commentedKinds.contains(object.kind) else { return }
        let sanitizedName = PluginExportUtilities.sanitizeForSQLComment(object.name)
        do {
            let statements = try await run.groupReads.commentDDL(for: object)
            guard !statements.isEmpty else { return }
            for statement in statements {
                try writer.write(dataSource.scriptText(for: statement) + dataSource.dumpStatementEnd)
            }
            try writer.write("\n")
        } catch {
            run.commentFailures.append(sanitizedName)
            Self.logger.warning("Failed to fetch comments for \(sanitizedName): \(error)")
            let warning = "Warning: failed to fetch comments for \(sanitizedName): \(error)"
            try writer.write("-- \(PluginExportUtilities.sanitizeForSQLComment(warning))\n\n")
        }
    }

    // Dump order within the group creates a view before one that selects from it; an unreadable object is noted, not fatal.
    private func writeObjectCreatePhase(
        objects: [PluginExportTable],
        kinds: [PluginExportObjectKind],
        dataSource: any PluginExportDataSource,
        to writer: SQLExportFileWriter,
        progress: PluginExportProgress,
        run: ExportRun,
        finishing: FinishingSteps? = nil
    ) async throws {
        let wanted = Set(kinds)
        let targets = objects
            .filter { wanted.contains($0.kind) && optionValue($0, at: 0) }
            .sorted { ($0.kind.dumpOrder, $0.name) < ($1.kind.dumpOrder, $1.name) }
        guard !targets.isEmpty else { return }

        for object in targets {
            try progress.checkCancellation()
            finishing?.advance()
            let sanitizedName = PluginExportUtilities.sanitizeForSQLComment(object.name)
            let label = objectCommentLabel(for: object.kind)
            try writer.write("-- --------------------------------------------------------\n")
            try writer.write("-- \(label): \(sanitizedName)\n")
            try writer.write("-- --------------------------------------------------------\n\n")
            if object.kind == .sequence {
                guard run.emittedSequenceNames.insert(PluginExportSpelling.key(object.name)).inserted else { continue }
            }
            do {
                let ddl = ddlRewriter(for: dataSource, options: run.options)
                    .rewrite(try await dataSource.fetchObjectDDL(object))
                guard !ddl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw SQLExportObjectError.emptyDefinition
                }
                let scope = try await creationScope(for: object, dataSource: dataSource, to: writer, run: run)
                try writer.write(creationScript(ddl: ddl, scope: scope, dataSource: dataSource))
                try writer.write("\n")
            } catch {
                run.ddlFailures.append(sanitizedName)
                Self.logger.warning("Failed to fetch DDL for \(sanitizedName): \(error)")
                let warning = "Warning: failed to fetch definition for \(label.lowercased()) \(sanitizedName): \(error)"
                try writer.write("-- \(PluginExportUtilities.sanitizeForSQLComment(warning))\n\n")
                continue
            }
            try await writeComments(for: object, dataSource: dataSource, to: writer, run: run)
        }
    }

    /// The kinds a server stores the creating session's settings with, such as MySQL's `sql_mode`.
    private static let creationScopedKinds: Set<PluginExportObjectKind> = [.routine, .trigger, .event]

    // An unreadable scope is noted in the file and still lets the definition be written.
    private func creationScope(
        for object: PluginExportTable,
        dataSource: any PluginExportDataSource,
        to writer: SQLExportFileWriter,
        run: ExportRun
    ) async throws -> PluginStatementScope? {
        guard Self.creationScopedKinds.contains(object.kind) else { return nil }
        do {
            return try await dataSource.fetchCreationScope(object)
        } catch {
            let sanitizedName = PluginExportUtilities.sanitizeForSQLComment(object.name)
            Self.logger.warning("Failed to fetch the creation settings for \(sanitizedName): \(error)")
            run.metadataWarnings.append(String(
                format: String(localized: "Could not read the settings %@ was created with, so it restores under the dump's SQL mode."),
                object.name))
            let warning = "Warning: failed to fetch the creation settings for \(sanitizedName): \(error)"
            try writer.write("-- \(PluginExportUtilities.sanitizeForSQLComment(warning))\n")
            return nil
        }
    }

    /// One string, so the writer cannot rotate between the settings and the definition they apply to.
    private func creationScript(
        ddl: String,
        scope: PluginStatementScope?,
        dataSource: any PluginExportDataSource
    ) -> String {
        let statements = (scope?.opening ?? []) + [ddl] + (scope?.closing ?? [])
        return statements
            .map { dataSource.scriptText(for: $0) + dataSource.dumpStatementEnd }
            .joined()
    }

    // Grants come last, because every object they name has to exist first.
    private func writeGrantPhase(
        objects: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        to writer: SQLExportFileWriter,
        run: ExportRun,
        finishing: FinishingSteps
    ) async throws {
        let principals = objects
            .filter { $0.kind == .grant && optionValue($0, at: 0) }
            .sorted { $0.name < $1.name }
        guard !principals.isEmpty else { return }

        try writer.write("-- --------------------------------------------------------\n")
        try writer.write("-- Privileges\n")
        try writer.write("-- --------------------------------------------------------\n\n")

        for principal in principals {
            finishing.advance()
            do {
                let statements = try await dataSource.fetchGrantStatements(
                    principal: principal.name, host: principal.identity)
                guard !statements.isEmpty else { continue }
                for statement in statements {
                    try writer.write(dataSource.scriptText(for: statement) + dataSource.dumpStatementEnd)
                }
            } catch {
                let sanitized = PluginExportUtilities.sanitizeForSQLComment(principal.name)
                run.ddlFailures.append(sanitized)
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
        progress: PluginExportProgress,
        run: ExportRun
    ) async throws -> SQLExportStatementTally {
        var tally = SQLExportStatementTally()
        for table in sortedTables where optionValue(table, at: 2) && table.kind.carriesRows {
            try progress.checkCancellation()
            tally.merge(try await writeTableData(
                table: table,
                columnInfo: columnsByTable[run.node(for: table).identifier] ?? [],
                dataSource: dataSource,
                to: writer,
                progress: progress,
                run: run))
        }
        return tally
    }

    private func writeFinalizationPhase(
        sortedTables: [PluginExportTable],
        fkMap: [String: [PluginForeignKeyInfo]],
        columnsByTable: [String: [PluginColumnInfo]],
        dataSource: any PluginExportDataSource,
        to writer: SQLExportFileWriter,
        progress: PluginExportProgress,
        run: ExportRun,
        finishing: FinishingSteps
    ) async throws {
        var emittedAnything = try await writeIndexPhase(
            objects: sortedTables, dataSource: dataSource, to: writer, progress: progress, run: run, finishing: finishing)
        // Only for DDL that leaves foreign keys out (PostgreSQL, Oracle): MySQL and SQL Server reject a duplicate one.
        if !dataSource.tableDDLIncludesForeignKeys {
            for table in sortedTables where optionValue(table, at: 0) {
                let fks = fkMap[run.node(for: table).identifier] ?? []
                let grouped = groupForeignKeysByConstraint(fks)
                for group in grouped {
                    let alter = renderAddConstraintFK(table: table, group: group, dataSource: dataSource, run: run)
                    try writer.write(alter + dataSource.dumpStatementEnd)
                    emittedAnything = true
                }
            }
        }

        // `setval` and `pg_get_serial_sequence` are PostgreSQL's own; any other engine reads them as a syntax error.
        if SqlDialect.from(databaseTypeId: dataSource.databaseTypeId) == .postgres {
            for table in sortedTables where optionValue(table, at: 2) && table.kind.carriesRows {
                let columns = columnsByTable[run.node(for: table).identifier] ?? []
                for column in columns where column.isIdentity {
                    let setval = renderIdentitySetval(
                        table: table, columnName: column.name, dataSource: dataSource, run: run)
                    try writer.write(setval + dataSource.dumpStatementEnd)
                    emittedAnything = true
                }
            }
        }

        if emittedAnything {
            try writer.write("\n")
        }
    }

    // After the rows, as every engine's own dump tool does, so the bulk load does not maintain the index.
    @discardableResult
    private func writeIndexPhase(
        objects: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        to writer: SQLExportFileWriter,
        progress: PluginExportProgress,
        run: ExportRun,
        finishing: FinishingSteps
    ) async throws -> Bool {
        var emittedAnything = false
        for object in objects where optionValue(object, at: 0) {
            try progress.checkCancellation()
            finishing.advance()
            let sanitizedName = PluginExportUtilities.sanitizeForSQLComment(object.name)
            do {
                let statements = try await run.groupReads.indexDDL(for: object)
                for statement in statements {
                    try writer.write(dataSource.scriptText(for: statement) + dataSource.dumpStatementEnd)
                    emittedAnything = true
                }
            } catch {
                run.indexFailures.append(sanitizedName)
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
        dataSource: any PluginExportDataSource,
        run: ExportRun
    ) -> String {
        let tableRef = qualifiedRef(
            schema: table.databaseName, table: table.name, dataSource: dataSource, run: run)
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

    // CREATE TABLE comes back from the driver verbatim, so a spanning export says it cannot qualify that statement.
    private func noteContainerSpan(of tables: [PluginExportTable], run: ExportRun) {
        let containers = Set(tables.map { PluginExportSpelling.key($0.containerName ?? "") })
        run.exportSpansContainers = containers.count > 1
        guard run.exportSpansContainers else { return }
        run.metadataWarnings.append(String(
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
        dataSource: any PluginExportDataSource,
        run: ExportRun
    ) -> String {
        let quotedTable = dataSource.quoteIdentifier(table)
        guard run.exportSpansContainers, !schema.isEmpty else { return quotedTable }
        return "\(dataSource.quoteIdentifier(schema)).\(quotedTable)"
    }

    private func renderAddConstraintFK(
        table: PluginExportTable,
        group: [PluginForeignKeyInfo],
        dataSource: any PluginExportDataSource,
        run: ExportRun
    ) -> String {
        let tableRef = qualifiedRef(
            schema: table.databaseName, table: table.name, dataSource: dataSource, run: run)
        let constraintName = dataSource.quoteIdentifier(group[0].name)
        let cols = group.map { dataSource.quoteIdentifier($0.column) }.joined(separator: ", ")
        let refCols = group.map { dataSource.quoteIdentifier($0.referencedColumn) }.joined(separator: ", ")
        let refSchema = (group[0].referencedSchema?.isEmpty == false ? group[0].referencedSchema : nil) ?? table.databaseName
        let refTable = qualifiedRef(
            schema: refSchema, table: group[0].referencedTable, dataSource: dataSource, run: run)
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
        progress: PluginExportProgress,
        run: ExportRun
    ) async throws -> SQLExportStatementTally {
        var wroteAnyRows = false
        var tally = SQLExportStatementTally()

        let generatedColumnNames = Set(columnInfo.filter { $0.isGenerated }.map { $0.name })
        let primaryKeyColumns = columnInfo.filter(\.isPrimaryKey).map(\.name)
        let usesOverridingSystemValue = SqlDialect.from(databaseTypeId: dataSource.databaseTypeId) == .postgres
            && columnInfo.contains { $0.identityKind == .always }
        let tableRef = qualifiedRef(
            schema: table.databaseName, table: table.name, dataSource: dataSource, run: run)
        // SQL Server rejects an explicit IDENTITY value unless the table is opened for it. A writer scope, so a part
        // rotation inside the rows carries it into the next part (#2533).
        let needsIdentityInsert = dataSource.databaseTypeId == "SQL Server"
            && columnInfo.contains(where: \.isIdentity)
        let identityInsert = needsIdentityInsert
            ? SQLExportSessionScope.identityInsert(tableRef: tableRef, statementEnd: dataSource.dumpStatementEnd)
            : nil

        if !table.rowScope.isUnrestricted {
            let scopeNote = PluginExportUtilities.sanitizeForSQLComment(table.rowScope.summary)
            try writer.write("-- Rows narrowed to: \(scopeNote)\n")
        }
        if table.rowScope.hasRejectedFilter {
            run.metadataWarnings.append(String(
                format: String(localized:
                    "The row filter on %@ was not a single expression, so every row was exported."),
                table.name))
        }
        var encoder: SQLExportRowValueEncoder?
        var accumulator: SQLExportStatementAccumulator?

        // Raised only once a row is written under it: a table whose scope selected nothing still sends a header, and
        // any warning retitles the summary alert as a failure.
        var pendingModeWarning: String?

        // The byte budget can hold rows past batchSize, so IDENTITY_INSERT opens on the first statement, not a row count.
        func emit(_ statement: String) throws {
            if let warning = pendingModeWarning {
                if !run.metadataWarnings.contains(warning) {
                    run.metadataWarnings.append(warning)
                }
                pendingModeWarning = nil
            }
            guard !wroteAnyRows else {
                try writer.write(statement)
                return
            }
            wroteAnyRows = true
            try writer.write(statement, opening: identityInsert)
        }

        let stream = dataSource.streamRows(for: table)
        for try await element in stream {
            try progress.checkCancellation()

            switch element {
            case .header(let header):
                // A second header describes different columns: close the statement built under the first.
                if let statement = accumulator?.finish() {
                    try emit(statement)
                }
                if let accumulator { tally.merge(accumulator.tally) }
                // The outgoing encoder's count too, or values a first segment could not represent go unreported.
                if let encoder { tally.unrepresentableValues += encoder.unrepresentableValues.total }
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
                    options: run.options,
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

        // A Stop between the last row and the end of the stream would otherwise commit the dump and report success.
        try progress.checkCancellation()

        if let statement = accumulator?.finish() {
            try emit(statement)
        }
        if let accumulator { tally.merge(accumulator.tally) }
        if let encoder { tally.unrepresentableValues += encoder.unrepresentableValues.total }

        if wroteAnyRows, needsIdentityInsert {
            try writer.closeScope()
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
            budget: statementBudget(for: dataSource.databaseTypeId, options: options),
            terminator: ";\(dataSource.dumpStatementEnd)\n")
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
}
