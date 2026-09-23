import Foundation
import os
import TableProDatabase
import TableProModels
import TableProPluginKit

nonisolated extension PostgreSQLDriver {
    func fetchTables(schema: String?) async throws -> [TableInfo] {
        let query = Self.tablesQuery(
            schema: schema ?? effectiveSchema,
            databaseType: databaseType,
            presence: catalogPresence
        )
        let result = try await execute(query: query)
        return Self.tables(fromRows: result.rows, databaseType: databaseType)
    }

    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] {
        let schemaName = schema ?? effectiveSchema
        let materializedViewsPresent = catalogPresence.hasMaterializedViews
        let attempts = columnReadSupport.attempts(materializedViewsPresent: materializedViewsPresent)
        for shape in attempts.dropLast() {
            try Task.checkCancellation()
            do {
                return try await readColumns(table: table, schema: schemaName, shape: shape)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Self.logger.debug(
                    "Column read failed with identity=\(shape.includesIdentityColumns, privacy: .public) matviews=\(shape.includesMaterializedViews, privacy: .public): \(error.localizedDescription, privacy: .private)"
                )
            }
        }
        guard let leastCapable = attempts.last else { return [] }
        try Task.checkCancellation()
        return try await readColumns(table: table, schema: schemaName, shape: leastCapable)
    }

    private func readColumns(table: String, schema: String, shape: PostgreSQLColumnReadShape) async throws -> [ColumnInfo] {
        let result = try await execute(query: Self.columnsQuery(schema: schema, table: table, shape: shape))
        columnReadSupport = columnReadSupport.learning(
            from: shape,
            materializedViewsPresent: catalogPresence.hasMaterializedViews
        )
        return Self.columns(fromRows: result.rows)
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo] {
        let query = Self.indexesQuery(
            schema: schema ?? effectiveSchema,
            table: table,
            databaseType: databaseType,
            serverVersionNumber: serverVersionNumber
        )
        let result = try await execute(query: query)
        return Self.indexes(fromRows: result.rows, databaseType: databaseType)
    }

    static func presence(probedRows rows: [[String?]]?) -> PostgreSQLCatalogPresence {
        PostgreSQLCatalogPresence(relationNames: rows?.compactMap { $0.first ?? nil } ?? [])
    }

    static func tablesQuery(schema: String, databaseType: DatabaseType, presence: PostgreSQLCatalogPresence) -> String {
        guard databaseType != .redshift else {
            return RedshiftTableCatalog.listingQuery(schema: schema)
        }
        return PostgreSQLTableListing.query(
            schema: schema,
            includeMaterializedViews: presence.hasMaterializedViews,
            includeForeignTables: presence.hasForeignTables,
            includeComments: false,
            includePartitionAwareness: false
        )
    }

    static func tables(fromRows rows: [[String?]], databaseType: DatabaseType) -> [TableInfo] {
        rows.compactMap { row in
            let listed = databaseType == .redshift
                ? RedshiftTableCatalog.table(fromListingRow: row)
                : PostgreSQLTableListing.table(fromRow: row)
            return listed.map { TableInfo(from: $0) }
        }
    }

    static func columnsQuery(schema: String, table: String, shape: PostgreSQLColumnReadShape) -> String {
        let schemaLiteral = PostgreSQLObjectQueries.quoteLiteral(schema)
        let tableLiteral = PostgreSQLObjectQueries.quoteLiteral(table)
        let identityColumns = shape.includesIdentityColumns ? ["is_identity", "is_generated"] : []
        let identityProjection = identityColumns.map { ",\n    c.\($0) AS \($0)" }.joined()
        var arms = [
            """
            SELECT
                c.column_name AS column_name,
                c.data_type AS data_type,
                c.is_nullable AS is_nullable,
                c.column_default AS column_default,
                c.character_maximum_length AS character_maximum_length,
                CASE WHEN pk.column_name IS NOT NULL THEN 'YES' ELSE 'NO' END AS is_pk\(identityProjection),
                c.ordinal_position AS ordinal_position
            FROM information_schema.columns c
            LEFT JOIN (
                SELECT kcu.column_name
                FROM information_schema.table_constraints tc
                JOIN information_schema.key_column_usage kcu
                    ON tc.constraint_name = kcu.constraint_name
                    AND tc.table_schema = kcu.table_schema
                WHERE tc.constraint_type = 'PRIMARY KEY'
                    AND tc.table_schema = \(schemaLiteral)
                    AND tc.table_name = \(tableLiteral)
            ) pk ON c.column_name = pk.column_name
            WHERE c.table_schema = \(schemaLiteral) AND c.table_name = \(tableLiteral)
            """
        ]
        if shape.includesMaterializedViews {
            arms.append(materializedViewColumnsArm(schemaLiteral: schemaLiteral, table: table, shape: shape))
        }
        let outerColumns = [
            "column_name", "data_type", "is_nullable", "column_default", "character_maximum_length", "is_pk"
        ] + identityColumns
        return """
            SELECT
                \(outerColumns.map { "cols.\($0)" }.joined(separator: ",\n    "))
            FROM (
            \(arms.joined(separator: "\nUNION ALL\n"))
            ) cols
            ORDER BY cols.ordinal_position
            """
    }

    private static func materializedViewColumnsArm(
        schemaLiteral: String,
        table: String,
        shape: PostgreSQLColumnReadShape
    ) -> String {
        let source = PostgreSQLMaterializedViewColumnSource.self
        let identityProjection = shape.includesIdentityColumns
            ? ",\n    'NO' AS is_identity,\n    'NEVER' AS is_generated"
            : ""
        return """
            SELECT
                \(source.columnName) AS column_name,
                \(source.dataType) AS data_type,
                \(source.isNullable) AS is_nullable,
                NULL::text AS column_default,
                \(source.characterMaximumLength) AS character_maximum_length,
                'NO' AS is_pk\(identityProjection),
                \(source.ordinalPosition) AS ordinal_position
            \(source.relation(schemaLiteral: schemaLiteral, table: table))
            """
    }

    static func columns(fromRows rows: [[String?]]) -> [ColumnInfo] {
        rows.enumerated().compactMap { index, row in
            guard row.count >= 6, let name = row[0], let dataType = row[1] else { return nil }
            return ColumnInfo(
                name: name,
                typeName: dataType,
                isPrimaryKey: row[5] == "YES",
                isNullable: row[2]?.uppercased() == "YES",
                defaultValue: row[3],
                comment: nil,
                characterMaxLength: row[4].flatMap { Int($0) },
                ordinalPosition: index,
                isAutoIncrement: ColumnMetadataRules.postgresIsAutoIncrement(
                    isIdentity: row.count > 6 ? row[6] : nil, columnDefault: row[3]
                ),
                isGenerated: ColumnMetadataRules.postgresIsGenerated(
                    isGenerated: row.count > 7 ? row[7] : nil
                )
            )
        }
    }

    static func indexesQuery(
        schema: String,
        table: String,
        databaseType: DatabaseType,
        serverVersionNumber: Int32
    ) -> String {
        guard databaseType != .redshift else {
            return RedshiftTableCatalog.keysQuery(schema: schema, table: table)
        }
        return PostgreSQLIndexQueries.indexList(
            schema: schema,
            table: table,
            capabilities: .assumingModernWhenUnknown(serverVersionNumber)
        )
    }

    static func indexes(fromRows rows: [[String?]], databaseType: DatabaseType) -> [IndexInfo] {
        guard databaseType != .redshift else {
            return RedshiftTableCatalog.keys(fromRows: rows).map { IndexInfo(from: $0) }
        }
        return rows.compactMap { row in
            PostgreSQLIndexRow.index(from: row.map(PluginCellValue.fromOptional), ddl: [:])
                .map { IndexInfo(from: $0.index) }
        }
    }
}
