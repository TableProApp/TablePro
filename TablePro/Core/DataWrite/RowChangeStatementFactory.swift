//
//  RowChangeStatementFactory.swift
//  TablePro
//
//  Turns a set of row changes into statements for the engine in front of it.
//
//  This used to live inside DataChangeManager, which is @MainActor and @Observable and owns the
//  undo stack, so nothing but a live edit session could ask for a statement. Data Rewind needs
//  the same answer for a change set it read back from disk, so the generation moved here and the
//  manager delegates. A plugin that implements generateRowWrites therefore serves both paths, and
//  both are held to RowWriteCoverage: a pending change no statement writes refuses the save.
//

import Foundation
import TableProPluginKit

/// The statements for a set of row changes, by who wrote them.
enum RowWriteStatements {
    /// The host's, each carrying the rows it should touch.
    case counted([AttributedStatement])
    /// A driver's, which carry no count the host can hold the server to.
    case driverWritten([ParameterizedStatement])
}

@MainActor
struct RowChangeStatementFactory {
    let tableName: String
    let schemaName: String?
    let columns: [String]
    let primaryKeyColumns: [String]
    let generatedColumns: Set<String>
    let rowMatchPolicy: RowMatchPolicy
    let databaseType: DatabaseType
    let pluginDriver: (any PluginDatabaseDriver)?

    init(
        tableName: String,
        schemaName: String?,
        columns: [String],
        primaryKeyColumns: [String],
        generatedColumns: Set<String> = [],
        rowMatchPolicy: RowMatchPolicy = .none,
        databaseType: DatabaseType,
        pluginDriver: (any PluginDatabaseDriver)?
    ) {
        self.tableName = tableName
        self.schemaName = schemaName
        self.columns = columns
        self.primaryKeyColumns = primaryKeyColumns
        self.generatedColumns = generatedColumns
        self.rowMatchPolicy = rowMatchPolicy
        self.databaseType = databaseType
        self.pluginDriver = pluginDriver
    }

    func statements(
        for changes: [RowChange],
        insertedRowData: [RowID: [PluginCellValue]] = [:],
        deletedRowIDs: Set<RowID> = [],
        insertedRowIDs: Set<RowID> = []
    ) throws -> [ParameterizedStatement] {
        switch try rowWriteStatements(
            for: changes,
            insertedRowData: insertedRowData,
            deletedRowIDs: deletedRowIDs,
            insertedRowIDs: insertedRowIDs
        ) {
        case .counted(let statements):
            return statements.map(\.statement)
        case .driverWritten(let statements):
            return statements
        }
    }

    /// Every statement the changes need, or a throw naming the changes that would be left out.
    ///
    /// The host's statements carry the rows they touch, so the executor can hold the server to that
    /// count. A driver's do not, because nothing tells the host how many rows its statements reach.
    func rowWriteStatements(
        for changes: [RowChange],
        insertedRowData: [RowID: [PluginCellValue]] = [:],
        deletedRowIDs: Set<RowID> = [],
        insertedRowIDs: Set<RowID> = []
    ) throws -> RowWriteStatements {
        if let driverStatements = try pluginRowWrites(
            for: changes,
            insertedRowData: insertedRowData,
            deletedRowIDs: deletedRowIDs,
            insertedRowIDs: insertedRowIDs
        ) {
            return .driverWritten(driverStatements)
        }
        return .counted(
            try hostStatements(
                for: changes,
                insertedRowData: insertedRowData,
                deletedRowIDs: deletedRowIDs,
                insertedRowIDs: insertedRowIDs
            )
        )
    }

