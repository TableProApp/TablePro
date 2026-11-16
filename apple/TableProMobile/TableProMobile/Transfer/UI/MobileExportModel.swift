import Foundation
import Observation
import TableProDatabase
import TableProModels
import TableProPluginKit

// What an export is asked to cover. Each entry point offers the scopes that make sense where it was opened.
nonisolated struct ExportScopeOption: Identifiable, Sendable {
    nonisolated enum Kind: String, Sendable, Hashable {
        case currentView
        case wholeTable
        case selectedRows
        case result
        case database
    }

    nonisolated enum Source: Sendable {
        case query(ExportSelect)
        // The user's statement run again, under the engine's read-only mode only.
        case rerun(String)
        case rows(ExportRowSet)
        case table(String)
        case database
    }

    let kind: Kind
    let source: Source
    let detail: String?

    var id: Kind { kind }

    init(kind: Kind, source: Source, detail: String? = nil) {
        self.kind = kind
        self.source = source
        self.detail = detail
    }

    var title: String {
        switch kind {
        case .currentView: String(localized: "Filtered and Sorted")
        case .wholeTable: String(localized: "Whole Table")
        case .selectedRows: String(localized: "Selected Rows")
        case .result: String(localized: "Query Result")
        case .database: String(localized: "Database Objects")
        }
    }

    var listsObjects: Bool {
        switch source {
        case .table, .database: true
        case .query, .rerun, .rows: false
        }
    }
}

nonisolated struct MobileExportInput: Sendable {
    let title: String
    let fileName: String
    let connectionId: UUID
    let databaseType: DatabaseType
    let database: String?
    let schema: String?
    let safeModeLevel: SafeModeLevel
    let scopes: [ExportScopeOption]
}

nonisolated struct ExportFormatChoice: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
}

nonisolated struct ExportObjectGroup: Identifiable, Sendable {
    let kind: PluginExportObjectKind
    let rows: [ExportObjectRow]

    var id: PluginExportObjectKind { kind }
}

nonisolated struct ExportObjectRow: Identifiable, Sendable {
    let id: String
    var object: PluginExportTable
    var isSelected: Bool

    // The type too: a MySQL function and procedure can share a name and a signature, and both are routines.
    init(object: PluginExportTable, isSelected: Bool) {
        self.id = [
            object.kind.rawValue, object.tableType, object.databaseName, object.schema ?? "", object.parentTable ?? "",
            object.identity ?? "", object.name
        ].joined(separator: "\u{1F}")
        self.object = object
        self.isSelected = isSelected
    }
}

// A table's or view's Export names a relation: a routine or trigger of the same name is not it.
nonisolated extension PluginExportObjectKind {
    var isRelation: Bool {
        switch self {
        case .table, .view, .materializedView, .foreignTable: return true
        case .sequence, .userType, .routine, .trigger, .event, .grant: return false
        }
    }
}

// The seams a test replaces: where the formats, the object list and the run come from.
struct MobileExportEnvironment {
    var formats: (DatabaseType) -> [any ExportFormatPlugin]
    var loadObjects: @MainActor (MobileExportInput, any ExportFormatPlugin) async throws -> [PluginExportTable]
    var makeRunner: @MainActor (ExportRequest, any ExportFormatPlugin) -> any ExportRunning
    var sessionDriver: @MainActor () -> (any DatabaseDriver)?
    // The connection's Safe Mode as it is when Export is tapped; nil keeps the level the sheet opened with.
    var safeModeLevel: @MainActor () -> SafeModeLevel? = { nil }
    var sessionHoldsTransaction: @MainActor () -> Bool = { false }

    // The coordinator is the session host: an export that lands on the window's own session runs tracked.
    static func live(connectionManager: ConnectionManager, coordinator: ConnectionCoordinator) -> MobileExportEnvironment {
        MobileExportEnvironment(
            formats: { MobileExportFormats.available(for: $0) },
            loadObjects: { input, plugin in
                try await ExportObjectListing.load(
                    connectionManager: connectionManager, connectionId: input.connectionId,
                    databaseType: input.databaseType, database: input.database, schema: input.schema, plugin: plugin
                )
            },
            makeRunner: { request, plugin in
                let background = TransferBackgroundRun(
                    title: String(format: String(localized: "Exporting %@"), request.fileName),
                    connectionManager: connectionManager,
                    connectionId: request.connectionId
                )
                return ExportRun(
                    request: request, plugin: plugin, connectionManager: connectionManager, background: background,
                    sessionHost: coordinator
                )
            },
            sessionDriver: { [weak coordinator] in coordinator?.session?.driver },
            safeModeLevel: { [weak coordinator] in coordinator?.connection.safeModeLevel },
            sessionHoldsTransaction: { [weak coordinator] in coordinator?.transactionHold != nil }
        )
    }
}

