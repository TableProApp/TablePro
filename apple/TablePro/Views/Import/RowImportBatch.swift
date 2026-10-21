//
//  RowImportBatch.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProPluginKit

/// Several files imported as rows in one run, each into its own table: what each file is read as, where it goes,
/// and whether the run as a whole can start. Held apart from `RowImportBatchSheet` so its rules are testable.
@MainActor
internal final class RowImportBatch: ObservableObject {
    internal enum ReadState: Equatable {
        case pending
        case reading
        case ready
        case failed(String)
    }

    /// The identity of a read: the file's destination, its table and the format's options. A file reads again
    /// when any of them changes.
    internal struct ReadKey: Hashable {
        let destination: RowImportDestination
        let table: String?
        let signature: String
    }

    internal enum Choice: Hashable {
        case newTable
        case existingTable(String)
    }

    internal struct File: Identifiable {
        internal let id = UUID()
        internal let url: URL
        internal let formatId: String
        internal var isIncluded = true
        internal var target: RowImportTarget

        /// The target is still the run's own proposal, which a table list arriving later may replace.
        internal var targetIsProposed = true
        internal var read: ReadState = .pending
        internal var loadedRead: ReadKey?

        internal var sourceName: String {
            url.lastPathComponent
        }
    }

    /// What the sheet needs from the database and the plugins, so a test can stand in for both.
    internal struct Services {
        internal var fetchTables: @MainActor (DatabaseScope) async throws -> [TableInfo]
        internal var fetchColumns: @MainActor (String, DatabaseScope) async throws -> [String]
        internal var detectFields: @MainActor (String, URL, String?) async throws -> [PluginImportField]
        internal var configuration: @MainActor (String) -> RowImportRunner.Configuration?
        internal var formatName: @MainActor (String) -> String
        internal var sqlType: @MainActor (PluginImportFieldType) -> String

