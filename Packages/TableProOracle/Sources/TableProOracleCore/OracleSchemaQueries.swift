import Foundation

public struct OracleTableRow: Sendable, Equatable {
    public let name: String
    public let isView: Bool
}

public struct OracleColumnRow: Sendable, Equatable {
    public let name: String
    public let dataType: String
    public let dataLength: String?
    public let precision: String?
    public let scale: String?
    public let isNullable: Bool
    public let isPrimaryKey: Bool

    public var displayType: String {
        OracleSchemaQueries.fullType(
            dataType: dataType,
            dataLength: dataLength,
            precision: precision,
            scale: scale
        )
    }
}

public struct OracleIndexRow: Sendable, Equatable {
    public let name: String
    public let isUnique: Bool
    public let columnName: String
    public let isPrimary: Bool
}

public struct OracleForeignKeyRow: Sendable, Equatable {
    public let constraintName: String
    public let columnName: String
    public let referencedTable: String
    public let referencedColumn: String
    public let referencedSchema: String?
    public let deleteRule: String
}

public enum OracleSchemaQueries {
    public static let ping = "SELECT 1 FROM DUAL"
    public static let currentSchema = "SELECT SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') FROM DUAL"
    public static let serverVersion = "SELECT BANNER FROM V$VERSION WHERE ROWNUM = 1"
    public static let users = "SELECT USERNAME FROM ALL_USERS ORDER BY USERNAME"
    public static let commitTransaction = "COMMIT"
    public static let rollbackTransaction = "ROLLBACK"

    public static func escapeLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    public static func quoteIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    public static func setCurrentSchema(_ schema: String) -> String {
        "ALTER SESSION SET CURRENT_SCHEMA = \(quoteIdentifier(schema))"
    }

    public static func tables(schema: String) -> String {
        let owner = escapeLiteral(schema)
        return """
            SELECT table_name, 'BASE TABLE' AS table_type FROM all_tables WHERE owner = '\(owner)'
            UNION ALL
            SELECT view_name, 'VIEW' FROM all_views WHERE owner = '\(owner)'
            ORDER BY 1
            """
    }

    public static func columns(schema: String, table: String) -> String {
        let owner = escapeLiteral(schema)
        let tableName = escapeLiteral(table)
        return """
            SELECT
                c.COLUMN_NAME,
                c.DATA_TYPE,
                c.DATA_LENGTH,
                c.DATA_PRECISION,
                c.DATA_SCALE,
                c.NULLABLE,
                CASE WHEN cc.COLUMN_NAME IS NOT NULL THEN 'Y' ELSE 'N' END AS IS_PK
            FROM ALL_TAB_COLUMNS c
            LEFT JOIN (
                SELECT acc.COLUMN_NAME
                FROM ALL_CONS_COLUMNS acc
                JOIN ALL_CONSTRAINTS ac ON acc.CONSTRAINT_NAME = ac.CONSTRAINT_NAME
                    AND acc.OWNER = ac.OWNER
                WHERE ac.CONSTRAINT_TYPE = 'P'
                    AND ac.OWNER = '\(owner)'
                    AND ac.TABLE_NAME = '\(tableName)'
            ) cc ON c.COLUMN_NAME = cc.COLUMN_NAME
            WHERE c.OWNER = '\(owner)'
              AND c.TABLE_NAME = '\(tableName)'
            ORDER BY c.COLUMN_ID
            """
    }

    public static func indexes(schema: String, table: String) -> String {
        let owner = escapeLiteral(schema)
        let tableName = escapeLiteral(table)
        return """
            SELECT i.INDEX_NAME, i.UNIQUENESS, ic.COLUMN_NAME,
                   CASE WHEN c.CONSTRAINT_TYPE = 'P' THEN 'Y' ELSE 'N' END AS IS_PK
            FROM ALL_INDEXES i
            JOIN ALL_IND_COLUMNS ic ON i.INDEX_NAME = ic.INDEX_NAME AND i.OWNER = ic.INDEX_OWNER
            LEFT JOIN ALL_CONSTRAINTS c ON i.INDEX_NAME = c.INDEX_NAME AND i.OWNER = c.OWNER
                AND c.CONSTRAINT_TYPE = 'P'
            WHERE i.TABLE_NAME = '\(tableName)'
              AND i.OWNER = '\(owner)'
            ORDER BY i.INDEX_NAME, ic.COLUMN_POSITION
            """
    }

