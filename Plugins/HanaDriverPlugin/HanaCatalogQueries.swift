import Foundation

enum HanaCatalogQueries {
    static let schemas = "SELECT SCHEMA_NAME FROM SYS.SCHEMAS ORDER BY SCHEMA_NAME"

    static func setSchema(_ schema: String) -> String {
        "SET SCHEMA \(HanaSQL.quoteIdentifier(schema))"
    }

    static func tables(schema: String) -> String {
        let owner = HanaSQL.quoteLiteral(schema)
        return """
            SELECT TABLE_NAME, 'TABLE' AS OBJECT_TYPE, COMMENTS
            FROM SYS.TABLES
            WHERE SCHEMA_NAME = \(owner)
              AND IS_USER_DEFINED_TYPE = 'FALSE'
            UNION ALL
            SELECT VIEW_NAME, 'VIEW', COMMENTS
            FROM SYS.VIEWS
            WHERE SCHEMA_NAME = \(owner)
            ORDER BY 1
            """
    }

    static func columns(schema: String, table: String?) -> String {
        let owner = HanaSQL.quoteLiteral(schema)
        let tableFilter = table.map { "\n      AND TABLE_NAME = \(HanaSQL.quoteLiteral($0))" } ?? ""
        let viewFilter = table.map { "\n      AND VIEW_NAME = \(HanaSQL.quoteLiteral($0))" } ?? ""
        return """
            SELECT C.TABLE_NAME, C.COLUMN_NAME, C.DATA_TYPE_NAME, C.LENGTH, C.SCALE, C.IS_NULLABLE,
                   C.DEFAULT_VALUE, C.COMMENTS, C.GENERATION_TYPE, C.GENERATED_ALWAYS_AS,
                   K.POSITION AS KEY_POSITION
            FROM (
                SELECT SCHEMA_NAME, TABLE_NAME, COLUMN_NAME, POSITION, DATA_TYPE_NAME, LENGTH, SCALE,
                       IS_NULLABLE, DEFAULT_VALUE, COMMENTS, GENERATION_TYPE, GENERATED_ALWAYS_AS
                FROM SYS.TABLE_COLUMNS
                WHERE SCHEMA_NAME = \(owner)\(tableFilter)
                UNION ALL
                SELECT SCHEMA_NAME, VIEW_NAME, COLUMN_NAME, POSITION, DATA_TYPE_NAME, LENGTH, SCALE,
                       IS_NULLABLE, DEFAULT_VALUE, COMMENTS, GENERATION_TYPE, GENERATED_ALWAYS_AS
                FROM SYS.VIEW_COLUMNS
                WHERE SCHEMA_NAME = \(owner)\(viewFilter)
            ) C
            LEFT JOIN SYS.CONSTRAINTS K
              ON K.SCHEMA_NAME = C.SCHEMA_NAME
             AND K.TABLE_NAME = C.TABLE_NAME
             AND K.COLUMN_NAME = C.COLUMN_NAME
             AND K.IS_PRIMARY_KEY = 'TRUE'
            ORDER BY C.TABLE_NAME, C.POSITION
            """
    }

    static func indexes(schema: String, table: String) -> String {
        """
        SELECT I.INDEX_NAME, I.INDEX_TYPE, C.CONSTRAINT, C.COLUMN_NAME, C.ASCENDING_ORDER
        FROM SYS.INDEXES I
        JOIN SYS.INDEX_COLUMNS C
          ON C.SCHEMA_NAME = I.SCHEMA_NAME
         AND C.TABLE_NAME = I.TABLE_NAME
         AND C.INDEX_NAME = I.INDEX_NAME
        WHERE I.SCHEMA_NAME = \(HanaSQL.quoteLiteral(schema))
          AND I.TABLE_NAME = \(HanaSQL.quoteLiteral(table))
        ORDER BY I.INDEX_NAME, C.POSITION
        """
    }

    static func foreignKeys(schema: String, table: String) -> String {
        """
        SELECT CONSTRAINT_NAME, COLUMN_NAME, REFERENCED_SCHEMA_NAME, REFERENCED_TABLE_NAME,
               REFERENCED_COLUMN_NAME, UPDATE_RULE, DELETE_RULE
        FROM SYS.REFERENTIAL_CONSTRAINTS
        WHERE SCHEMA_NAME = \(HanaSQL.quoteLiteral(schema))
          AND TABLE_NAME = \(HanaSQL.quoteLiteral(table))
        ORDER BY CONSTRAINT_NAME, POSITION
        """
    }

    static func tableMetadata(schema: String, table: String) -> String {
        """
        SELECT T.TABLE_TYPE, T.COMMENTS, M.RECORD_COUNT, M.TABLE_SIZE
        FROM SYS.TABLES T
        LEFT JOIN SYS.M_TABLES M
          ON M.SCHEMA_NAME = T.SCHEMA_NAME
         AND M.TABLE_NAME = T.TABLE_NAME
        WHERE T.SCHEMA_NAME = \(HanaSQL.quoteLiteral(schema))
          AND T.TABLE_NAME = \(HanaSQL.quoteLiteral(table))
        """
    }

    static func relationComment(schema: String, name: String) -> String {
        let owner = HanaSQL.quoteLiteral(schema)
        let relation = HanaSQL.quoteLiteral(name)
        return """
            SELECT 'TABLE', COMMENTS
            FROM SYS.TABLES
            WHERE SCHEMA_NAME = \(owner)
              AND TABLE_NAME = \(relation)
            UNION ALL
            SELECT 'VIEW', COMMENTS
            FROM SYS.VIEWS
            WHERE SCHEMA_NAME = \(owner)
              AND VIEW_NAME = \(relation)
            """
    }

    static func viewComment(schema: String, view: String) -> String {
        """
        SELECT COMMENTS
        FROM SYS.VIEWS
        WHERE SCHEMA_NAME = \(HanaSQL.quoteLiteral(schema))
          AND VIEW_NAME = \(HanaSQL.quoteLiteral(view))
        """
    }

    static func approximateRowCount(schema: String, table: String) -> String {
        """
        SELECT RECORD_COUNT
        FROM SYS.M_TABLES
        WHERE SCHEMA_NAME = \(HanaSQL.quoteLiteral(schema))
          AND TABLE_NAME = \(HanaSQL.quoteLiteral(table))
        """
    }

    static func tableCount(schema: String) -> String {
        """
        SELECT COUNT(*)
        FROM SYS.TABLES
        WHERE SCHEMA_NAME = \(HanaSQL.quoteLiteral(schema))
          AND IS_USER_DEFINED_TYPE = 'FALSE'
        """
    }

    static func tableStore(schema: String, table: String) -> String {
        """
        SELECT IS_COLUMN_TABLE
        FROM SYS.TABLES
        WHERE SCHEMA_NAME = \(HanaSQL.quoteLiteral(schema))
          AND TABLE_NAME = \(HanaSQL.quoteLiteral(table))
        """
    }

    static func viewDefinition(schema: String, view: String) -> String {
        """
        SELECT DEFINITION
        FROM SYS.VIEWS
        WHERE SCHEMA_NAME = \(HanaSQL.quoteLiteral(schema))
          AND VIEW_NAME = \(HanaSQL.quoteLiteral(view))
        """
    }
}
