import Foundation
import TableProPluginKit

/// Turns grid edits into PartiQL, one statement per changed row, every value a `?` parameter.
///
/// The statements carry no types. A cell has none to give, and guessing one is how every edit used
/// to write a String; the driver types each parameter when the statement runs, from the key schema
/// and the item as it is then. An UPDATE also compares every attribute it changes with the value
/// the grid loaded, so it neither recreates an item someone deleted nor overwrites one someone
/// changed.
struct DynamoDBWriteStatements {
    static let defaultSentinel = "__DEFAULT__"

    let table: String
    let columns: [String]
    let keyColumns: [String]

    func statements(
        for changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])] {
        changes.compactMap { change in
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex) else { return nil }
                return insert(change, rowData: insertedRowData[change.rowIndex])
            case .update:
                return update(change)
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { return nil }
                return delete(change)
            }
        }
    }

    func insert(row: [PluginCellValue]) -> (statement: String, parameters: [PluginCellValue]) {
        var names: [String] = []
        var parameters: [PluginCellValue] = []
        for (index, column) in columns.enumerated() where index < row.count {
            let value = row[index]
            if case .null = value { continue }
            if case .text(let text) = value, text == Self.defaultSentinel { continue }
            names.append(column)
            parameters.append(value)
        }
        let entries = names.map { "\(Self.literal($0)): ?" }.joined(separator: ", ")
        return ("INSERT INTO \(DynamoDBStatement.quote(table)) VALUE {\(entries)}", parameters)
    }

    private func insert(
        _ change: PluginRowChange,
        rowData: [PluginCellValue]?
    ) -> (statement: String, parameters: [PluginCellValue]) {
        if let rowData {
            return insert(row: rowData)
        }
        var row = [PluginCellValue](repeating: .null, count: columns.count)
        for cell in change.cellChanges where cell.columnIndex < row.count {
            row[cell.columnIndex] = cell.newValue
        }
        return insert(row: row)
    }

    private func update(_ change: PluginRowChange) -> (statement: String, parameters: [PluginCellValue])? {
        guard let original = change.originalRow, !change.cellChanges.isEmpty else { return nil }
        var assignments: [String] = []
        var assignedValues: [PluginCellValue] = []
        var removals: [String] = []
        var guards: [String] = []
        var guardValues: [PluginCellValue] = []

        for cell in change.cellChanges {
            let name = DynamoDBStatement.quote(cell.columnName)
            if case .null = cell.newValue {
                removals.append(name)
            } else {
                assignments.append("\(name) = ?")
                assignedValues.append(cell.newValue)
            }
            guard !keyColumns.contains(cell.columnName) else { continue }
            if case .null = cell.oldValue { continue }
            guards.append("\(name) = ?")
            guardValues.append(cell.oldValue)
        }
        guard !assignments.isEmpty || !removals.isEmpty else { return nil }

        let key = keyCondition(original)
        var statement = "UPDATE \(DynamoDBStatement.quote(table))"
        if !assignments.isEmpty {
            statement += " SET " + assignments.joined(separator: ", ")
        }
        if !removals.isEmpty {
            statement += " REMOVE " + removals.joined(separator: ", ")
        }
        statement += " WHERE " + (key.terms + guards).joined(separator: " AND ")
        return (statement, assignedValues + key.values + guardValues)
    }

    private func delete(_ change: PluginRowChange) -> (statement: String, parameters: [PluginCellValue])? {
        guard let original = change.originalRow else { return nil }
        let key = keyCondition(original)
        let statement = "DELETE FROM \(DynamoDBStatement.quote(table)) WHERE "
            + key.terms.joined(separator: " AND ") + " RETURNING ALL OLD *"
        return (statement, key.values)
    }

    private func keyCondition(_ row: [PluginCellValue]) -> (terms: [String], values: [PluginCellValue]) {
        var terms: [String] = []
        var values: [PluginCellValue] = []
        for column in keyColumns {
            guard let index = columns.firstIndex(of: column), index < row.count else { continue }
            terms.append("\(DynamoDBStatement.quote(column)) = ?")
            values.append(row[index])
        }
        return (terms, values)
    }

    static func literal(_ name: String) -> String {
        "'\(name.replacingOccurrences(of: "'", with: "''"))'"
    }
}

