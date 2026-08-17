import Foundation
import TableProPluginKit

extension DamengPluginDriver {
    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let result = try await executeParameterized(
            query: """
                SELECT TABLE_NAME, 'TABLE' AS TABLE_TYPE
                FROM ALL_TABLES
                WHERE OWNER = ?
                UNION ALL
                SELECT VIEW_NAME, 'VIEW'
                FROM ALL_VIEWS
                WHERE OWNER = ?
                ORDER BY 1
                """,
            parameters: [.text(effectiveSchema(schema)), .text(effectiveSchema(schema))]
        )
        return result.rows.compactMap { row in
            guard let name = row[safe: 0]?.asText else { return nil }
            return PluginTableInfo(name: name, type: row[safe: 1]?.asText ?? "TABLE")
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let owner = effectiveSchema(schema)
        let result = try await executeParameterized(
            query: """
                SELECT c.COLUMN_NAME,
                       c.DATA_TYPE,
                       c.DATA_LENGTH,
                       c.DATA_PRECISION,
                       c.DATA_SCALE,
                       c.NULLABLE,
                       CAST(c.DATA_DEFAULT AS VARCHAR(8188)) AS DATA_DEFAULT,
                       CAST(com.COMMENTS AS VARCHAR(8188)) AS COMMENTS,
                       CASE WHEN pk.COLUMN_NAME IS NOT NULL THEN 'Y' ELSE 'N' END AS IS_PK
                FROM ALL_TAB_COLUMNS c
                LEFT JOIN (
                    SELECT acc.COLUMN_NAME
                    FROM ALL_CONS_COLUMNS acc
                    JOIN ALL_CONSTRAINTS ac
                      ON acc.CONSTRAINT_NAME = ac.CONSTRAINT_NAME
                     AND acc.OWNER = ac.OWNER
                    WHERE ac.CONSTRAINT_TYPE = 'P'
                      AND ac.OWNER = ?
                      AND ac.TABLE_NAME = ?
                ) pk ON c.COLUMN_NAME = pk.COLUMN_NAME
                LEFT JOIN ALL_COL_COMMENTS com
                  ON c.OWNER = com.OWNER
                 AND c.TABLE_NAME = com.TABLE_NAME
                 AND c.COLUMN_NAME = com.COLUMN_NAME
                WHERE c.OWNER = ?
                  AND c.TABLE_NAME = ?
                ORDER BY c.COLUMN_ID
                """,
            parameters: [.text(owner), .text(table), .text(owner), .text(table)]
        )
        return result.rows.compactMap { row in
            guard let name = row[safe: 0]?.asText else { return nil }
            return PluginColumnInfo(
                name: name,
                dataType: DamengSchemaValue.fullType(
                    name: row[safe: 1]?.asText ?? "VARCHAR",
                    length: row[safe: 2]?.asText,
                    precision: row[safe: 3]?.asText,
                    scale: row[safe: 4]?.asText
                ),
                isNullable: row[safe: 5]?.asText == "Y",
                isPrimaryKey: row[safe: 8]?.asText == "Y",
                defaultValue: DamengSchemaValue.nonEmpty(row[safe: 6]?.asText),
                comment: DamengSchemaValue.nonEmpty(row[safe: 7]?.asText)
            )
        }
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let owner = effectiveSchema(schema)
        let result = try await executeParameterized(
            query: """
                SELECT c.TABLE_NAME,
                       c.COLUMN_NAME,
                       c.DATA_TYPE,
                       c.DATA_LENGTH,
                       c.DATA_PRECISION,
                       c.DATA_SCALE,
                       c.NULLABLE,
                       CAST(c.DATA_DEFAULT AS VARCHAR(8188)) AS DATA_DEFAULT,
                       CAST(com.COMMENTS AS VARCHAR(8188)) AS COMMENTS,
                       CASE WHEN pk.COLUMN_NAME IS NOT NULL THEN 'Y' ELSE 'N' END AS IS_PK
                FROM ALL_TAB_COLUMNS c
                LEFT JOIN (
                    SELECT acc.OWNER, acc.TABLE_NAME, acc.COLUMN_NAME
                    FROM ALL_CONS_COLUMNS acc
                    JOIN ALL_CONSTRAINTS ac
                      ON acc.CONSTRAINT_NAME = ac.CONSTRAINT_NAME
                     AND acc.OWNER = ac.OWNER
                    WHERE ac.CONSTRAINT_TYPE = 'P'
                ) pk
                  ON c.OWNER = pk.OWNER
                 AND c.TABLE_NAME = pk.TABLE_NAME
                 AND c.COLUMN_NAME = pk.COLUMN_NAME
                LEFT JOIN ALL_COL_COMMENTS com
                  ON c.OWNER = com.OWNER
                 AND c.TABLE_NAME = com.TABLE_NAME
                 AND c.COLUMN_NAME = com.COLUMN_NAME
                WHERE c.OWNER = ?
                ORDER BY c.TABLE_NAME, c.COLUMN_ID
                """,
            parameters: [.text(owner)]
        )
        var columnsByTable: [String: [PluginColumnInfo]] = [:]
        for row in result.rows {
            guard let table = row[safe: 0]?.asText,
                  let name = row[safe: 1]?.asText else {
                continue
            }
            columnsByTable[table, default: []].append(PluginColumnInfo(
                name: name,
                dataType: DamengSchemaValue.fullType(
                    name: row[safe: 2]?.asText ?? "VARCHAR",
                    length: row[safe: 3]?.asText,
                    precision: row[safe: 4]?.asText,
                    scale: row[safe: 5]?.asText
                ),
                isNullable: row[safe: 6]?.asText == "Y",
                isPrimaryKey: row[safe: 9]?.asText == "Y",
                defaultValue: DamengSchemaValue.nonEmpty(row[safe: 7]?.asText),
                comment: DamengSchemaValue.nonEmpty(row[safe: 8]?.asText)
            ))
        }
        return columnsByTable
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let result = try await executeParameterized(
            query: """
                SELECT i.INDEX_NAME,
                       i.UNIQUENESS,
                       ic.COLUMN_NAME,
                       CASE WHEN c.CONSTRAINT_TYPE = 'P' THEN 'Y' ELSE 'N' END AS IS_PK
                FROM ALL_INDEXES i
                JOIN ALL_IND_COLUMNS ic
                  ON i.INDEX_NAME = ic.INDEX_NAME
                 AND i.OWNER = ic.INDEX_OWNER
                LEFT JOIN ALL_CONSTRAINTS c
                  ON i.INDEX_NAME = c.INDEX_NAME
                 AND i.OWNER = c.OWNER
                 AND c.CONSTRAINT_TYPE = 'P'
                WHERE i.TABLE_NAME = ?
                  AND i.OWNER = ?
                ORDER BY i.INDEX_NAME, ic.COLUMN_POSITION
                """,
            parameters: [.text(table), .text(effectiveSchema(schema))]
        )
        var grouped: [String: (isUnique: Bool, isPrimary: Bool, columns: [String])] = [:]
        for row in result.rows {
            guard let name = row[safe: 0]?.asText, let column = row[safe: 2]?.asText else { continue }
            var item = grouped[name] ?? (false, false, [])
            item.isUnique = row[safe: 1]?.asText == "UNIQUE"
            item.isPrimary = row[safe: 3]?.asText == "Y"
            item.columns.append(column)
            grouped[name] = item
        }
        return grouped.map { name, item in
            PluginIndexInfo(
                name: name,
                columns: item.columns,
                isUnique: item.isUnique,
                isPrimary: item.isPrimary
            )
        }.sorted { $0.name < $1.name }
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        let result = try await executeParameterized(
            query: """
                SELECT ac.CONSTRAINT_NAME,
                       acc.COLUMN_NAME,
                       rc.TABLE_NAME,
                       rcc.COLUMN_NAME,
                       ac.DELETE_RULE,
                       rc.OWNER
                FROM ALL_CONSTRAINTS ac
                JOIN ALL_CONS_COLUMNS acc
                  ON ac.CONSTRAINT_NAME = acc.CONSTRAINT_NAME
                 AND ac.OWNER = acc.OWNER
                JOIN ALL_CONSTRAINTS rc
                  ON ac.R_CONSTRAINT_NAME = rc.CONSTRAINT_NAME
                 AND ac.R_OWNER = rc.OWNER
                JOIN ALL_CONS_COLUMNS rcc
                  ON rc.CONSTRAINT_NAME = rcc.CONSTRAINT_NAME
                 AND rc.OWNER = rcc.OWNER
                 AND acc.POSITION = rcc.POSITION
                WHERE ac.CONSTRAINT_TYPE = 'R'
                  AND ac.TABLE_NAME = ?
                  AND ac.OWNER = ?
                ORDER BY ac.CONSTRAINT_NAME, acc.POSITION
                """,
            parameters: [.text(table), .text(effectiveSchema(schema))]
        )
        return result.rows.compactMap { row in
            guard let name = row[safe: 0]?.asText,
                  let column = row[safe: 1]?.asText,
                  let referencedTable = row[safe: 2]?.asText,
                  let referencedColumn = row[safe: 3]?.asText else {
                return nil
            }
            return PluginForeignKeyInfo(
                name: name,
                column: column,
                referencedTable: referencedTable,
                referencedColumn: referencedColumn,
                referencedSchema: row[safe: 5]?.asText,
                onDelete: row[safe: 4]?.asText ?? "NO ACTION"
            )
        }
    }

