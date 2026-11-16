import Foundation
import Observation
import TableProModels
import TableProPluginKit

// Rows from a CSV, JSON or Excel file into an existing table or one made from the file, as the Mac's row import does.
@MainActor
@Observable
final class MobileRowImportModel {
    enum Destination: Hashable {
        case existingTable
        case newTable
    }

    typealias TableReader = @MainActor (_ table: String) async throws -> (columns: [ColumnInfo], indexes: [IndexInfo])

    let runner: ImportRunController
    let tables: [TableInfo]
    private(set) var destination: Destination
    private(set) var targetTable: String?
    var newTableName: String
    private(set) var writeMode: ImportWriteMode = .insert
    var matchKey: ImportMatchKey?
    private(set) var matchKeys: [ImportMatchKey] = []
    var mapping = ImportFieldMapping()
    var newTable = NewTableDraft()
    private(set) var isReading = false
    private(set) var readError: String?

    @ObservationIgnored private let readTable: TableReader
    @ObservationIgnored private let mappingStore = ImportMappingStore()
    @ObservationIgnored private var fields: [PluginImportField] = []
    @ObservationIgnored private var readGeneration = 0
    @ObservationIgnored private var mappedTable: String?

    init(runner: ImportRunController, tables: [TableInfo], presetTable: String?, readTable: @escaping TableReader) {
        self.runner = runner
        self.tables = tables.filter { $0.type.allowsRowEditing }
        self.readTable = readTable
        let preset = presetTable.flatMap { name in tables.contains { $0.name == name } ? name : nil }
        self.targetTable = preset
        self.destination = .existingTable
        let base = runner.sourceURL.deletingPathExtension().lastPathComponent
        self.newTableName = TransferFiles.sanitizedFileName(base, fallback: "imported_rows")
        runner.willBegin = { [weak self] _ in self?.rememberMapping() }
    }

    var plugin: any ImportFormatPlugin { runner.plugin }
    var context: ImportTargetContext { runner.context }

    var fieldsFollowFileOrder: Bool { type(of: plugin).sourceFieldsFollowFileOrder }

    // MARK: - Choices

    func selectDestination(_ destination: Destination) async {
        guard destination != self.destination else { return }
        self.destination = destination
        if destination == .newTable {
            selectWriteMode(.insert)
        }
        await read()
    }

    func selectTable(_ table: String?) async {
        guard table != targetTable else { return }
        targetTable = table
        mapping.clear()
        matchKeys = []
        matchKey = nil
        mappedTable = nil
        await read()
    }

    // The plugin clears the table before any mode when the option is on, so a mode that matches rows turns it off.
    func selectWriteMode(_ mode: ImportWriteMode) {
        writeMode = mode
        if mode != .insert {
            ImportPluginSettings.setDeletesExistingRows(false, on: plugin)
        }
    }

    // MARK: - Reading

    func start() async {
        guard await runner.stageIfNeeded() else { return }
        await read()
    }

    // A parsing option changed what the fields are; a read in flight for the old ones is dropped.
    func read() async {
        guard let file = runner.file else { return }
        readGeneration += 1
        let generation = readGeneration
        isReading = true
        readError = nil
        defer {
            if generation == readGeneration { isReading = false }
        }
        do {
            switch destination {
            case .existingTable:
                guard let table = targetTable else {
                    fields = []
                    return
                }
                let detected = try await ImportFieldDetection.detectFields(plugin: plugin, at: file.url, targetTable: table)
                guard generation == readGeneration else { return }
                let catalog = try await readTable(table)
                guard generation == readGeneration else { return }
                fields = detected
                applyTable(table, columns: catalog.columns, indexes: catalog.indexes)
            case .newTable:
                let detected = try await ImportFieldDetection.detectFields(plugin: plugin, at: file.url, targetTable: nil)
                guard generation == readGeneration else { return }
                fields = detected
                let databaseTypeId = context.databaseType.rawValue
                let serverVersion = context.serverVersion
                newTable.load(fields: detected) { inferred in
                    ImportTypeMapper.sqlType(for: inferred, databaseTypeId: databaseTypeId, serverVersion: serverVersion)
                }
            }
        } catch {
            guard generation == readGeneration, !(error is CancellationError) else { return }
            readError = error.localizedDescription
        }
    }

