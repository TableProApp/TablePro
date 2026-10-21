//
//  ERDiagramSchemaEdits.swift
//  TablePro
//

import Combine
import Foundation

enum ERDiagramEditError: LocalizedError, Equatable {
    case columnNotFound(table: String, column: String)
    case foreignKeyNotFound(table: String, name: String)
    case saveInProgress
    case referencedByStagedKey(table: String, column: String)

    var errorDescription: String? {
        switch self {
        case .referencedByStagedKey(let table, let column):
            String(
                format: String(localized: "A foreign key staged in this diagram uses “%1$@.%2$@”. Save or undo that key before renaming the column."),
                table,
                column
            )
        case .saveInProgress:
            String(localized: "The diagram is saving its changes. Make this change once the save has finished.")
        case .columnNotFound(let table, let column):
            String(format: String(localized: "The column “%1$@” is no longer in “%2$@”."), column, table)
        case .foreignKeyNotFound(let table, let name):
            String(format: String(localized: "The foreign key “%1$@” is no longer on “%2$@”."), name, table)
        }
    }
}

// Each edited table stages on a Structure tab session of its own, so Preview SQL and Save run the
// Structure tab's statement generator, Safe Mode check, confirmation and SQLite rebuild review.
@MainActor
final class ERDiagramSchemaEdits {
    let connection: DatabaseConnection
    let databaseName: String
    let schemaName: String?
    private let provider: any ScopedMetadataProviding
    private let executionGate: any ExecutionGate
    private let objectKind: @MainActor (String) -> TableInfo.TableType

    private(set) var sessions: [String: StructureEditingSession] = [:]
    private(set) var tableOrder: [String] = []
    private var undoTables: [String] = []
    private var redoTables: [String] = []
    private var loading: [String: Task<StructureEditingSession, any Error>] = [:]
    private var appliedSubscriptions: [String: AnyCancellable] = [:]
    private var isApplyingQueue = false
    private var generation = 0

    var onChange: (() -> Void)?
    // A SQLite rebuild runs from its review sheet after Save has returned.
    var onAppliedOutsideSave: (() -> Void)?

    init(
        connection: DatabaseConnection,
        databaseName: String,
        schemaName: String?,
        provider: any ScopedMetadataProviding,
        executionGate: any ExecutionGate = ExecutionGateProvider.shared,
        objectKind: @escaping @MainActor (String) -> TableInfo.TableType = { _ in .table }
    ) {
        self.connection = connection
        self.databaseName = databaseName
        self.schemaName = schemaName
        self.provider = provider
        self.executionGate = executionGate
        self.objectKind = objectKind
    }

    var hasChanges: Bool {
        sessions.values.contains { $0.changeManager.hasChanges }
    }

    var isSaving: Bool {
        isApplyingQueue || sessions.values.contains { $0.isApplying || $0.changeManager.isHeldForSave }
    }

    var editedTables: [String] {
        tableOrder.filter { sessions[$0]?.changeManager.hasChanges == true }
    }

    // A key added here may name a column another table only gains in this save, so that table goes
    // first; a key dropped here may hold a column another table drops or changes, so this one goes
    // first. Only the referenced columns count, and a cycle keeps the order the edits were made in.
    var saveOrder: [String] {
        let tables = editedTables
        var prerequisites: [String: Set<String>] = [:]
        for table in tables {
            guard let changes = sessions[table]?.changeManager.pendingChanges.values else { continue }
            for change in changes {
                switch change {
                case .addForeignKey(let key), .modifyForeignKey(_, let key):
                    guard key.referencedTable != table, tables.contains(key.referencedTable),
                          !gainedColumns(of: key.referencedTable).isDisjoint(with: key.referencedColumns)
                    else { continue }
                    prerequisites[table, default: []].insert(key.referencedTable)
                case .deleteForeignKey(let key):
                    guard key.referencedTable != table, tables.contains(key.referencedTable),
                          !changedColumns(of: key.referencedTable).isDisjoint(with: key.referencedColumns)
                    else { continue }
                    prerequisites[key.referencedTable, default: []].insert(table)
                default:
                    continue
                }
            }
        }
        var ordered: [String] = []
        var remaining = tables
        while !remaining.isEmpty {
            let placed = Set(ordered)
            let next = remaining.first { (prerequisites[$0] ?? []).isSubset(of: placed) } ?? remaining[0]
            ordered.append(next)
            remaining.removeAll { $0 == next }
        }
        return ordered
    }

    var canUndo: Bool {
        guard !isSaving, let table = undoTables.last else { return false }
        return sessions[table]?.changeManager.canUndo ?? false
    }