    public static func foreignKeys(schema: String, table: String) -> String {
        let owner = escapeLiteral(schema)
        let tableName = escapeLiteral(table)
        return """
            SELECT
                ac.CONSTRAINT_NAME,
                acc.COLUMN_NAME,
                rc.TABLE_NAME AS REF_TABLE,
                rcc.COLUMN_NAME AS REF_COLUMN,
                ac.DELETE_RULE,
                rc.OWNER AS REF_SCHEMA
            FROM ALL_CONSTRAINTS ac
            JOIN ALL_CONS_COLUMNS acc ON ac.CONSTRAINT_NAME = acc.CONSTRAINT_NAME
                AND ac.OWNER = acc.OWNER
            JOIN ALL_CONSTRAINTS rc ON ac.R_CONSTRAINT_NAME = rc.CONSTRAINT_NAME
                AND ac.R_OWNER = rc.OWNER
            JOIN ALL_CONS_COLUMNS rcc ON rc.CONSTRAINT_NAME = rcc.CONSTRAINT_NAME
                AND rc.OWNER = rcc.OWNER AND acc.POSITION = rcc.POSITION
            WHERE ac.CONSTRAINT_TYPE = 'R'
              AND ac.TABLE_NAME = '\(tableName)'
              AND ac.OWNER = '\(owner)'
            ORDER BY ac.CONSTRAINT_NAME, acc.POSITION
            """
    }

    public static func parseTableRow(_ row: [OracleRawCell]) -> OracleTableRow? {
        guard let name = row[safe: 0]?.stringValue else { return nil }
        return OracleTableRow(name: name, isView: row[safe: 1]?.stringValue == "VIEW")
    }

    public static func parseColumnRow(_ row: [OracleRawCell]) -> OracleColumnRow? {
        guard let name = row[safe: 0]?.stringValue else { return nil }
        return OracleColumnRow(
            name: name,
            dataType: (row[safe: 1]?.stringValue)?.lowercased() ?? "varchar2",
            dataLength: row[safe: 2]?.stringValue,
            precision: row[safe: 3]?.stringValue,
            scale: row[safe: 4]?.stringValue,
            isNullable: row[safe: 5]?.stringValue == "Y",
            isPrimaryKey: row[safe: 6]?.stringValue == "Y"
        )
    }

    public static func parseIndexRow(_ row: [OracleRawCell]) -> OracleIndexRow? {
        guard let name = row[safe: 0]?.stringValue,
              let columnName = row[safe: 2]?.stringValue else { return nil }
        return OracleIndexRow(
            name: name,
            isUnique: row[safe: 1]?.stringValue == "UNIQUE",
            columnName: columnName,
            isPrimary: row[safe: 3]?.stringValue == "Y"
        )
    }

    public static func parseForeignKeyRow(_ row: [OracleRawCell]) -> OracleForeignKeyRow? {
        guard let constraintName = row[safe: 0]?.stringValue,
              let columnName = row[safe: 1]?.stringValue,
              let referencedTable = row[safe: 2]?.stringValue,
              let referencedColumn = row[safe: 3]?.stringValue else { return nil }
        return OracleForeignKeyRow(
            constraintName: constraintName,
            columnName: columnName,
            referencedTable: referencedTable,
            referencedColumn: referencedColumn,
            referencedSchema: row[safe: 5]?.stringValue,
            deleteRule: row[safe: 4]?.stringValue ?? "NO ACTION"
        )
    }

    public static func fullType(
        dataType: String,
        dataLength: String?,
        precision: String?,
        scale: String?
    ) -> String {
        let fixedTypes: Set<String> = [
            "date", "clob", "nclob", "blob", "bfile", "long", "long raw",
            "rowid", "urowid", "binary_float", "binary_double", "xmltype"
        ]
        if fixedTypes.contains(dataType) {
            return dataType
        }
        if dataType == "number" {
            guard let precision, let precisionValue = Int(precision) else { return dataType }
            if let scale, let scaleValue = Int(scale), scaleValue > 0 {
                return "number(\(precisionValue),\(scaleValue))"
            }
            return "number(\(precisionValue))"
        }
        if let dataLength, let lengthValue = Int(dataLength), lengthValue > 0 {
            return "\(dataType)(\(lengthValue))"
        }
        return dataType
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
