import Foundation

enum ERDiagramSQLExporter {
    static func generate(
        tableNames: [String],
        allColumns: [String: [ColumnInfo]],
        allForeignKeys: [String: [ForeignKeyInfo]],
        isSQLite: Bool,
        quoteIdentifier: (String) -> String
    ) -> String {
        let orderedTables = tableNames.sorted()
        let exportedTables = Set(orderedTables)

        var statements: [String] = []

        for tableName in orderedTables {
            guard let columns = allColumns[tableName], !columns.isEmpty else { continue }
            let inlineForeignKeys = isSQLite
                ? (allForeignKeys[tableName] ?? []).filter { exportedTables.contains($0.referencedTable) }
                : []
            statements.append(createTableStatement(
                tableName: tableName,
                columns: columns,
                inlineForeignKeys: inlineForeignKeys,
                quoteIdentifier: quoteIdentifier
            ))
        }

        if !isSQLite {
            for tableName in orderedTables {
                guard allColumns[tableName]?.isEmpty == false else { continue }
                let foreignKeys = (allForeignKeys[tableName] ?? []).filter { exportedTables.contains($0.referencedTable) }
                for group in groupByConstraintName(foreignKeys) {
                    statements.append(alterTableForeignKeyStatement(
                        tableName: tableName,
                        group: group,
                        quoteIdentifier: quoteIdentifier
                    ))
                }
            }
        }

        return statements.joined(separator: "\n\n")
    }

    private static func createTableStatement(
        tableName: String,
        columns: [ColumnInfo],
        inlineForeignKeys: [ForeignKeyInfo],
        quoteIdentifier: (String) -> String
    ) -> String {
        let primaryKeyColumns = columns.filter(\.isPrimaryKey).map(\.name)
        let singleColumnPrimaryKey = primaryKeyColumns.count == 1 ? primaryKeyColumns.first : nil

        var lines = columns.map { column in
            columnDefinition(
                column: column,
                inlinePrimaryKey: column.name == singleColumnPrimaryKey,
                quoteIdentifier: quoteIdentifier
            )
        }

        if primaryKeyColumns.count > 1 {
            let cols = primaryKeyColumns.map(quoteIdentifier).joined(separator: ", ")
            lines.append("PRIMARY KEY (\(cols))")
        }

        for group in groupByConstraintName(inlineForeignKeys) {
            lines.append(inlineForeignKeyClause(group: group, quoteIdentifier: quoteIdentifier))
        }

        let body = lines.map { "    \($0)" }.joined(separator: ",\n")
        return "CREATE TABLE \(quoteIdentifier(tableName)) (\n\(body)\n);"
    }

    private static func columnDefinition(
        column: ColumnInfo,
        inlinePrimaryKey: Bool,
        quoteIdentifier: (String) -> String
    ) -> String {
        var definition = "\(quoteIdentifier(column.name)) \(column.dataType)"
        if !column.isNullable {
            definition += " NOT NULL"
        }
        if let defaultValue = column.defaultValue, !defaultValue.isEmpty {
            definition += " DEFAULT \(formatDefaultValue(defaultValue))"
        }
        if inlinePrimaryKey {
            definition += " PRIMARY KEY"
        }
        return definition
    }

    private static func formatDefaultValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let passthroughKeywords: Set<String> = [
            "NULL", "TRUE", "FALSE",
            "CURRENT_TIMESTAMP", "CURRENT_TIMESTAMP()",
            "CURRENT_DATE", "CURRENT_TIME", "NOW()", "LOCALTIMESTAMP"
        ]
        if passthroughKeywords.contains(trimmed.uppercased()) { return trimmed }
        if trimmed.hasPrefix("'") { return trimmed }
        if trimmed.contains("(") || trimmed.contains("::") { return trimmed }
        if Int64(trimmed) != nil { return trimmed }
        if let number = Double(trimmed), number.isFinite { return trimmed }
        let escaped = trimmed.replacingOccurrences(of: "'", with: "''")
        return "'\(escaped)'"
    }

    private static func inlineForeignKeyClause(
        group: [ForeignKeyInfo],
        quoteIdentifier: (String) -> String
    ) -> String {
        let cols = group.map { quoteIdentifier($0.column) }.joined(separator: ", ")
        let refCols = group.map { quoteIdentifier($0.referencedColumn) }.joined(separator: ", ")
        let refTable = quoteIdentifier(group[0].referencedTable)
        var clause = "FOREIGN KEY (\(cols)) REFERENCES \(refTable) (\(refCols))"
        clause += referentialActions(group[0])
        return clause
    }

    private static func alterTableForeignKeyStatement(
        tableName: String,
        group: [ForeignKeyInfo],
        quoteIdentifier: (String) -> String
    ) -> String {
        let cols = group.map { quoteIdentifier($0.column) }.joined(separator: ", ")
        let refCols = group.map { quoteIdentifier($0.referencedColumn) }.joined(separator: ", ")
        let refTable = quoteIdentifier(group[0].referencedTable)
        let constraintName = quoteIdentifier(group[0].name)
        var statement = "ALTER TABLE \(quoteIdentifier(tableName)) ADD CONSTRAINT \(constraintName)"
        statement += " FOREIGN KEY (\(cols)) REFERENCES \(refTable) (\(refCols))"
        statement += referentialActions(group[0])
        return statement + ";"
    }

    private static func referentialActions(_ foreignKey: ForeignKeyInfo) -> String {
        var actions = ""
        let onDelete = foreignKey.onDelete.uppercased()
        let onUpdate = foreignKey.onUpdate.uppercased()
        if onDelete != "NO ACTION" { actions += " ON DELETE \(onDelete)" }
        if onUpdate != "NO ACTION" { actions += " ON UPDATE \(onUpdate)" }
        return actions
    }

    private static func groupByConstraintName(_ foreignKeys: [ForeignKeyInfo]) -> [[ForeignKeyInfo]] {
        var orderedNames: [String] = []
        var groups: [String: [ForeignKeyInfo]] = [:]
        for foreignKey in foreignKeys {
            if groups[foreignKey.name] == nil {
                orderedNames.append(foreignKey.name)
            }
            groups[foreignKey.name, default: []].append(foreignKey)
        }
        return orderedNames.compactMap { groups[$0] }
    }
}
