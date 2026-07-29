import Foundation

public enum MSSQLSchemaQueries {
    public static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    public static func escapeBracket(_ value: String) -> String {
        value.replacingOccurrences(of: "]", with: "]]")
    }

    public static func bracketed(schema: String, table: String) -> String {
        "[\(escapeBracket(schema))].[\(escapeBracket(table))]"
    }

    public static func qualifiedName(schema: String?, table: String) -> String {
        guard let schema, !schema.isEmpty else {
            return "[\(escapeBracket(table))]"
        }
        return bracketed(schema: schema, table: table)
    }

    public static func browse(
        schema: String?,
        table: String,
        orderByClause: String,
        offset: Int,
        limit: Int
    ) -> String {
        let target = qualifiedName(schema: schema, table: table)
        return "SELECT * FROM \(target) \(orderByClause) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
    }

    public static func filtered(
        schema: String?,
        table: String,
        whereClause: String,
        orderByClause: String,
        offset: Int,
        limit: Int
    ) -> String {
        let target = qualifiedName(schema: schema, table: table)
        var query = "SELECT * FROM \(target)"
        if !whereClause.isEmpty {
            query += " WHERE \(whereClause)"
        }
        query += " \(orderByClause) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        return query
    }

    public static let currentSchema = "SELECT SCHEMA_NAME()"
    public static let serverVersion = "SELECT @@VERSION"
    public static let beginTransaction = "BEGIN TRANSACTION"
    public static let commitTransaction = "COMMIT TRANSACTION"
    public static let rollbackTransaction = "ROLLBACK TRANSACTION"
    public static let ping = "SELECT 1"

    public static let databases = "SELECT name FROM sys.databases ORDER BY name"

    public static let schemas = """
        SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA
        WHERE SCHEMA_NAME NOT IN (
            'information_schema','sys','db_owner','db_accessadmin',
            'db_securityadmin','db_ddladmin','db_backupoperator',
            'db_datareader','db_datawriter','db_denydatareader',
            'db_denydatawriter','guest'
        )
        ORDER BY SCHEMA_NAME
        """

    public static func tables(schema: String) -> String {
        let s = escape(schema)
        return """
            SELECT t.TABLE_NAME, t.TABLE_TYPE
            FROM INFORMATION_SCHEMA.TABLES t
            WHERE t.TABLE_SCHEMA = '\(s)'
              AND t.TABLE_TYPE IN ('BASE TABLE', 'VIEW')
            ORDER BY t.TABLE_NAME
            """
    }

    public static func columns(schema: String, table: String) -> String {
        let s = escape(schema)
        let t = escape(table)
        return """
            SELECT
                c.COLUMN_NAME,
                c.DATA_TYPE,
                c.CHARACTER_MAXIMUM_LENGTH,
                c.NUMERIC_PRECISION,
                c.NUMERIC_SCALE,
                c.IS_NULLABLE,
                c.COLUMN_DEFAULT,
                COLUMNPROPERTY(OBJECT_ID(c.TABLE_SCHEMA + '.' + c.TABLE_NAME), c.COLUMN_NAME, 'IsIdentity') AS IS_IDENTITY,
                CASE WHEN pk.COLUMN_NAME IS NOT NULL THEN 1 ELSE 0 END AS IS_PK
            FROM INFORMATION_SCHEMA.COLUMNS c
            LEFT JOIN (
                SELECT kcu.COLUMN_NAME
                FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
                JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu
                    ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
                    AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA
                WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
                    AND tc.TABLE_SCHEMA = '\(s)'
                    AND tc.TABLE_NAME = '\(t)'
            ) pk ON c.COLUMN_NAME = pk.COLUMN_NAME
            WHERE c.TABLE_NAME = '\(t)'
              AND c.TABLE_SCHEMA = '\(s)'
            ORDER BY c.ORDINAL_POSITION
            """
    }

    public static func indexes(schema: String, table: String) -> String {
        let object = bracketed(schema: schema, table: table)
        return """
            SELECT i.name, i.is_unique, i.is_primary_key, c.name AS column_name
            FROM sys.indexes i
            JOIN sys.index_columns ic
                ON i.object_id = ic.object_id AND i.index_id = ic.index_id
            JOIN sys.columns c
                ON ic.object_id = c.object_id AND ic.column_id = c.column_id
            WHERE i.object_id = OBJECT_ID('\(object)')
              AND i.name IS NOT NULL
            ORDER BY i.index_id, ic.key_ordinal
            """
    }

    public static func foreignKeys(schema: String, table: String) -> String {
        let s = escape(schema)
        let t = escape(table)
        return """
            SELECT
                fk.name AS constraint_name,
                cp.name AS column_name,
                tr.name AS ref_table,
                cr.name AS ref_column,
                sr.name AS ref_schema
            FROM sys.foreign_keys fk
            JOIN sys.foreign_key_columns fkc ON fk.object_id = fkc.constraint_object_id
            JOIN sys.tables tp ON fkc.parent_object_id = tp.object_id
            JOIN sys.schemas s ON tp.schema_id = s.schema_id
            JOIN sys.columns cp
                ON fkc.parent_object_id = cp.object_id AND fkc.parent_column_id = cp.column_id
            JOIN sys.tables tr ON fkc.referenced_object_id = tr.object_id
            JOIN sys.schemas sr ON tr.schema_id = sr.schema_id
            JOIN sys.columns cr
                ON fkc.referenced_object_id = cr.object_id AND fkc.referenced_column_id = cr.column_id
            WHERE tp.name = '\(t)' AND s.name = '\(s)'
            ORDER BY fk.name
            """
    }
}

