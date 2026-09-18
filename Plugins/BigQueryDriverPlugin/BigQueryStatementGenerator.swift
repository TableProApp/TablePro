import Foundation
import os
import TableProGoogleCloud
import TableProPluginKit

internal struct BigQueryStatementGenerator {
    typealias Statement = (statement: String, parameters: [PluginCellValue])

    static let defaultSentinel = "__DEFAULT__"

    private static let logger = Logger(subsystem: "com.TablePro", category: "BigQueryStatementGenerator")
    private static let placeholder = "?"

    let projectId: String
    let dataset: String
    let tableName: String
    let columns: [String]
    let primaryKeyColumns: [String]
    let nonComparableColumns: Set<String>

    init(
        projectId: String,
        dataset: String,
        tableName: String,
        columns: [String],
        primaryKeyColumns: [String] = [],
        nonComparableColumns: Set<String> = []
    ) {
        self.projectId = projectId
        self.dataset = dataset
        self.tableName = tableName
        self.columns = columns
        self.primaryKeyColumns = primaryKeyColumns
        self.nonComparableColumns = nonComparableColumns
    }

    private var qualifiedTable: String {
        BigQueryQueryBuilder.qualifiedTable(projectId: projectId, dataset: dataset, table: tableName)
    }

    func generateStatements(
        from changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [Statement]? {
        var statements: [Statement] = []
        for change in changes {
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex) else { continue }
                guard let statement = insertStatement(for: change, insertedRowData: insertedRowData) else { continue }
                statements.append(statement)
            case .update:
                guard !change.cellChanges.isEmpty else { continue }
                guard let statement = updateStatement(for: change) else {
                    logUnkeyable("UPDATE")
                    return nil
                }
                statements.append(statement)
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                guard let statement = deleteStatement(for: change) else {
                    logUnkeyable("DELETE")
                    return nil
                }
                statements.append(statement)
            }
        }
        return statements
    }

    private func insertStatement(
        for change: PluginRowChange,
        insertedRowData: [Int: [PluginCellValue]]
    ) -> Statement? {
        guard let firstColumn = columns.first else { return nil }
        let values = insertValues(for: change, insertedRowData: insertedRowData)
        var names: [String] = []
        var parameters: [PluginCellValue] = []
        for column in columns {
            guard let value = values[column], !Self.isDefaultSentinel(value) else { continue }
            names.append(GoogleSQLLiteral.quotedIdentifier(column))
            parameters.append(value)
        }

        guard !names.isEmpty else {
            let target = GoogleSQLLiteral.quotedIdentifier(firstColumn)
            return (statement: "INSERT INTO \(qualifiedTable) (\(target)) VALUES (DEFAULT)", parameters: [])
        }

        let placeholders = Array(repeating: Self.placeholder, count: parameters.count).joined(separator: ", ")
        let statement = "INSERT INTO \(qualifiedTable) (\(names.joined(separator: ", "))) VALUES (\(placeholders))"
        return (statement: statement, parameters: parameters)
    }

    private func insertValues(
        for change: PluginRowChange,
        insertedRowData: [Int: [PluginCellValue]]
    ) -> [String: PluginCellValue] {
        var values: [String: PluginCellValue] = [:]
        if let rowData = insertedRowData[change.rowIndex] {
            for (index, column) in columns.enumerated() where index < rowData.count {
                values[column] = rowData[index]
            }
            return values
        }
        for cellChange in change.cellChanges {
            values[cellChange.columnName] = cellChange.newValue
        }
        return values
    }

    private func updateStatement(for change: PluginRowChange) -> Statement? {
        guard let key = keyCondition(for: change) else { return nil }
        var parameters: [PluginCellValue] = []
        let assignments = change.cellChanges.map { cellChange -> String in
            let column = GoogleSQLLiteral.quotedIdentifier(cellChange.columnName)
            guard !Self.isDefaultSentinel(cellChange.newValue) else { return "\(column) = DEFAULT" }
            parameters.append(cellChange.newValue)
            return "\(column) = \(Self.placeholder)"
        }
        let statement = "UPDATE \(qualifiedTable) SET \(assignments.joined(separator: ", ")) WHERE \(key.clause)"
        return (statement: statement, parameters: parameters + key.parameters)
    }

    private func deleteStatement(for change: PluginRowChange) -> Statement? {
        guard let key = keyCondition(for: change) else { return nil }
        return (statement: "DELETE FROM \(qualifiedTable) WHERE \(key.clause)", parameters: key.parameters)
    }

    private func keyCondition(for change: PluginRowChange) -> (clause: String, parameters: [PluginCellValue])? {
        guard let originalRow = change.originalRow, let keyIndices = keyColumnIndices(rowWidth: originalRow.count) else {
            return nil
        }
        var conditions: [String] = []
        var parameters: [PluginCellValue] = []
        for index in keyIndices {
            let quoted = GoogleSQLLiteral.quotedIdentifier(columns[index])
            let value = originalRow[index]
            guard !value.isNull else {
                conditions.append("\(quoted) IS NULL")
                continue
            }
            conditions.append("\(quoted) = \(Self.placeholder)")
            parameters.append(value)
        }
        return (clause: conditions.joined(separator: " AND "), parameters: parameters)
    }

    private func keyColumnIndices(rowWidth: Int) -> [Int]? {
        guard primaryKeyColumns.isEmpty else { return primaryKeyIndices(rowWidth: rowWidth) }
        let indices = columns.indices.filter { index in
            index < rowWidth && !nonComparableColumns.contains(columns[index])
        }
        return indices.isEmpty ? nil : indices
    }

    private func primaryKeyIndices(rowWidth: Int) -> [Int]? {
        var indices: [Int] = []
        for keyColumn in primaryKeyColumns {
            guard let index = columns.firstIndex(of: keyColumn), index < rowWidth else { return nil }
            indices.append(index)
        }
        return indices
    }

    private func logUnkeyable(_ kind: String) {
        Self.logger.warning(
            "Refusing the save: a \(kind, privacy: .public) on \(self.tableName, privacy: .private) has no usable row key"
        )
    }

    private static func isDefaultSentinel(_ value: PluginCellValue) -> Bool {
        value.asText == defaultSentinel
    }
}
