//
//  StructureColumnReorderHandler.swift
//  TablePro
//
//  Orchestrates column reorder via ALTER TABLE ... MODIFY COLUMN ... AFTER
//  when the user drags a row in the Structure tab's column list.
//

import Foundation
import os
import TableProPluginKit

@MainActor
enum StructureColumnReorderHandler {
    private static let logger = Logger(subsystem: "com.TablePro", category: "StructureColumnReorderHandler")

    enum ReorderError: LocalizedError {
        case noDriver
        case notSupported
        case invalidIndices
        case sqlGenerationFailed
        case executionFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDriver:
                return String(localized: "No active database connection")
            case .notSupported:
                return String(localized: "Column reorder is not supported for this database type")
            case .invalidIndices:
                return String(localized: "Invalid column indices for reorder operation")
            case .sqlGenerationFailed:
                return String(localized: "Failed to generate SQL for column reorder")
            case .executionFailed(let message):
                return String(localized: "Column reorder failed: \(message)")
            }
        }
    }

    /// Move a column from one position to another in the table's column order.
    ///
    /// - Parameters:
    ///   - fromIndex: The source row index in the NSTableView (0-based).
    ///   - toIndex: The drop target row index from NSTableView's `acceptDrop`.
    ///     This is the row ABOVE which the item will be inserted.
    ///   - workingColumns: The current column definitions in display order.
    ///   - tableName: The table being modified.
    ///   - connectionId: The connection to execute the SQL on.
    static func moveColumn(
        fromIndex: Int,
        toIndex: Int,
        workingColumns: [EditableColumnDefinition],
        tableName: String,
        connectionId: UUID
    ) async throws -> String {
        guard fromIndex >= 0, fromIndex < workingColumns.count,
              toIndex >= 0, toIndex <= workingColumns.count else {
            throw ReorderError.invalidIndices
        }

        guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
            throw ReorderError.noDriver
        }

        guard let adapter = driver as? PluginDriverAdapter else {
            throw ReorderError.notSupported
        }

        let movingColumn = workingColumns[fromIndex]
        let pluginColumn = buildPluginColumn(from: movingColumn)

        // Compute the "after" column name.
        // NSTableView acceptDrop toIndex is the row ABOVE which the drop occurs.
        // toIndex == 0 means FIRST position (afterColumn = nil).
        // Otherwise, build a virtual list with the source removed, then pick
        // the column at (insertionIndex - 1) as the "after" target.
        let afterColumn: String?
        if toIndex == 0 {
            afterColumn = nil
        } else {
            var columnNames = workingColumns.map(\.name)
            columnNames.remove(at: fromIndex)

            // Adjust insertion point: if source was above the drop target, the
            // indices shift down by one after removal.
            let adjustedIndex = fromIndex < toIndex ? toIndex - 1 : toIndex

            // The column just before the insertion point is the "after" target
            let afterIndex = adjustedIndex - 1
            if afterIndex >= 0, afterIndex < columnNames.count {
                afterColumn = columnNames[afterIndex]
            } else {
                afterColumn = nil
            }
        }

        guard let sql = adapter.generateMoveColumnSQL(
            table: tableName,
            column: pluginColumn,
            afterColumn: afterColumn
        ) else {
            throw ReorderError.sqlGenerationFailed
        }

        logger.info("Reordering column '\(movingColumn.name)' — \(sql)")

        do {
            _ = try await driver.execute(query: sql)
        } catch {
            logger.error("Column reorder failed: \(error.localizedDescription, privacy: .public)")
            throw ReorderError.executionFailed(error.localizedDescription)
        }

        return sql
    }

    private static func buildPluginColumn(from col: EditableColumnDefinition) -> PluginColumnDefinition {
        PluginColumnDefinition(
            name: col.name,
            dataType: col.dataType,
            isNullable: col.isNullable,
            defaultValue: col.defaultValue,
            isPrimaryKey: col.isPrimaryKey,
            autoIncrement: col.autoIncrement,
            comment: col.comment,
            unsigned: col.unsigned,
            onUpdate: col.onUpdate
        )
    }
}