    var canRedo: Bool {
        guard !isSaving, let table = redoTables.last else { return false }
        return sessions[table]?.changeManager.canRedo ?? false
    }

    private func gainedColumns(of table: String) -> Set<String> {
        guard let changes = sessions[table]?.changeManager.pendingChanges.values else { return [] }
        return Set(changes.compactMap { change -> String? in
            switch change {
            case .addColumn(let column): column.name
            case .modifyColumn(let old, let new) where old.name != new.name: new.name
            default: nil
            }
        })
    }

    private func changedColumns(of table: String) -> Set<String> {
        guard let changes = sessions[table]?.changeManager.pendingChanges.values else { return [] }
        return Set(changes.compactMap { change -> String? in
            switch change {
            case .deleteColumn(let column): column.name
            case .modifyColumn(let old, _): old.name
            default: nil
            }
        })
    }

    func tableEdits() -> [String: ERDiagramStagedOverlay.TableEdits] {
        sessions.reduce(into: [:]) { result, entry in
            guard entry.value.changeManager.hasChanges else { return }
            result[entry.key] = ERDiagramStagedOverlay.TableEdits(entry.value.changeManager)
        }
    }

    func workingColumns(of table: String) -> [EditableColumnDefinition]? {
        sessions[table]?.changeManager.workingColumns
    }

    // MARK: - Sessions

    func session(for table: String) async throws -> StructureEditingSession {
        if let existing = sessions[table] { return existing }
        if let inFlight = loading[table] {
            let loaded = try await inFlight.value
            return sessions[table] ?? loaded
        }
        let session = StructureEditingSession(
            identity: "er-diagram.\(databaseName).\(schemaName ?? "").\(table)",
            connection: connection,
            databaseName: databaseName,
            schemaName: schemaName,
            tableName: table,
            objectKind: objectKind(table)
        )
        session.executionGate = executionGate
        let provider = provider
        let task = Task { @MainActor in
            try await session.loadEditingBaseline(provider: provider)
            return session
        }
        loading[table] = task
        defer { loading[table] = nil }
        let loaded = try await task.value
        adopt(loaded, for: table)
        return sessions[table] ?? loaded
    }