@MainActor
@Observable
final class MobileExportModel {
    enum Phase: Equatable {
        case configuring
        case running(TransferProgress)
        case sharing
        case finished
        case failed(String)
        case cancelled
    }

    struct Finished: Equatable {
        let files: [URL]
        let rowsWritten: Int
        let warnings: [String]
        let notes: [String]
    }

    let input: MobileExportInput
    let formats: [any ExportFormatPlugin]
    private(set) var phase: Phase = .configuring
    private(set) var finished: Finished?
    private(set) var objects: Loadable<[ExportObjectRow]>?
    var fileName: String
    // Set through `selectFormat` and `selectScope`: an @Observable property's didSet also runs from init.
    private(set) var formatId: String
    private(set) var scopeKind: ExportScopeOption.Kind

    @ObservationIgnored private let environment: MobileExportEnvironment
    @ObservationIgnored private var listed: [PluginExportTable] = []
    @ObservationIgnored private var runner: (any ExportRunning)?
    @ObservationIgnored private var outcome: ExportOutcome?
    @ObservationIgnored private var objectsRead: Task<Void, Never>?

    init(input: MobileExportInput, environment: MobileExportEnvironment) {
        self.input = input
        self.environment = environment
        let formats = environment.formats(input.databaseType)
        self.formats = formats
        self.formatId = formats.first.map { type(of: $0).formatId } ?? ""
        self.scopeKind = input.scopes.first?.kind ?? .database
        self.fileName = input.fileName
    }

    func selectFormat(_ id: String) {
        guard id != formatId, formats.contains(where: { type(of: $0).formatId == id }) else { return }
        formatId = id
        applyFormatDefaults()
    }

    func selectScope(_ kind: ExportScopeOption.Kind) async {
        guard kind != scopeKind, input.scopes.contains(where: { $0.kind == kind }) else { return }
        scopeKind = kind
        await loadObjectsIfNeeded()
    }

    var plugin: (any ExportFormatPlugin)? {
        formats.first { type(of: $0).formatId == formatId }
    }

    var formatChoices: [ExportFormatChoice] {
        formats.map { ExportFormatChoice(id: type(of: $0).formatId, name: type(of: $0).formatDisplayName) }
    }

    var scope: ExportScopeOption? {
        input.scopes.first { $0.kind == scopeKind }
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var optionColumns: [PluginExportOptionColumn] {
        plugin.map { type(of: $0).perTableOptionColumns } ?? []
    }

    // The objects this format can write, grouped in dump order.
    var objectGroups: [ExportObjectGroup] {
        guard let rows = objects?.value, let plugin else { return [] }
        let kinds = Set(type(of: plugin).supportedObjectKinds)
        var shown = rows.filter { kinds.contains($0.object.kind) }
        if case .table(let name)? = scope?.source {
            shown = shown.filter { $0.object.name == name && $0.object.kind.isRelation }
        }
        let grouped = Dictionary(grouping: shown, by: \.object.kind)
        return grouped.keys.sorted { $0.dumpOrder < $1.dumpOrder }.map { kind in
            ExportObjectGroup(kind: kind, rows: grouped[kind] ?? [])
        }
    }

    var exportableObjects: [PluginExportTable] {
        guard let plugin else { return [] }
        return objectGroups.flatMap { $0.rows }
            .filter { $0.isSelected && plugin.isExportable(optionValues: $0.object.optionValues, kind: $0.object.kind) }
            .map(\.object)
    }

    var canExport: Bool {
        guard case .configuring = phase, plugin != nil, let scope,
              !fileName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return scope.listsObjects ? !exportableObjects.isEmpty : true
    }

    // MARK: - Objects

    func loadObjectsIfNeeded() async {
        guard let scope, scope.listsObjects, let plugin else { return }
        if case .loaded = objects { return }
        objectsRead?.cancel()
        objects = .loading
        let read = Task { [weak self, input, environment] in
            do {
                let listed = try await environment.loadObjects(input, plugin)
                guard !Task.isCancelled else { return }
                self?.adopt(listed)
            } catch {
                guard !Task.isCancelled else { return }
                self?.objects = .failed(error)
            }
        }
        objectsRead = read
        await read.value
    }

    func retryObjects() async {
        objects = nil
        await loadObjectsIfNeeded()
    }

    // The format can change while the list loads, so the options come from the one chosen now.
    private func adopt(_ listed: [PluginExportTable]) {
        self.listed = listed
        let plugin = plugin
        objects = .loaded(listed.map { object in
            let options = plugin.map { ExportObjectOptions.defaults(for: object.kind, plugin: $0) } ?? object.optionValues
            return ExportObjectRow(object: object.withOptionValues(options), isSelected: selectsAtFirst(object))
        })
    }

    // A table's export lists the whole schema so its definition comes out as the Mac writes it, with only that
    // table ticked.
    private func selectsAtFirst(_ object: PluginExportTable) -> Bool {
        guard case .table(let name)? = scope?.source else { return true }
        return object.name == name && object.kind.isRelation
    }

    // The list holds every kind the database has, so a format that writes more kinds shows them with the selection
    // they had; option values belong to a format and start over at its defaults, as on the Mac.
    private func applyFormatDefaults() {
        guard let plugin, case .loaded(let rows) = objects else { return }
        objects = .loaded(rows.map { row in
            var row = row
            row.object = row.object.withOptionValues(ExportObjectOptions.defaults(for: row.object.kind, plugin: plugin))
            return row
        })
    }

    func setSelected(_ isSelected: Bool, for id: String) {
        mutateRow(id) { $0.isSelected = isSelected }
    }

    func setSelected(_ isSelected: Bool, kind: PluginExportObjectKind) {
        guard case .loaded(let rows) = objects else { return }
        objects = .loaded(rows.map { row in
            guard row.object.kind == kind else { return row }
            var row = row
            row.isSelected = isSelected
            return row
        })
    }

    func setOption(_ value: Bool, at column: Int, for id: String) {
        mutateRow(id) { row in
            var values = row.object.optionValues
            guard values.indices.contains(column) else { return }
            values[column] = value
            row.object = row.object.withOptionValues(values)
        }
    }

    private func mutateRow(_ id: String, _ change: (inout ExportObjectRow) -> Void) {
        guard case .loaded(var rows) = objects, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[index])
        objects = .loaded(rows)
    }

