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

/// The statements that put deleted rows back, with what has to run around them outside the transaction.
struct RestoreStatements {
    let statements: [ParameterizedStatement]
    /// Run before the transaction opens and after it ends, on the same session: SQL Server's `IDENTITY_INSERT`.
    let prologue: [String]
    let epilogue: [String]

    init(statements: [ParameterizedStatement], prologue: [String] = [], epilogue: [String] = []) {
        self.statements = statements
        self.prologue = prologue
        self.epilogue = epilogue
    }
}

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
    /// The `GENERATED ALWAYS` and SQL Server `IDENTITY` columns among `generatedColumns`, which a restore writes back
    /// rather than leaving to the server. Nil when the source never said, as a record saved before it was kept.
    let identityColumns: Set<String>?

    init(
        tableName: String,
        schemaName: String?,
        columns: [String],
        primaryKeyColumns: [String],
        generatedColumns: Set<String> = [],
        rowMatchPolicy: RowMatchPolicy = .none,
        databaseType: DatabaseType,
        pluginDriver: (any PluginDatabaseDriver)?,
        identityColumns: Set<String>? = []
    ) {
        self.tableName = tableName
        self.schemaName = schemaName
        self.columns = columns
        self.primaryKeyColumns = primaryKeyColumns
        self.generatedColumns = generatedColumns
        self.rowMatchPolicy = rowMatchPolicy
        self.databaseType = databaseType
        self.pluginDriver = pluginDriver
        self.identityColumns = identityColumns
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
        try refuseServerOwnedEdits(in: changes)
        let insertedRowData = insertedRowData.mapValues(leavingServerOwnedColumnsToTheServer)
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

    /// A value staged for a column the server owns can never be written, however it got staged: the grid offers no
    /// editor for one, but the set of such columns is empty until the table's schema arrives, and an edit made in
    /// that window survives its arrival. Sending it fails on the server (SQL Server Msg 8102 for an `IDENTITY`), and a
    /// generator that quietly drops it saves less than the user asked for, so the save is refused with the column
    /// named instead.
    private func refuseServerOwnedEdits(in changes: [RowChange]) throws {
        for change in changes where change.type == .update {
            guard let owned = change.cellChanges.first(where: { generatedColumns.contains($0.columnName) }) else {
                continue
            }
            throw DataWriteError.changeRefused(
                table: tableName,
                kind: .update,
                reason: String(
                    format: String(localized: "The server fills in %@, so it cannot be given a value."),
                    owned.columnName
                )
            )
        }
    }

    /// A new row leaves every column the server owns to the server, whatever the row was staged with.
    private func leavingServerOwnedColumnsToTheServer(_ values: [PluginCellValue]) -> [PluginCellValue] {
        guard !generatedColumns.isEmpty else { return values }
        return values.enumerated().map { index, value in
            guard columns.indices.contains(index), generatedColumns.contains(columns[index]) else { return value }
            return Self.defaultMarker
        }
    }

    private static let defaultMarker = PluginCellValue.text("__DEFAULT__")

    private var rowWriteContext: PluginRowWriteContext {
        var context = PluginRowWriteContext()
        context.serverOwnedColumns = generatedColumns
        context.rowMatchExcludedColumns = rowMatchPolicy.excludedColumns
        context.rowMatchTextColumns = rowMatchPolicy.textColumns
        return context
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
    ///
    /// `absentCells` names, by row index, the fields a row did not have, which stay missing.
    func restoreStatements(
        rows: [[PluginCellValue]],
        absentCells: [Int: Set<Int>] = [:]
    ) throws -> RestoreStatements {
        if let pluginDriver {
            if let restored = pluginDriver.generateIdentityPreservingInsert(
                table: tableName,
                schema: schemaName,
                columns: columns,
                primaryKeyColumns: primaryKeyColumns,
                rows: rows,
                absentCells: absentCells
            ) {
                return RestoreStatements(statements: restored.map {
                    ParameterizedStatement(sql: $0.statement, parameters: $0.parameters.map(\.asAny))
                })
            }
            if pluginOwnsStatementGeneration {
                throw DataWriteError.identityNotPreservable(databaseType.rawValue)
            }
        }

        let restoredIdentity = try identityColumnsToRestore()
        let style = restoredIdentity.isEmpty ? nil : ExplicitIdentityInsert.style(for: databaseType)
        if !restoredIdentity.isEmpty, style == nil {
            throw DataWriteError.identityNotPreservable(databaseType.rawValue)
        }

        let generator = try hostGenerator(
            schemaName: schemaName,
            generatedColumns: generatedColumns.subtracting(restoredIdentity),
            insertOverridesSystemValue: style == .overridingSystemValue
        )
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

        guard style == .identityInsertSession else { return RestoreStatements(statements: statements) }
        let session = ExplicitIdentityInsert.sessionStatements(for: generator.qualifiedTableName)
        return RestoreStatements(statements: statements, prologue: [session.open], epilogue: [session.close])
    }

    /// The identity columns a restored row carries its old value for. A value the server allocated cannot be left to
    /// the server, because the row then comes back under a different one. When the source never said which
    /// generated columns are identity, an allocated value cannot be told from a computed one, key or not, so a row
    /// with any generated column is refused rather than guessed at.
    private func identityColumnsToRestore() throws -> Set<String> {
        guard let identityColumns else {
            guard generatedColumns.isEmpty else {
                throw DataWriteError.identityNotPreservable(databaseType.rawValue)
            }
            return []
        }
        return identityColumns.intersection(generatedColumns).intersection(columns)
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
                insertedRowIndices: [],
                context: PluginRowWriteContext()
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
                insertedRowIndices: keyed.insertedRowIndices,
                context: rowWriteContext
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

    /// A save leaves the table unqualified, as it always has. A restore names the schema the record was saved
    /// against, because the connection may be pointed at another one by the time the rows are asked for back.
    private func hostGenerator(
        schemaName: String? = nil,
        generatedColumns: Set<String>? = nil,
        insertOverridesSystemValue: Bool = false
    ) throws -> SQLStatementGenerator {
        guard PluginManager.shared.editorLanguage(for: databaseType) == .sql else {
            throw DataWriteError.statementGenerationUnavailable(databaseType.rawValue)
        }
        return try SQLStatementGenerator(
            tableName: tableName,
            schemaName: schemaName,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            databaseType: databaseType,
            generatedColumns: generatedColumns ?? self.generatedColumns,
            rowMatchPolicy: rowMatchPolicy,
            insertOverridesSystemValue: insertOverridesSystemValue,
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
        let ordered = changes.sorted { $0.sequence < $1.sequence }
        var keys: [RowID: Int] = [:]
        var rowIDs: [RowID] = []
        for change in ordered where keys[change.rowID] == nil {
            keys[change.rowID] = rowIDs.count
            rowIDs.append(change.rowID)
        }
        self.rowIDs = rowIDs
        self.changes = ordered.compactMap { change in
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
        absentColumns = Self.absentColumns(after: change)
    }

    /// The fields the row has none of once the change is written: the ones an update removes, or
    /// the ones a new row leaves out. Nil when there are none, which is every engine but a
    /// document store.
    static func absentColumns(after change: RowChange) -> Set<Int>? {
        let absent: Set<Int>
        switch change.type {
        case .update:
            absent = Set(change.cellChanges.filter(\.newIsAbsent).map(\.columnIndex))
        case .insert:
            absent = change.absentColumns
        case .delete:
            return nil
        }
        return absent.isEmpty ? nil : absent
    }
}