public struct MSSQLTableRow: Sendable, Equatable {
    public let name: String
    public let isView: Bool

    public init(name: String, isView: Bool) {
        self.name = name
        self.isView = isView
    }
}

public struct MSSQLColumnRow: Sendable, Equatable {
    public let name: String
    public let dataType: String
    public let characterMaxLength: Int?
    public let numericPrecision: Int?
    public let numericScale: Int?
    public let isNullable: Bool
    public let defaultValue: String?
    public let isIdentity: Bool
    public let isPrimaryKey: Bool

    public init(
        name: String,
        dataType: String,
        characterMaxLength: Int?,
        numericPrecision: Int?,
        numericScale: Int?,
        isNullable: Bool,
        defaultValue: String?,
        isIdentity: Bool,
        isPrimaryKey: Bool
    ) {
        self.name = name
        self.dataType = dataType
        self.characterMaxLength = characterMaxLength
        self.numericPrecision = numericPrecision
        self.numericScale = numericScale
        self.isNullable = isNullable
        self.defaultValue = defaultValue
        self.isIdentity = isIdentity
        self.isPrimaryKey = isPrimaryKey
    }

    public var displayType: String {
        let base = dataType.lowercased()
        let fixedSize: Set<String> = [
            "int", "bigint", "smallint", "tinyint", "bit",
            "money", "smallmoney", "float", "real",
            "datetime", "datetime2", "smalldatetime", "date", "time",
            "uniqueidentifier", "text", "ntext", "image", "xml",
            "timestamp", "rowversion"
        ]
        if fixedSize.contains(base) {
            return base
        }
        if let len = characterMaxLength {
            return len < 0 ? "\(base)(max)" : "\(base)(\(len))"
        }
        if let p = numericPrecision, let s = numericScale {
            return "\(base)(\(p),\(s))"
        }
        return base
    }
}

public struct MSSQLIndexRow: Sendable, Equatable {
    public let name: String
    public let isUnique: Bool
    public let isPrimary: Bool
    public let columnName: String

    public init(name: String, isUnique: Bool, isPrimary: Bool, columnName: String) {
        self.name = name
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.columnName = columnName
    }
}

public struct MSSQLForeignKeyRow: Sendable, Equatable {
    public let constraintName: String
    public let columnName: String
    public let referencedTable: String
    public let referencedColumn: String
    public let referencedSchema: String?

    public init(
        constraintName: String,
        columnName: String,
        referencedTable: String,
        referencedColumn: String,
        referencedSchema: String? = nil
    ) {
        self.constraintName = constraintName
        self.columnName = columnName
        self.referencedTable = referencedTable
        self.referencedColumn = referencedColumn
        self.referencedSchema = referencedSchema
    }
}

public extension MSSQLSchemaQueries {
    static func parseTableRow(_ row: [String?]) -> MSSQLTableRow? {
        guard let name = row[safe: 0] ?? nil else { return nil }
        let typeRaw = (row[safe: 1] ?? nil) ?? "BASE TABLE"
        return MSSQLTableRow(name: name, isView: typeRaw == "VIEW")
    }

    static func parseColumnRow(_ row: [String?]) -> MSSQLColumnRow? {
        guard let name = row[safe: 0] ?? nil else { return nil }
        return MSSQLColumnRow(
            name: name,
            dataType: (row[safe: 1] ?? nil) ?? "nvarchar",
            characterMaxLength: (row[safe: 2] ?? nil).flatMap { Int($0) },
            numericPrecision: (row[safe: 3] ?? nil).flatMap { Int($0) },
            numericScale: (row[safe: 4] ?? nil).flatMap { Int($0) },
            isNullable: (row[safe: 5] ?? nil) == "YES",
            defaultValue: row[safe: 6] ?? nil,
            isIdentity: (row[safe: 7] ?? nil) == "1",
            isPrimaryKey: (row[safe: 8] ?? nil) == "1"
        )
    }

    static func parseIndexRow(_ row: [String?]) -> MSSQLIndexRow? {
        guard let name = row[safe: 0] ?? nil,
              let column = row[safe: 3] ?? nil
        else { return nil }
        return MSSQLIndexRow(
            name: name,
            isUnique: (row[safe: 1] ?? nil) == "1",
            isPrimary: (row[safe: 2] ?? nil) == "1",
            columnName: column
        )
    }

    static func parseForeignKeyRow(_ row: [String?]) -> MSSQLForeignKeyRow? {
        guard let name = row[safe: 0] ?? nil,
              let column = row[safe: 1] ?? nil,
              let refTable = row[safe: 2] ?? nil,
              let refColumn = row[safe: 3] ?? nil
        else { return nil }
        return MSSQLForeignKeyRow(
            constraintName: name,
            columnName: column,
            referencedTable: refTable,
            referencedColumn: refColumn,
            referencedSchema: row[safe: 4] ?? nil
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