    private func adopt(_ session: StructureEditingSession, for table: String) {
        guard sessions[table] == nil else { return }
        sessions[table] = session
        appliedSubscriptions[table] = session.$appliedVersion
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.sessionAppliedOutsideSave(table) }
            }
    }

    private func sessionAppliedOutsideSave(_ table: String) {
        guard !isApplyingQueue, sessions[table]?.changeManager.hasChanges == false else { return }
        forget(table)
        onChange?()
        onAppliedOutsideSave?()
    }

    private func forget(_ table: String) {
        sessions.removeValue(forKey: table)?.releaseViewWiring()
        appliedSubscriptions.removeValue(forKey: table)
        tableOrder.removeAll { $0 == table }
        undoTables.removeAll { $0 == table }
        redoTables.removeAll { $0 == table }
    }

    // A session nothing is staged on holds a baseline that goes stale, so a refresh lets it go.
    func forgetUnedited() {
        for (table, session) in sessions where !session.changeManager.hasChanges && !session.isApplying {
            forget(table)
        }
    }

    private func recordEdit(on table: String) {
        if !tableOrder.contains(table) {
            tableOrder.append(table)
        }
        undoTables.append(table)
        redoTables.removeAll()
        onChange?()
    }

    // MARK: - Staging

    // A save visits the tables it found when it started, so nothing is staged until it has ended:
    // an edit accepted mid-save would be left out of the save that then reports itself complete.
    private func stagingManager(for table: String) async throws -> StructureChangeManager? {
        guard !isSaving else { throw ERDiagramEditError.saveInProgress }
        let started = generation
        let manager = try await session(for: table).changeManager
        guard !isSaving else { throw ERDiagramEditError.saveInProgress }
        // A Discard while the baseline loaded covers this edit too: it was confirmed before the Discard.
        guard generation == started else { return nil }
        return manager
    }

    func addForeignKey(_ foreignKey: EditableForeignKeyDefinition, to table: String) async throws {
        guard let manager = try await stagingManager(for: table) else { return }
        manager.addForeignKey(foreignKey)
        recordEdit(on: table)
    }

    func dropForeignKey(named name: String, column: String, referencing referencedTable: String, on table: String) async throws {
        guard let manager = try await stagingManager(for: table) else { return }
        let previousName = manager.pendingChanges.values.lazy.compactMap { change -> String? in
            guard case .modifyColumn(let old, let new) = change, new.name == column else { return nil }
            return old.name
        }.first
        // A key already staged for dropping keeps its row, and its replacement may share its name.
        guard let foreignKey = manager.workingForeignKeys.first(where: { key in
            if case .deleteForeignKey = manager.pendingChanges[.foreignKey(key.id)] { return false }
            return key.name == name && key.referencedTable == referencedTable
                && (key.columns.contains(column) || previousName.map { key.columns.contains($0) } == true)
        }) else {
            throw ERDiagramEditError.foreignKeyNotFound(table: table, name: name)
        }
        manager.deleteForeignKey(id: foreignKey.id)
        recordEdit(on: table)
    }

    private func isReferencedByStagedKey(table: String, column: String) -> Bool {
        sessions.contains { owner, session in
            session.changeManager.pendingChanges.values.contains { change in
                switch change {
                case .addForeignKey(let key), .modifyForeignKey(_, let key):
                    (key.referencedTable == table && key.referencedColumns.contains(column))
                        || (owner == table && key.columns.contains(column))
                default:
                    false
                }
            }
        }
    }

    func addColumn(_ column: EditableColumnDefinition, to table: String) async throws {
        guard let manager = try await stagingManager(for: table) else { return }
        manager.addColumn(column)
        recordEdit(on: table)
    }

    func renameColumn(_ name: String, to newName: String, on table: String) async throws {
        guard let manager = try await stagingManager(for: table) else { return }
        guard name != newName else { return }
        // The staged key would still name the old column, and its table saves after this one.
        if isReferencedByStagedKey(table: table, column: name) {
            throw ERDiagramEditError.referencedByStagedKey(table: table, column: name)
        }
        guard var column = manager.workingColumns.first(where: { $0.name == name }) else {
            throw ERDiagramEditError.columnNotFound(table: table, column: name)
        }
        column.name = newName
        manager.updateColumn(id: column.id, with: column)
        recordEdit(on: table)
    }

    func dropColumn(_ name: String, on table: String) async throws {
        guard let manager = try await stagingManager(for: table) else { return }
        guard let column = manager.workingColumns.first(where: { $0.name == name }) else {
            throw ERDiagramEditError.columnNotFound(table: table, column: name)
        }
        if case .deleteColumn = manager.pendingChanges[.column(column.id)] { return }
        manager.deleteColumn(id: column.id)
        recordEdit(on: table)
    }

    // MARK: - Undo

    func undo() {
        guard canUndo, let table = undoTables.popLast(), let session = sessions[table] else { return }
        session.changeManager.undo()
        redoTables.append(table)
        onChange?()
    }

    func redo() {
        guard canRedo, let table = redoTables.popLast(), let session = sessions[table] else { return }
        session.changeManager.redo()
        undoTables.append(table)
        onChange?()
    }

    func discardAll() {
        guard !isSaving else { return }
        generation += 1
        for session in sessions.values {
            session.changeManager.discardChanges()
        }
        for table in Array(sessions.keys) {
            forget(table)
        }
        onChange?()
    }

    // MARK: - Preview and Save

    func previewStatements() async -> [String] {
        var statements: [String] = []
        for table in saveOrder {
            guard let session = sessions[table] else { continue }
            do {
                let plan = try await session.stagedSavePlan(for: session.changeManager.getChangesArray())
                statements += plan.displayStatements
            } catch {
                statements.append("-- Error generating SQL: \(error.localizedDescription)")
            }
        }
        return statements
    }

    struct SaveResult: Equatable {
        let outcome: StructureSaveOutcome
        let appliedTables: [String]
    }

    // One table at a time, each through its own session. The first one that does not land stops the run,
    // so what is still staged is exactly what did not reach the database.
    func apply(coordinator: MainContentCoordinator?) async -> SaveResult {
        guard !isApplyingQueue else { return SaveResult(outcome: .refused, appliedTables: []) }
        isApplyingQueue = true
        defer {
            isApplyingQueue = false
            onChange?()
        }
        var applied: [String] = []
        for table in saveOrder {
            guard let session = sessions[table] else { continue }
            let result = await session.applyStagedChanges(coordinator: coordinator)
            switch result {
            case .applied:
                forget(table)
                applied.append(table)
            case .nothingToApply:
                forget(table)
            case .refused, .failed:
                return SaveResult(outcome: result, appliedTables: applied)
            }
        }
        return SaveResult(outcome: applied.isEmpty ? .nothingToApply : .applied, appliedTables: applied)
    }
}