    func fetchSchemas() async throws -> [String] {
        let result = try await execute(query: """
            SELECT OBJECT_NAME
            FROM ALL_OBJECTS
            WHERE OBJECT_TYPE = 'SCH'
            ORDER BY OBJECT_NAME
            """)
        return result.rows.compactMap { $0.first?.asText }
    }

    func fetchDatabases() async throws -> [String] {
        try await fetchSchemas()
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        let result = try await executeParameterized(
            query: "SELECT COUNT(*) FROM ALL_TABLES WHERE OWNER = ?",
            parameters: [.text(database)]
        )
        return PluginDatabaseMetadata(
            name: database,
            tableCount: result.rows.first?.first?.asText.flatMap(Int.init),
            isSystemDatabase: DamengPlugin.systemSchemaNames.contains(database.uppercased())
        )
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let result = try await executeParameterized(
            query: """
                SELECT t.NUM_ROWS, t.AVG_ROW_LEN, CAST(c.COMMENTS AS VARCHAR(8188)) AS COMMENTS
                FROM ALL_TABLES t
                LEFT JOIN ALL_TAB_COMMENTS c
                  ON t.OWNER = c.OWNER
                 AND t.TABLE_NAME = c.TABLE_NAME
                WHERE t.OWNER = ?
                  AND t.TABLE_NAME = ?
                """,
            parameters: [.text(effectiveSchema(schema)), .text(table)]
        )
        guard let row = result.rows.first else {
            return PluginTableMetadata(tableName: table)
        }
        return PluginTableMetadata(
            tableName: table,
            avgRowLength: row[safe: 1]?.asText.flatMap(Int64.init),
            rowCount: row[safe: 0]?.asText.flatMap(Int64.init),
            comment: DamengSchemaValue.nonEmpty(row[safe: 2]?.asText),
            engine: "DM8"
        )
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let result = try await executeParameterized(
            query: """
                SELECT CAST(TEXT AS VARCHAR(8188)), LENGTHB(TEXT) FROM ALL_VIEWS
                WHERE OWNER = ? AND VIEW_NAME = ?
                """,
            parameters: [.text(effectiveSchema(schema)), .text(view)]
        )
        guard let row = result.rows.first, let definition = row[safe: 0]?.asText else {
            throw DamengError(message: String(localized: "Dameng did not return the view definition."))
        }
        let storedLength = row[safe: 1]?.asText.flatMap(Int.init)
        guard !DamengSchemaValue.isCastTruncated(definition, storedLength: storedLength) else {
            throw DamengError(message: String(localized: """
                Dameng returned only the first 8188 bytes of this view definition. \
                Saving it here would replace the view with the truncated text.
                """))
        }
        return definition
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let owner = effectiveSchema(schema)
        let columns = try await fetchColumns(table: table, schema: owner)
        guard !columns.isEmpty else {
            throw DamengError(message: String(localized: "Dameng did not return the table definition."))
        }
        var definitions = columns.map { column in
            var definition = "    \(quoteIdentifier(column.name)) \(column.dataType)"
            if let defaultValue = column.defaultValue {
                definition += " DEFAULT \(defaultValue)"
            }
            if !column.isNullable {
                definition += " NOT NULL"
            }
            return definition
        }
        let primaryKeys = columns.filter(\.isPrimaryKey).map { quoteIdentifier($0.name) }
        if !primaryKeys.isEmpty {
            definitions.append("    PRIMARY KEY (\(primaryKeys.joined(separator: ", ")))")
        }
        return "CREATE TABLE \(quoteIdentifier(owner)).\(quoteIdentifier(table)) (\n" +
            definitions.joined(separator: ",\n") + "\n);"
    }