    private func hostStatements(
        for changes: [RowChange],
        insertedRowData: [RowID: [PluginCellValue]],
        deletedRowIDs: Set<RowID>,
        insertedRowIDs: Set<RowID>
    ) throws -> [AttributedStatement] {
        let statements = try hostGenerator().generateAttributedStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIDs: deletedRowIDs,
            insertedRowIDs: insertedRowIDs
        )
        let unwritten = RowWriteCoverage.unwrittenChanges(
            changes,
            deletedRowIDs: deletedRowIDs,
            insertedRowIDs: insertedRowIDs,
            writtenRowIDs: Set(statements.flatMap(\.rowIDs))
        )
        if let kind = UnwrittenRowCounts(unwritten).leadingKind {
            throw DataWriteError.rowsNotIdentifiable(tableName, kind)
        }
        return statements
    }

    /// Restores a row the user deleted, keeping the identity it had.
    ///
    /// A plugin's ordinary insert is written for a row the user just added, so it is free to let
    /// the server pick the key: MongoDB's drops `_id` on purpose. Replaying that to undo a delete
    /// produces a different document rather than the one that went missing, so a driver with its
    /// own statement generation has to answer this separately or say it cannot.
    func restoreStatements(rows: [[PluginCellValue]]) throws -> [ParameterizedStatement] {
        if let pluginDriver {
            if let restored = pluginDriver.generateIdentityPreservingInsert(
                table: tableName,
                schema: schemaName,
                columns: columns,
                primaryKeyColumns: primaryKeyColumns,
                rows: rows
            ) {
                return restored.map {
                    ParameterizedStatement(sql: $0.statement, parameters: $0.parameters.map(\.asAny))
                }
            }
            if pluginOwnsStatementGeneration {
                throw DataWriteError.identityNotPreservable(databaseType.rawValue)
            }
        }

        let generator = try hostGenerator()
        var statements: [ParameterizedStatement] = []
        for (offset, row) in rows.enumerated() {
            let rowID = RowID.existing(offset)
            let change = RowChange(rowID: rowID, type: .insert, cellChanges: [], originalRow: row)
            let generated = generator.generateStatements(
                from: [change],
                insertedRowData: [rowID: row],
                deletedRowIDs: [],
                insertedRowIDs: [rowID]
            )
            guard let statement = generated.first else {
                throw DataWriteError.statementGenerationFailed(tableName)
            }
            statements.append(statement)
        }
        return statements
    }

    /// True when the engine's statements come from the plugin rather than from
    /// `SQLStatementGenerator`, which is what decides whether the host may fall back.
    ///
    /// A driver that throws on the probe is refusing a change it owns, so it still owns the engine.
    var pluginOwnsStatementGeneration: Bool {
        guard let pluginDriver else { return false }
        let probe = PluginRowChange(rowIndex: 0, type: .update, cellChanges: [], originalRow: nil)
        do {
            return try pluginDriver.generateRowWrites(
                table: tableName,
                schema: schemaName,
                columns: columns,
                primaryKeyColumns: primaryKeyColumns,
                changes: [probe],
                insertedRowData: [:],
                deletedRowIndices: [],
                insertedRowIndices: []
            ) != nil
        } catch {
            return true
        }
    }

    private func pluginRowWrites(
        for changes: [RowChange],
        insertedRowData: [RowID: [PluginCellValue]],
        deletedRowIDs: Set<RowID>,
        insertedRowIDs: Set<RowID>
    ) throws -> [ParameterizedStatement]? {
        guard let pluginDriver else { return nil }
        let keyed = PluginKeyedChanges(
            changes: changes,
            insertedRowData: insertedRowData,
            deletedRowIDs: deletedRowIDs,
            insertedRowIDs: insertedRowIDs
        )
        let writes: [PluginRowWrite]
        do {
            guard let generated = try pluginDriver.generateRowWrites(
                table: tableName,
                schema: schemaName,
                columns: columns,
                primaryKeyColumns: primaryKeyColumns,
                changes: keyed.changes,
                insertedRowData: keyed.insertedRowData,
                deletedRowIndices: keyed.deletedRowIndices,
                insertedRowIndices: keyed.insertedRowIndices
            ) else { return nil }
            writes = generated
        } catch let refusal as PluginRowWriteRefusal {
            throw DataWriteError.changeRefused(
                table: tableName, kind: keyed.writeKind(ofRowIndex: refusal.rowIndex), reason: refusal.reason
            )
        } catch {
            throw DataWriteError.changeRefused(table: tableName, kind: nil, reason: error.localizedDescription)
        }

        let unwritten = RowWriteCoverage.unwrittenChanges(
            changes,
            deletedRowIDs: deletedRowIDs,
            insertedRowIDs: insertedRowIDs,
            writtenRowIDs: Set(writes.flatMap(\.rowIndices).compactMap(keyed.rowID(forIndex:)))
        )
        guard unwritten.isEmpty else {
            throw DataWriteError.changesNotWritable(table: tableName, unwritten: UnwrittenRowCounts(unwritten))
        }
        return writes.map {
            ParameterizedStatement(sql: $0.statement, parameters: $0.parameters.map(\.asAny))
        }
    }

    private func hostGenerator() throws -> SQLStatementGenerator {
        guard PluginManager.shared.editorLanguage(for: databaseType) == .sql else {
            throw DataWriteError.statementGenerationUnavailable(databaseType.rawValue)
        }
        return try SQLStatementGenerator(
            tableName: tableName,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            databaseType: databaseType,
            generatedColumns: generatedColumns,
            rowMatchPolicy: rowMatchPolicy,
            dialect: PluginManager.shared.sqlDialect(for: databaseType),
            quoteIdentifier: pluginDriver?.quoteIdentifier
        )
    }
}

struct PluginKeyedChanges {
    let changes: [PluginRowChange]
    let insertedRowData: [Int: [PluginCellValue]]
    let deletedRowIndices: Set<Int>
    let insertedRowIndices: Set<Int>
    /// The row each key stands for, indexed by key.
    let rowIDs: [RowID]

    init(
        changes: [RowChange],
        insertedRowData: [RowID: [PluginCellValue]],
        deletedRowIDs: Set<RowID>,
        insertedRowIDs: Set<RowID>
    ) {
        var keys: [RowID: Int] = [:]
        var rowIDs: [RowID] = []
        for change in changes where keys[change.rowID] == nil {
            keys[change.rowID] = rowIDs.count
            rowIDs.append(change.rowID)
        }
        self.rowIDs = rowIDs
        self.changes = changes.compactMap { change in
            keys[change.rowID].map { PluginRowChange(change, key: $0) }
        }
        self.insertedRowData = Dictionary(
            uniqueKeysWithValues: insertedRowData.compactMap { rowID, values in
                keys[rowID].map { ($0, values) }
            }
        )
        self.deletedRowIndices = Set(deletedRowIDs.compactMap { keys[$0] })
        self.insertedRowIndices = Set(insertedRowIDs.compactMap { keys[$0] })
    }

    /// The row a driver's `rowIndex` names, or nil when it names none of these changes.
    func rowID(forIndex index: Int) -> RowID? {
        rowIDs.indices.contains(index) ? rowIDs[index] : nil
    }

    func writeKind(ofRowIndex index: Int) -> RowWriteKind? {
        guard let change = changes.first(where: { $0.rowIndex == index }) else { return nil }
        switch change.type {
        case .insert: return .insert
        case .update: return .update
        case .delete: return .delete
        }
    }
}

private extension PluginRowChange {
    init(_ change: RowChange, key: Int) {
        self.init(
            rowIndex: key,
            type: {
                switch change.type {
                case .insert: return .insert
                case .update: return .update
                case .delete: return .delete
                }
            }(),
            cellChanges: change.cellChanges.map {
                ($0.columnIndex, $0.columnName, $0.oldValue, $0.newValue)
            },
            originalRow: change.originalRow
        )
    }
}