/// Types the `?` parameters of a PartiQL statement when it runs.
///
/// A key attribute takes its declared type. Any other attribute takes the type of its current
/// value in the item, then the type its column shows, and only then a String: a Number is never
/// read out of text that happens to look like one.
struct DynamoDBParameterBinder {
    let schema: DynamoDBTableSchema?
    let observedTypes: [String: DynamoDBAttributeType]
    let currentItem: DynamoDBItem?

    func bind(
        _ parameters: [PluginCellValue],
        roles: [DynamoDBPartiQL.ParameterRole]
    ) throws -> [DynamoDBAttributeValue] {
        try parameters.enumerated().map { index, cell in
            let role = index < roles.count ? roles[index] : .unknown
            return try bind(cell, role: role)
        }
    }

    private func bind(_ cell: PluginCellValue, role: DynamoDBPartiQL.ParameterRole) throws -> DynamoDBAttributeValue {
        switch role {
        case .assigned(let path):
            if path.isTopLevel, schema?.keys.attributes.contains(path.root) == true {
                throw DynamoDBError.invalidValue(attribute: path.root, reason: String(
                    localized: "DynamoDB can't change a key. Duplicate the row with the new key, then delete the old one."
                ))
            }
            if path.isTopLevel, let keyType = indexKeyType(path.root) {
                return try keyValue(cell, type: keyType, attribute: path.root)
            }
            return try typed(cell, path: path)
        case .compared(let path):
            if path.isTopLevel, let keyType = indexKeyType(path.root) {
                return try keyValue(cell, type: keyType, attribute: path.root)
            }
            return try typed(cell, path: path)
        case .inserted(let attribute):
            if let keyType = indexKeyType(attribute) {
                return try keyValue(cell, type: keyType, attribute: attribute)
            }
            return try typed(cell, path: DynamoDBAttributePath(attribute: attribute))
        case .unknown:
            return untyped(cell)
        }
    }

    /// The declared type of a key attribute of the table or of any of its indexes.
    private func indexKeyType(_ attribute: String) -> DynamoDBAttributeType? {
        guard let schema, schema.allKeyAttributes.contains(attribute) else { return nil }
        return schema.keyType(of: attribute)
    }

    private func typed(_ cell: PluginCellValue, path: DynamoDBAttributePath) throws -> DynamoDBAttributeValue {
        let template = currentItem.flatMap { path.value(in: $0) }
        let decoded = try DynamoDBCellCodec.decode(
            cell,
            template: template,
            columnType: path.isTopLevel ? observedTypes[path.root] : nil,
            attribute: path.isTopLevel ? path.root : Self.describe(path)
        )
        return decoded ?? .null
    }

    private static func describe(_ path: DynamoDBAttributePath) -> String {
        path.segments.map { segment -> String in
            switch segment {
            case .name(let name): return ".\(name)"
            case .index(let position): return "[\(position)]"
            }
        }.joined().dropFirst().description
    }

    private func keyValue(
        _ cell: PluginCellValue,
        type: DynamoDBAttributeType,
        attribute: String
    ) throws -> DynamoDBAttributeValue {
        switch cell {
        case .null:
            throw DynamoDBError.invalidValue(
                attribute: attribute, reason: String(localized: "A key attribute needs a value")
            )
        case .bytes(let data):
            guard type == .binary else {
                throw DynamoDBError.invalidValue(
                    attribute: attribute,
                    reason: String(format: String(localized: "This key is a %@, not binary data"), type.displayName)
                )
            }
            return .binary(data)
        case .text(let text):
            guard !text.isEmpty, text != DynamoDBWriteStatements.defaultSentinel else {
                throw DynamoDBError.invalidValue(
                    attribute: attribute, reason: String(localized: "A key attribute needs a value")
                )
            }
            return try DynamoDBCellCodec.decode(text: text, as: type, template: nil, attribute: attribute)
        }
    }

    private func untyped(_ cell: PluginCellValue) -> DynamoDBAttributeValue {
        switch cell {
        case .null: return .null
        case .bytes(let data): return .binary(data)
        case .text(let text): return .string(text)
        }
    }
}
