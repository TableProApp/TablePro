import Foundation

nonisolated enum PostgreSQLMaterializedViewColumnSource {
    static let columnName = "mva.attname"

    static let ordinalPosition = "mva.attnum"

    static let dataType = """
        CASE WHEN mvt.typtype = 'd'
                 THEN CASE WHEN mvbt.typelem <> 0 AND mvbt.typlen = -1 THEN 'ARRAY'
                           WHEN mvbtn.nspname = 'pg_catalog' THEN pg_catalog.format_type(mvt.typbasetype, NULL)
                           ELSE 'USER-DEFINED' END
                 ELSE CASE WHEN mvt.typelem <> 0 AND mvt.typlen = -1 THEN 'ARRAY'
                           WHEN mvtn.nspname = 'pg_catalog' THEN pg_catalog.format_type(mva.atttypid, NULL)
                           ELSE 'USER-DEFINED' END
            END
        """

    static let isNullable = "CASE WHEN mva.attnotnull OR (mvt.typtype = 'd' AND mvt.typnotnull) THEN 'NO' ELSE 'YES' END"

    static let characterMaximumLength = """
        information_schema._pg_char_max_length(\
        information_schema._pg_truetypid(mva.*, mvt.*), \
        information_schema._pg_truetypmod(mva.*, mvt.*))
        """

    static func relation(schemaLiteral: String, table: String?) -> String {
        let tableFilter = table.map { "\n  AND mvc.relname = \(PostgreSQLObjectQueries.quoteLiteral($0))" } ?? ""
        return """
            FROM pg_catalog.pg_class mvc
            JOIN pg_catalog.pg_namespace mvn ON mvn.oid = mvc.relnamespace
            JOIN pg_catalog.pg_attribute mva
                ON mva.attrelid = mvc.oid
                AND mva.attnum > 0
                AND NOT mva.attisdropped
            JOIN pg_catalog.pg_type mvt ON mvt.oid = mva.atttypid
            JOIN pg_catalog.pg_namespace mvtn ON mvtn.oid = mvt.typnamespace
            LEFT JOIN pg_catalog.pg_type mvbt
                ON mvt.typtype = 'd'
                AND mvbt.oid = mvt.typbasetype
            LEFT JOIN pg_catalog.pg_namespace mvbtn ON mvbtn.oid = mvbt.typnamespace
            LEFT JOIN pg_catalog.pg_collation mvco ON mvco.oid = mva.attcollation
            LEFT JOIN pg_catalog.pg_namespace mvcon ON mvcon.oid = mvco.collnamespace
            WHERE mvc.relkind = 'm'
              AND mvn.nspname = \(schemaLiteral)\(tableFilter)
              AND NOT pg_catalog.pg_is_other_temp_schema(mvn.oid)
              AND (pg_catalog.pg_has_role(mvc.relowner, 'USAGE')
                   OR pg_catalog.has_column_privilege(mvc.oid, mva.attnum, 'SELECT, INSERT, UPDATE, REFERENCES'))
            """
    }
}
