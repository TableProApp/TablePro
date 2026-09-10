//
//  RowChangeStatementFactory.swift
//  TablePro
//
//  Turns a set of row changes into statements for the engine in front of it.
//
//  This used to live inside DataChangeManager, which is @MainActor and @Observable and owns the
//  undo stack, so nothing but a live edit session could ask for a statement. Data Rewind needs
//  the same answer for a change set it read back from disk, so the generation moved here and the
//  manager delegates. A plugin that overrides generateStatements therefore serves both paths.
//

import Foundation
import TableProPluginKit

@MainActor
struct RowChangeStatementFactory {
    let tableName: String
    let schemaName: String?
    let columns: [String]
    let primaryKeyColumns: [String]
    let generatedColumns: Set<String>
    let databaseType: DatabaseType
    let pluginDriver: (any PluginDatabaseDriver)?

    init(
        tableName: String,
        schemaName: String?,
        columns: [String],
        primaryKeyColumns: [String],
        generatedColumns: Set<String> = [],
        databaseType: DatabaseType,
        pluginDriver: (any PluginDatabaseDriver)?
    ) {
        self.tableName = tableName
        self.schemaName = schemaName
        self.columns = columns
        self.primaryKeyColumns = primaryKeyColumns
        self.generatedColumns = generatedColumns
        self.databaseType = databaseType
        self.pluginDriver = pluginDriver
    }

    func statements(
        for changes: [RowChange],
        insertedRowData: [Int: [PluginCellValue]] = [:],
        deletedRowIndices: Set<Int> = [],
        insertedRowIndices: Set<Int> = []
    ) throws -> [ParameterizedStatement] {
        if let pluginStatements = pluginGeneratedStatements(
            for: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        ) {
            return pluginStatements
        }
        return try attributedHostStatements(
            for: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        ).map(\.statement)
    }

    /// The host generator's statements, each with the number of rows it should touch.
    ///
    /// Returns nil when the driver writes its own statements, because nothing then tells the host
    /// which rows went into which statement and a guessed count is worse than no count.
    func attributedStatements(
        for changes: [RowChange],
        insertedRowData: [Int: [PluginCellValue]] = [:],
        deletedRowIndices: Set<Int> = [],
        insertedRowIndices: Set<Int> = []
    ) throws -> [AttributedStatement]? {
        if pluginGeneratedStatements(
            for: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        ) != nil {
            return nil
        }
        return try attributedHostStatements(
            for: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        )
    }

    private func attributedHostStatements(
        for changes: [RowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) throws -> [AttributedStatement] {
        let statements = try hostGenerator().generateAttributedStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        )
        try validate(statements.map(\.statement), against: changes, deletedRowIndices: deletedRowIndices)
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
            let change = RowChange(rowIndex: offset, type: .insert, cellChanges: [], originalRow: row)
            let generated = generator.generateStatements(
                from: [change],
                insertedRowData: [offset: row],
                deletedRowIndices: [],
                insertedRowIndices: [offset]
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
    var pluginOwnsStatementGeneration: Bool {
        pluginGeneratedStatements(
            for: [RowChange(rowIndex: 0, type: .update, cellChanges: [], originalRow: nil)],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        ) != nil
    }

    private func pluginGeneratedStatements(
        for changes: [RowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [ParameterizedStatement]? {
        guard let pluginDriver else { return nil }
        let pluginChanges = changes.map(PluginRowChange.init(_:))
        guard let statements = pluginDriver.generateStatements(
            table: tableName,
            schema: schemaName,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            changes: pluginChanges,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        ) else { return nil }
        return statements.map {
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
            dialect: PluginManager.shared.sqlDialect(for: databaseType),
            quoteIdentifier: pluginDriver?.quoteIdentifier
        )
    }

    private func validate(
        _ statements: [ParameterizedStatement],
        against changes: [RowChange],
        deletedRowIndices: Set<Int>
    ) throws {
        let expectedUpdates = changes.count(where: { $0.type == .update })
        let actualUpdates = statements.count(where: { $0.sql.hasPrefix("UPDATE") })
        if expectedUpdates > 0, actualUpdates < expectedUpdates {
            throw DataWriteError.rowsNotIdentifiable(tableName, .update)
        }

        let deletable = changes.filter { $0.type == .delete && deletedRowIndices.contains($0.rowIndex) }
        if !deletable.isEmpty, deletable.allSatisfy({ $0.originalRow == nil }) {
            throw DataWriteError.rowsNotIdentifiable(tableName, .delete)
        }
    }
}

private extension PluginRowChange {
    init(_ change: RowChange) {
        self.init(
            rowIndex: change.rowIndex,
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
