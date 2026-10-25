//
//  DataTabSQLExporter.swift
//  TablePro
//

import Foundation
import os
import TableProAutocomplete
import TableProPluginKit

@MainActor
final class DataTabSQLExporter: DataGridSQLExporting {
    private static let logger = Logger(subsystem: "com.TablePro", category: "DataTabSQLExporter")

    private let tabId: UUID
    private weak var coordinator: MainContentCoordinator?

    init(tabId: UUID, coordinator: MainContentCoordinator?) {
        self.tabId = tabId
        self.coordinator = coordinator
    }

    private struct Target {
        let tableName: String
        let schemaName: String?
        let primaryKeyColumns: [String]
        let databaseType: DatabaseType
        let connectionId: UUID
        let changeManager: DataChangeManager
        let driver: (any DatabaseDriver)?
    }

    private var target: Target? {
        guard let coordinator,
              let tab = coordinator.tabManager.tabs.first(where: { $0.id == tabId }),
              let tableName = tab.tableContext.tableName else { return nil }
        return Target(
            tableName: tableName,
            schemaName: tab.tableContext.schemaName,
            primaryKeyColumns: tab.tableContext.primaryKeyColumns,
            databaseType: coordinator.connection.type,
            connectionId: coordinator.connectionId,
            changeManager: coordinator.changeManager,
            driver: coordinator.services.databaseManager.driver(for: coordinator.connectionId)
        )
    }

    // The statements leave out the columns the server owns, which only the schema names.
    func canCopyAsInsert(_ rows: TableRows) -> Bool {
        guard let target, target.databaseType != .mongodb, target.databaseType != .redis else { return false }
        return rows.hasAuthoritativeSchema
    }

    // A table without a key is matched on every column, so one no match can compare leaves nothing to find the row by.
    func canCopyAsUpdate(_ rows: TableRows) -> Bool {
        guard canCopyAsInsert(rows), let target else { return false }
        return !target.primaryKeyColumns.isEmpty || rows.rowMatchPolicy.excludedColumns.isEmpty
    }

    func insertStatements(for rowIDs: [RowID], columns: [DataGridColumn], in rows: TableRows) -> String? {
        guard let target else { return nil }
        let projection = VisibleColumnProjection(indices: columns.map(\.dataIndex))
        do {
            let converter = try SQLRowToStatementConverter(
                tableName: target.tableName,
                schemaName: target.schemaName,
                columns: projection.columns(rows.columns),
                primaryKeyColumns: target.primaryKeyColumns,
                databaseType: target.databaseType,
                unwritableColumns: unwritableColumns(in: rows, target: target),
                quoteIdentifier: target.driver?.quoteIdentifier,
                escapeStringLiteral: target.driver?.escapeStringLiteral,
                identifierSpelling: identifierSpelling(for: target)
            )
            let sources = rowIDs.compactMap { rows.row(withID: $0) }.map { row in
                SQLRowToStatementConverter.SourceRow(
                    values: projection.values(Array(row.values)),
                    defaultedColumns: projection.positions(of: stagedDefaults(of: row, target: target)),
                    expressionColumns: projection.positions(of: target.changeManager.expressionColumns(forRow: row.id))
                )
            }
            return nonEmpty(converter.generateInserts(rows: sources))
        } catch {
            Self.logger.error("Copy as INSERT failed: \(error.publicLogShape, privacy: .public)")
            return nil
        }
    }

    // SET covers the columns asked for; the row is found by all of its key, or every stored column, hidden ones included.
    func updateStatements(for rowIDs: [RowID], columns: [DataGridColumn], in rows: TableRows) -> String? {
        guard let target else { return nil }
        do {
            let converter = try SQLRowToStatementConverter(
                tableName: target.tableName,
                schemaName: target.schemaName,
                columns: rows.columns,
                primaryKeyColumns: target.primaryKeyColumns,
                databaseType: target.databaseType,
                unwritableColumns: unwritableColumns(in: rows, target: target),
                rowMatchPolicy: rows.rowMatchPolicy,
                settableColumns: columns.map(\.name),
                quoteIdentifier: target.driver?.quoteIdentifier,
                escapeStringLiteral: target.driver?.escapeStringLiteral,
                identifierSpelling: identifierSpelling(for: target),
                rowUpdateStatement: target.driver?.rowUpdateStatement,
                matchesEveryColumn: target.driver?.primaryKeyNamesOneRow == false
            )
            let sources = rowIDs.compactMap { rows.row(withID: $0) }.map { sourceRow($0, target: target) }
            return nonEmpty(converter.generateUpdates(rows: sources))
        } catch {
            Self.logger.error("Copy as UPDATE failed: \(error.publicLogShape, privacy: .public)")
            return nil
        }
    }

    func inClause(values: [PluginCellValue], column: DataGridColumn) -> String? {
        guard !values.isEmpty else { return nil }
        let databaseType = coordinator?.connection.type
        let converter = InClauseConverter(
            columnIndex: 0,
            columnTypes: [column.type ?? .text(rawType: nil)],
            escapeStringLiteral: target?.driver?.escapeStringLiteral,
            stringLiteralPrefix: SQLStringLiteralPrefix.forDatabaseType(databaseType)
        )
        return converter.generateInClause(rows: values.map { [$0] })
    }

    private func identifierSpelling(for target: Target) -> SQLIdentifierSpelling? {
        guard let rules = target.databaseType.identifierRules else { return nil }
        return SQLIdentifierSpelling(rules: rules, policy: SQLIdentifierCase.stored(for: target.connectionId))
    }

    private func unwritableColumns(in rows: TableRows, target: Target) -> Set<String> {
        let immutable = Set(PluginManager.shared.immutableColumns(for: target.databaseType))
        return Set(rows.columns.filter { name in
            rows.generatedColumns.contains(name) || immutable.contains(name) || !target.changeManager.isColumnWritable(name)
        })
    }

    private func sourceRow(_ row: Row, target: Target) -> SQLRowToStatementConverter.SourceRow {
        var stored = Array(row.values)
        let pendingUpdate = target.changeManager.rowChanges.first { $0.rowID == row.id && $0.type == .update }
        for cellChange in pendingUpdate?.cellChanges ?? [] where stored.indices.contains(cellChange.columnIndex) {
            stored[cellChange.columnIndex] = cellChange.oldValue
        }
        return SQLRowToStatementConverter.SourceRow(
            values: Array(row.values),
            storedValues: stored,
            isPendingInsert: target.changeManager.insertedRowIDs.contains(row.id),
            defaultedColumns: stagedDefaults(of: row, target: target),
            expressionColumns: target.changeManager.expressionColumns(forRow: row.id)
        )
    }

    // Every marker in a row not saved yet, and in a saved row the cells a pending edit set to Default.
    private func stagedDefaults(of row: Row, target: Target) -> Set<Int> {
        let marker = PluginCellValue.text("__DEFAULT__")
        if target.changeManager.insertedRowIDs.contains(row.id) {
            return Set(row.values.indices.filter { row.values[$0] == marker })
        }
        let pendingUpdate = target.changeManager.rowChanges.first { $0.rowID == row.id && $0.type == .update }
        return Set(pendingUpdate?.cellChanges.filter { $0.newValue == marker }.map(\.columnIndex) ?? [])
    }

    private func nonEmpty(_ statements: String) -> String? {
        statements.isEmpty ? nil : statements
    }
}