        internal static func live(for connection: DatabaseConnection) -> Services {
            Services(
                fetchTables: { scope in
                    try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
                        try await driver.fetchTables()
                    }
                },
                fetchColumns: { table, scope in
                    try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
                        try await driver.fetchColumns(table: table)
                    }.map(\.name)
                },
                detectFields: { formatId, url, table in
                    guard let plugin = PluginManager.shared.importPlugin(forFormat: formatId) else {
                        throw PluginImportError.importFailed("Import format '\(formatId)' not found")
                    }
                    return try await ImportFieldDetection.detectFields(plugin: plugin, at: url, targetTable: table)
                },
                configuration: { formatId in
                    PluginManager.shared.importPlugin(forFormat: formatId)?.rowImportConfiguration
                },
                formatName: { formatId in
                    PluginManager.shared.importPlugin(forFormat: formatId).map { type(of: $0).formatDisplayName }
                        ?? formatId.uppercased()
                },
                sqlType: { fieldType in
                    let serverVersion = DatabaseManager.shared.driver(for: connection.id)?.serverVersion
                    return ImportTypeMapper.sqlType(
                        for: fieldType,
                        databaseType: connection.type,
                        serverVersion: serverVersion
                    )
                }
            )
        }
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "RowImportBatch")

    @Published internal private(set) var files: [File]
    @Published internal private(set) var tables: [TableInfo] = []

    /// Folded names of every object the database holds, nil while the list is unknown, as in the one-file sheet.
    @Published internal private(set) var catalogNameKeys: Set<String>?
    @Published internal private(set) var tableListError: String?
    @Published internal private(set) var isLoadingTables = false

    /// Reads wait for the first table list, which can turn a file's proposed new table into the table it matches.
    @Published internal private(set) var isCatalogSettled = false
    @Published internal private(set) var signatures: [String: String] = [:]

    /// Each format's error handling and transaction options as its options view last left them. They change no
    /// read, so they are kept apart from the signature, and the readiness they decide follows them here.
    @Published internal private(set) var configurations: [String: RowImportRunner.Configuration] = [:]
    @Published internal private(set) var readRetries = 0

    /// The tables this run created, so a retry after a failed run reuses them rather than tripping on their names.
    @Published internal var planner = NewTableImportPlanner()

    @Published internal private(set) var leftOut: [URL]
    internal let scope: DatabaseScope?
    private let databaseType: DatabaseType
    private let style: NewTableNameStyle
    private let services: Services
    private let mappingStore: ImportColumnMappingStore
    private var columnsByTable: [String: [String]] = [:]

    internal init(
        files: [ImportBatchFiles.File],
        leftOut: [URL],
        connection: DatabaseConnection,
        scope: DatabaseScope?,
        services: Services,
        mappingStore: ImportColumnMappingStore = .shared
    ) {
        self.mappingStore = mappingStore
        self.leftOut = leftOut
        self.scope = scope
        self.databaseType = connection.type
        self.style = NewTableNameStyle.forDatabaseType(connection.type)
        self.services = services
        self.files = files.map { File(url: $0.url, formatId: $0.formatId, target: .newTable(named: "")) }
        proposeTargets()
    }

    // MARK: - Formats

    /// Every format the files are in, in the order the files first name them.
    internal var formatIds: [String] {
        var seen = Set<String>()
        return files.map(\.formatId).filter { seen.insert($0).inserted }
    }

    internal func formatName(_ formatId: String) -> String {
        services.formatName(formatId)
    }

    internal func setSignature(_ signature: String, for formatId: String) {
        guard signatures[formatId] != signature else { return }
        signatures[formatId] = signature
    }

    internal func setConfiguration(_ configuration: RowImportRunner.Configuration?, for formatId: String) {
        configurations[formatId] = configuration
    }

    private func configuration(for formatId: String) -> RowImportRunner.Configuration? {
        configurations[formatId] ?? services.configuration(formatId)
    }

    // MARK: - Catalog

    /// Tables alone, because they are the only objects a file's rows can be inserted into.
    internal var availableTables: [TableInfo] {
        tables.filter(\.type.acceptsImportedRows)
    }

    internal func loadTables() async {
        guard !isLoadingTables else { return }
        defer { isCatalogSettled = true }
        guard let scope else {
            catalogNameKeys = nil
            tableListError = String(localized: "This connection is not open.")
            return
        }
        isLoadingTables = true
        defer { isLoadingTables = false }
        do {
            let objects = try await services.fetchTables(scope)
            tables = objects
            catalogNameKeys = NewTableNaming.comparisonKeys(for: objects.map(\.name))
            tableListError = nil
            columnsByTable = [:]
        } catch {
            catalogNameKeys = nil
            tableListError = error.localizedDescription
            Self.logger.warning("Failed to load tables: \(error.publicLogShape, privacy: .public)")
        }
        proposeTargets()
    }

    /// Names a new table must not take: the catalog's, less the tables this run created, which a retry lands on.
    private var catalogKeysOutsideRun: Set<String> {
        let ours = NewTableNaming.comparisonKeys(for: scope.map(planner.createdTableNames(in:)) ?? [])
        return (catalogNameKeys ?? []).subtracting(ours)
    }

    /// A file goes to the table its name matches, as the one-file sheet would name it, or to a new table under that
    /// name. Two files never get one new name. Only a target the user has not changed is replaced, and a table this
    /// run created is not a match: the retry lands on it as the new table it was.
    private func proposeTargets() {
        let ours = NewTableNaming.comparisonKeys(for: scope.map(planner.createdTableNames(in:)) ?? [])
        let tablesByKey = Dictionary(
            availableTables.map { ($0.name.lowercased(), $0.name) }.filter { !ours.contains($0.0) },
            uniquingKeysWith: { first, _ in first }
        )
        var taken = catalogKeysOutsideRun
        for file in files where !file.targetIsProposed && file.target.destination == .newTable {
            taken.insert(file.target.newTableName.trimmingCharacters(in: .whitespaces).lowercased())
        }
        for index in files.indices where files[index].targetIsProposed {
            let base = NewTableNaming.suggestion(forFileNamed: files[index].sourceName, style: style, avoiding: [])
            if let table = tablesByKey[base.lowercased()] {
                if files[index].target.destination != .existingTable || files[index].target.existingTable != table {
                    files[index].target = .existingTable(table, proposingNewTable: "")
                }
                continue
            }
            let name = NewTableNaming.suggestion(forFileNamed: files[index].sourceName, style: style, avoiding: taken)
            taken.insert(name.lowercased())
            if files[index].target.destination == .newTable {
                files[index].target.newTableName = name
                files[index].target.proposedTableName = name
            } else {
                files[index].target = .newTable(named: name)
            }
        }
    }

    // MARK: - Choices

    /// Files and folders dropped on the list join the run after the files already in it.
    internal func add(_ resolution: ImportBatchFiles.Resolution) {
        let known = Set(files.map { $0.url.standardizedFileURL })
        let added = resolution.files.filter { !known.contains($0.url.standardizedFileURL) }
        files += added.map { File(url: $0.url, formatId: $0.formatId, target: .newTable(named: "")) }
        leftOut += resolution.leftOut.filter { !leftOut.contains($0) }
        proposeTargets()
    }

    internal func file(_ id: File.ID) -> File? {
        files.first { $0.id == id }
    }

    private func index(of id: File.ID) -> Int? {
        files.firstIndex { $0.id == id }
    }

    internal func setIncluded(_ isIncluded: Bool, for id: File.ID) {
        guard let index = index(of: id) else { return }
        files[index].isIncluded = isIncluded
    }

    internal func choice(for file: File) -> Choice {
        switch file.target.destination {
        case .newTable:
            return .newTable
        case .existingTable:
            return file.target.existingTable.map(Choice.existingTable) ?? .newTable
        }
    }

    internal func choose(_ choice: Choice, for id: File.ID) {
        guard let index = index(of: id) else { return }
        files[index].targetIsProposed = false
        switch choice {
        case .newTable:
            files[index].target.destination = .newTable
            if files[index].target.newTableName.trimmingCharacters(in: .whitespaces).isEmpty {
                let name = NewTableNaming.suggestion(
                    forFileNamed: files[index].sourceName,
                    style: style,
                    avoiding: catalogKeysOutsideRun.union(newTableKeys(excluding: id))
                )
                files[index].target.newTableName = name
                files[index].target.proposedTableName = name
            }
        case .existingTable(let table):
            files[index].target.destination = .existingTable
            files[index].target.existingTable = table
        }
    }

    /// What the sheet that edits one file handed back, which answers a read of the current options.
    internal func apply(_ target: RowImportTarget, to id: File.ID) {
        guard let index = index(of: id) else { return }
        files[index].target = target
        files[index].targetIsProposed = false
        files[index].read = .ready
        files[index].loadedRead = readKey(for: files[index])
    }

    internal func edit(for id: File.ID, onDone: @escaping @MainActor (RowImportTarget) -> Void) -> RowImportSheetEdit? {
        guard let scope, let file = file(id) else { return nil }
        return RowImportSheetEdit(
            scope: scope,
            target: file.target,
            planner: planner,
            takenTableNames: newTableKeys(excluding: id),
            onDone: onDone
        )
    }

    /// Folded names of the new tables the other included files create.
    private func newTableKeys(excluding id: File.ID) -> Set<String> {
        Set(files.compactMap { file in
            guard file.id != id, file.isIncluded, file.target.destination == .newTable else { return nil }
            let name = file.target.newTableName.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name.lowercased()
        })
    }

    // MARK: - Reading

    internal func readKey(for file: File) -> ReadKey {
        let isExisting = file.target.destination == .existingTable
        return ReadKey(
            destination: file.target.destination,
            table: isExisting ? file.target.existingTable : nil,
            signature: signatures[file.formatId] ?? ""
        )
    }

    internal struct ReadRequest: Hashable {
        let keys: [ReadKey?]
        let retries: Int
        let isCatalogSettled: Bool
    }

    /// Changes whenever a file needs a read, so `.task(id:)` cancels the reads in flight and starts again.
    internal var readRequest: ReadRequest {
        ReadRequest(
            keys: files.map { $0.isIncluded ? readKey(for: $0) : nil },
            retries: readRetries,
            isCatalogSettled: isCatalogSettled
        )
    }

    internal func needsRead(_ file: File) -> Bool {
        guard file.isIncluded else { return false }
        if file.target.destination == .existingTable, file.target.existingTable == nil { return false }
        return file.loadedRead != readKey(for: file)
    }

    /// One file at a time, so twenty files do not open twenty reads at once.
    internal func readFiles() async {
        guard isCatalogSettled else { return }
        let pending = files.filter(needsRead).map(\.id)
        for id in pending {
            guard !Task.isCancelled else { return }
            await read(id)
        }
    }

    internal func retryRead(of id: File.ID) {
        guard let index = index(of: id) else { return }
        files[index].loadedRead = nil
        files[index].read = .pending
        readRetries += 1
    }

    private func read(_ id: File.ID) async {
        guard let index = index(of: id) else { return }
        let file = files[index]
        let key = readKey(for: file)
        files[index].read = .reading
        do {
            switch key.destination {
            case .newTable:
                let fields = try await services.detectFields(file.formatId, file.url, nil)
                guard let index = landing(id, key) else { return }
                files[index].target.newTable.load(fields: fields) { services.sqlType($0) }
            case .existingTable:
                guard let table = key.table, let scope else { return }
                let columns = try await columns(of: table, in: scope)
                let fields = try await services.detectFields(file.formatId, file.url, table)
                guard let index = landing(id, key) else { return }
                files[index].target.mapping = mapping(
                    fields: fields,
                    columns: columns,
                    table: table,
                    scope: scope,
                    prior: files[index].target.mapping
                )
            }
            guard let index = landing(id, key) else { return }
            files[index].read = .ready
            files[index].loadedRead = key
        } catch {
            guard let index = landing(id, key) else { return }
            files[index].read = .failed(error.localizedDescription)
            files[index].loadedRead = key
            Self.logger.warning("Failed to read an import file: \(error.publicLogShape, privacy: .public)")
        }
    }

    /// The file's slot when the read still answers what the file asks for now.
    private func landing(_ id: File.ID, _ key: ReadKey) -> Int? {
        guard !Task.isCancelled, let index = index(of: id), readKey(for: files[index]) == key else { return nil }
        return index
    }

    private func columns(of table: String, in scope: DatabaseScope) async throws -> [String] {
        if let cached = columnsByTable[table] { return cached }
        let columns = try await services.fetchColumns(table, scope)
        columnsByTable[table] = columns
        return columns
    }

    /// The choices already made for this table first, then the mapping saved for it, then the name match: the order
    /// the one-file sheet restores them in.
    private func mapping(
        fields: [PluginImportField],
        columns: [String],
        table: String,
        scope: DatabaseScope,
        prior: RowImportTarget.Mapping?
    ) -> RowImportTarget.Mapping {
        let saved = mappingStore.overrides(for: TableScope(table: table, in: scope))
        var tiers = [saved.mapValues(\.choice)]
        if let prior, prior.table == table {
            tiers.insert(prior.choicesByField, at: 0)
        }
        let choices = ImportColumnMatcher.resolve(fields: fields.map(\.name), columns: columns, preferring: tiers)
        return RowImportTarget.Mapping(table: table, fields: fields, columns: columns, choices: choices)
    }

    // MARK: - Readiness

    internal var includedFiles: [File] {
        files.filter(\.isIncluded)
    }

    internal var isReading: Bool {
        includedFiles.contains { $0.read == .reading || needsRead($0) }
    }

    /// What stands between the run and Import, the first of it, naming the file it is about.
    internal var problem: String? {
        let included = includedFiles
        guard !included.isEmpty else {
            return String(localized: "Choose at least one file to import.")
        }
        for file in included {
            if let problem = problem(of: file) {
                return problem
            }
        }
        if let name = duplicateNewTableName(in: included) {
            return String(format: String(localized: "Two files create a table named %@."), name)
        }
        if let table = clearedTwice(in: included) {
            return String(
                format: String(localized: """
                    %@ takes rows from two files, so Delete existing rows before import would remove the first \
                    file's rows.
                    """),
                table
            )
        }
        return policyProblem(in: included)
    }

    internal func problem(of file: File) -> String? {
        if case .failed(let reason) = file.read {
            return String(format: String(localized: "%1$@ cannot be read. %2$@"), file.sourceName, reason)
        }
        switch file.target.destination {
        case .existingTable:
            guard let table = file.target.existingTable else {
                return String(format: String(localized: "Choose a table for %@."), file.sourceName)
            }
            guard file.read == .ready, let mapping = file.target.mapping else { return nil }
            if mapping.mappedFieldCount == 0 {
                return String(format: String(localized: "%1$@ maps no field to a column of %2$@."), file.sourceName, table)
            }
            if mapping.mapsOneColumnTwice {
                return String(
                    format: String(localized: "%1$@ maps two fields to one column of %2$@."), file.sourceName, table
                )
            }
            return nil
        case .newTable:
            if let problem = nameProblem(of: file) {
                return String(
                    format: String(localized: "%1$@: %2$@"),
                    file.sourceName,
                    problem.message(for: file.target.newTableName)
                )
            }
            guard file.read == .ready else { return nil }
            if let problem = file.target.newTable.problem {
                return String(format: String(localized: "%1$@: %2$@"), file.sourceName, problem.message)
            }
            if !file.target.newTable.hasNamedColumn {
                return String(format: String(localized: "%@ has no column to create."), file.sourceName)
            }
            return nil
        }
    }

    private func nameProblem(of file: File) -> NewTableNameProblem? {
        let name = file.target.newTableName
        let problem = NewTableNaming.problem(with: name, style: style, existingNames: catalogNameKeys)
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard problem == .nameTaken, let scope, planner.created(TableScope(table: trimmed, in: scope)) else {
            return problem
        }
        return nil
    }

    private func duplicateNewTableName(in included: [File]) -> String? {
        var seen = Set<String>()
        for file in included where file.target.destination == .newTable {
            let name = file.target.newTableName.trimmingCharacters(in: .whitespaces)
            guard seen.insert(name.lowercased()).inserted else { return name }
        }
        return nil
    }

    /// The first file into a table clears it, and the second clears it again, taking the first file's rows. Grouped by
    /// the table each file ends in, new or existing, since a table a failed run created is offered as existing too.
    private func clearedTwice(in included: [File]) -> String? {
        let grouped = Dictionary(grouping: included.filter { $0.target.tableName != nil }) {
            $0.target.tableName?.lowercased() ?? ""
        }
        for (_, group) in grouped.sorted(by: { $0.key < $1.key }) where group.count > 1 {
            let clears = group.contains { configuration(for: $0.formatId)?.deleteExistingRows == true }
            if clears { return group.first?.target.tableName }
        }
        return nil
    }

    private func policyProblem(in included: [File]) -> String? {
        var formats: [String] = []
        for file in included where !formats.contains(file.formatId) {
            formats.append(file.formatId)
        }
        let policies = formats.map { configuration(for: $0).map(RowImportBatchPolicy.init) }
        if let index = policies.firstIndex(where: { $0 == nil }) {
            return String(
                format: String(localized: "%@ files cannot be imported together with other files."),
                formatName(formats[index])
            )
        }
        let distinct = Set(policies.compactMap { $0.map { "\($0.errorHandling.rawValue)|\($0.usesTransaction)" } })
        guard distinct.count > 1 else { return nil }
        return String(
            format: String(localized: "Set On error and Wrap in transaction the same for %@."),
            formats.map(formatName).formatted(.list(type: .and))
        )
    }

    internal var policy: RowImportBatchPolicy? {
        includedFiles.first.flatMap { configuration(for: $0.formatId) }.map(RowImportBatchPolicy.init)
    }

    internal var canImport: Bool {
        !isReading && problem == nil && includedFiles.allSatisfy { $0.read == .ready } && policy != nil
    }

    // MARK: - Plan

    internal struct PlannedMapping {
        internal let fields: [String]
        internal let columns: [String]
        internal let columnMapping: [String: String]
        internal let table: String
    }

    internal struct Plan {
        internal let items: [RowImportRunItem]
        internal let newTables: [PluginCreateTableDefinition]
        internal let mappings: [PlannedMapping]
    }

    /// The run as the included files stand, or nil while any of them is not ready.
    internal func plan() -> Plan? {
        guard canImport else { return nil }
        var items: [RowImportRunItem] = []
        var newTables: [PluginCreateTableDefinition] = []
        var mappings: [PlannedMapping] = []
        for file in includedFiles {
            let fields: [String]
            let columns: [String]
            let columnMapping: [String: String]
            let table: String
            switch file.target.destination {
            case .existingTable:
                guard let name = file.target.existingTable, let mapping = file.target.mapping else { return nil }
                table = name
                fields = mapping.fieldNames
                columns = mapping.columns
                columnMapping = mapping.columnMapping
            case .newTable:
                guard let name = file.target.tableName,
                      let definition = file.target.newTable.definition(tableName: name) else { return nil }
                table = name
                newTables.append(definition)
                columnMapping = file.target.newTable.columnMapping
                fields = file.target.newTable.fields
                columns = fields.compactMap { columnMapping[$0] }
            }
            items.append(RowImportRunItem(
                url: file.url,
                sourceName: file.sourceName,
                formatId: file.formatId,
                targetTable: table,
                columnMapping: columnMapping,
                sourceFields: Set(fields)
            ))
            mappings.append(PlannedMapping(fields: fields, columns: columns, columnMapping: columnMapping, table: table))
        }
        return Plan(items: items, newTables: newTables, mappings: mappings)
    }

    // MARK: - Summary

    internal func summary(of file: File) -> String {
        switch file.read {
        case .pending, .reading:
            return String(localized: "Reading…")
        case .failed:
            return String(localized: "Cannot read the file")
        case .ready:
            break
        }
        switch file.target.destination {
        case .existingTable:
            guard let mapping = file.target.mapping else { return String(localized: "Reading…") }
            return String(
                format: String(localized: "%1$lld of %2$lld fields mapped"),
                Int64(mapping.mappedFieldCount),
                Int64(mapping.fields.count)
            )
        case .newTable:
            let count = file.target.newTable.columnMapping.count
            return count == 1
                ? String(localized: "1 new column")
                : String(format: String(localized: "%lld new columns"), Int64(count))
        }
    }
}
