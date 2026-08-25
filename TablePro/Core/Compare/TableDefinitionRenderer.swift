//
//  TableDefinitionRenderer.swift
//  TablePro
//
//  Canonical text for one table's structure, rendered from parsed metadata
//  rather than from driver DDL. Both sides of a comparison render through the
//  same function, so a formatting difference can never show up as a difference.
//

import Foundation

internal enum TableDefinitionRenderer {
    internal static func lines(for snapshot: TableStructureSnapshot) -> [String] {
        var result: [String] = ["TABLE \(snapshot.name)"]

        for column in snapshot.columns {
            result.append("  COLUMN \(column.name) \(column.dataType)\(columnAttributes(column))")
        }

        let primaryKey = snapshot.primaryKeyColumns
        if !primaryKey.isEmpty {
            result.append("  PRIMARY KEY (\(primaryKey.joined(separator: ", ")))")
        }

        for index in snapshot.indexes.filter({ !$0.isPrimary })
            .sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            let unique = index.isUnique ? "UNIQUE " : ""
            var line = "  \(unique)INDEX \(index.name) (\(index.columns.joined(separator: ", "))) USING \(index.type.rawValue)"
            if let whereClause = index.whereClause, !whereClause.isEmpty {
                line += " WHERE \(whereClause)"
            }
            result.append(line)
        }

        for foreignKey in snapshot.foreignKeys
            .sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            let columns = foreignKey.columns.joined(separator: ", ")
            let referenced = foreignKey.referencedColumns.joined(separator: ", ")
            result.append(
                "  FOREIGN KEY \(foreignKey.name) (\(columns)) REFERENCES \(foreignKey.referencedTable) (\(referenced))"
                    + " ON DELETE \(foreignKey.onDelete.rawValue) ON UPDATE \(foreignKey.onUpdate.rawValue)"
            )
        }

        if let engine = snapshot.engine, !engine.isEmpty {
            result.append("  ENGINE \(engine)")
        }
        if let collation = snapshot.collation, !collation.isEmpty {
            result.append("  COLLATE \(collation)")
        }
        return result
    }

    private static func columnAttributes(_ column: EditableColumnDefinition) -> String {
        var parts: [String] = []
        if column.unsigned { parts.append("UNSIGNED") }
        parts.append(column.isNullable ? "NULL" : "NOT NULL")
        if let defaultValue = column.defaultValue, !defaultValue.isEmpty {
            parts.append("DEFAULT \(defaultValue)")
        }
        if column.autoIncrement { parts.append("AUTO_INCREMENT") }
        if let onUpdate = column.onUpdate, !onUpdate.isEmpty { parts.append("ON UPDATE \(onUpdate)") }
        if let charset = column.charset, !charset.isEmpty { parts.append("CHARACTER SET \(charset)") }
        if let collation = column.collation, !collation.isEmpty { parts.append("COLLATE \(collation)") }
        if let comment = column.comment, !comment.isEmpty { parts.append("COMMENT '\(comment)'") }
        return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
    }
}