    private func applyTable(_ table: String, columns: [ColumnInfo], indexes: [IndexInfo]) {
        let names = columns.map(\.name)
        let saved = mappingStore.overrides(for: mappingKey(table))
        mapping.load(fields: fields.map(\.name), columns: names, saved: saved, keepingChoices: mappedTable == table)
        mappedTable = table
        matchKeys = ImportMatchKey.options(columns: columns, indexes: indexes)
        if let matchKey, matchKeys.contains(matchKey) { return }
        matchKey = matchKeys.first
    }

    private func mappingKey(_ table: String) -> ImportMappingStore.Key {
        ImportMappingStore.Key(
            connectionId: context.connectionId, database: context.database, schema: context.schema, table: table
        )
    }

    private func rememberMapping() {
        guard destination == .existingTable, let table = targetTable, mappedTable == table else { return }
        mappingStore.remember(mapping.overrides, fields: mapping.fields, for: mappingKey(table))
    }

    // MARK: - Validation

    var trimmedNewTableName: String {
        newTableName.trimmingCharacters(in: .whitespaces)
    }

    var validationMessage: String? {
        switch destination {
        case .existingTable:
            if mapping.mapsOneColumnTwice {
                return String(localized: "Each column can be mapped from only one field.")
            }
            guard targetTable != nil, !isReading, readError == nil else { return nil }
            return ImportRowWritingProblem.of(
                mode: writeMode, key: matchKey, mappedColumns: Array(mapping.columnMapping.values)
            )?.message
        case .newTable:
            let name = trimmedNewTableName
            if !name.isEmpty, tables.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return String(format: String(localized: "A table named “%@” already exists."), name)
            }
            return newTable.problem?.message
        }
    }

    var canImport: Bool {
        guard runner.isConfiguring, runner.refusal == nil, !isReading, readError == nil, validationMessage == nil else {
            return false
        }
        switch destination {
        case .existingTable:
            return targetTable != nil && mappedTable == targetTable && mapping.hasMappedField
        case .newTable:
            return !trimmedNewTableName.isEmpty && newTable.hasNamedColumn
        }
    }

    // MARK: - Run

    func requestImport() {
        guard canImport, let file = runner.file, let target = makeTarget() else { return }
        let request = ImportRequest(
            formatId: type(of: plugin).formatId,
            file: file,
            connectionId: context.connectionId,
            connectionName: context.connectionName,
            databaseType: context.databaseType,
            database: context.database,
            safeModeLevel: context.safeModeLevel,
            target: target
        )
        // The settings are taken now, so the delete question and the run read the same ones whatever another window
        // changes on the shared form while the confirmation is open.
        let frozen = MobileImportFormats.frozen(plugin)
        let clears = destination == .existingTable && writeMode == .insert
            && ImportPluginSettings.deletesExistingRows(frozen)
        let extra = clears ? String(
            format: String(localized: "Every row in “%@” is deleted before the file’s rows are inserted."),
            targetTable ?? ""
        ) : nil
        runner.requestImport(request, plugin: frozen, extraConfirmation: extra)
    }

    private func makeTarget() -> RowImportTarget? {
        switch destination {
        case .existingTable:
            guard let table = targetTable else { return nil }
            let rowWriting = writeMode == .insert
                ? ImportRowWriting.insert
                : ImportRowWriting(mode: writeMode, keyColumns: matchKey?.columns ?? [])
            return RowImportTarget(
                table: table, schema: context.schema, columnMapping: mapping.columnMapping,
                sourceFields: mapping.fields, rowWriting: rowWriting
            )
        case .newTable:
            let name = trimmedNewTableName
            guard let definition = newTable.definition(tableName: name) else { return nil }
            return RowImportTarget(
                table: name, schema: context.schema, columnMapping: newTable.columnMapping,
                sourceFields: newTable.fields, rowWriting: .insert, newTable: definition
            )
        }
    }
}