    // MARK: - Run

    // The run gets a copy of the format's settings as they are now, so another window editing the shared form cannot
    // change the name or the content of a file already started.
    func start() {
        guard canExport, let shared = plugin, let scope else { return }
        let plugin = MobileExportFormats.frozen(shared)
        let source: ExportSource
        switch scope.source {
        case .query(let sql): source = .query(sql)
        case .rerun(let sql): source = .rerun(sql)
        case .rows(let rows): source = .rows(rows)
        case .table, .database: source = .objects(exportableObjects)
        }
        let request = ExportRequest(
            formatId: formatId,
            source: source,
            fileName: fileName.trimmingCharacters(in: .whitespaces),
            connectionId: input.connectionId,
            databaseType: input.databaseType,
            database: input.database,
            schema: input.schema,
            safeModeLevel: environment.safeModeLevel() ?? input.safeModeLevel,
            sessionDriver: environment.sessionDriver(),
            sessionHoldsTransaction: environment.sessionHoldsTransaction()
        )
        let runner = environment.makeRunner(request, plugin)
        self.runner = runner
        phase = .running(TransferProgress(stage: .preparing))
        Task { [weak self] in
            do {
                let outcome = try await runner.run { [weak self] progress in
                    Task { @MainActor in self?.progressArrived(progress, from: runner) }
                }
                self?.complete(outcome, from: runner)
            } catch {
                self?.fail(error, from: runner)
            }
        }
    }

    func cancel() {
        runner?.cancel()
    }

    private func progressArrived(_ progress: TransferProgress, from source: any ExportRunning) {
        guard source === runner, case .running = phase else { return }
        phase = .running(progress)
    }

    private func complete(_ outcome: ExportOutcome, from source: any ExportRunning) {
        guard source === runner else {
            outcome.discard()
            return
        }
        runner = nil
        self.outcome = outcome
        finished = Finished(
            files: outcome.files, rowsWritten: outcome.rowsWritten, warnings: outcome.warnings, notes: outcome.notes
        )
        phase = .sharing
    }

    private func fail(_ error: any Error, from source: any ExportRunning) {
        guard source === runner else { return }
        runner = nil
        if error is CancellationError {
            phase = .cancelled
        } else {
            phase = .failed(error.localizedDescription)
        }
    }

    func shareEnded() {
        guard case .sharing = phase else { return }
        phase = .finished
    }

    func reconfigure() {
        guard !isRunning, phase != .sharing else { return }
        discardFile()
        phase = .configuring
    }

    // The sheet is closing: a running export stops and whatever it wrote goes with it.
    func close() {
        runner?.cancel()
        runner = nil
        discardFile()
    }

    private func discardFile() {
        outcome?.discard()
        outcome = nil
        finished = nil
    }
}