    func effectiveSchema(_ schema: String?) -> String {
        if let schema, !schema.isEmpty {
            return schema
        }
        if let currentSchema, !currentSchema.isEmpty {
            return currentSchema
        }
        if !config.database.isEmpty {
            return config.database
        }
        return config.username.uppercased()
    }
}

enum DamengSchemaValue {
    static let castByteLimit = 8_188

    /// The server's own byte length decides truncation. Falling back to the returned length alone would
    /// reject a definition of exactly `castByteLimit` bytes, which the cast returns complete.
    static func isCastTruncated(_ value: String, storedLength: Int?) -> Bool {
        guard let storedLength else { return value.utf8.count >= castByteLimit }
        return storedLength > castByteLimit
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    static func fullType(name: String, length: String?, precision: String?, scale: String?) -> String {
        let type = name.uppercased()
        if ["CHAR", "CHARACTER", "VARCHAR", "VARCHAR2", "BINARY", "VARBINARY"].contains(type),
           let length, let lengthValue = Int(length), lengthValue > 0 {
            return "\(type)(\(lengthValue))"
        }
        if ["DEC", "DECIMAL", "NUMERIC", "NUMBER"].contains(type),
           let precision, let precisionValue = Int(precision), precisionValue > 0 {
            if let scale, let scaleValue = Int(scale), scaleValue > 0 {
                return "\(type)(\(precisionValue),\(scaleValue))"
            }
            return "\(type)(\(precisionValue))"
        }
        if type == "TIMESTAMP", let scale, let scaleValue = Int(scale), scaleValue > 0 {
            return "TIMESTAMP(\(scaleValue))"
        }
        return type
    }
}
