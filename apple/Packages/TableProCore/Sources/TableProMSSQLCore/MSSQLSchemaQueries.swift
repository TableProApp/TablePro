import Foundation
import TableProSQLQuoting

public enum MSSQLTableListingScope: Sendable, Equatable {
    case schema(String)
    case schemas([String])
    case allSchemas
}

public enum MSSQLSchemaQueries {
    public static func escape(_ value: String) -> String {
        MSSQLStringLiteral.escaped(value)
    }

    public static func escapeBracket(_ value: String) -> String {
        var scalars = SQLQuoting.identifier(value, quote: .bracket).unicodeScalars
        scalars.removeFirst()
        scalars.removeLast()
        return String(scalars)
    }

    public static func bracketed(schema: String, table: String) -> String {
        SQLQuoting.identifier(schema, quote: .bracket) + "." + SQLQuoting.identifier(table, quote: .bracket)
    }

    // Both views are scoped to a database. `size` counts 8 KB pages and with ANSI_WARNINGS off an int overflow reads NULL.
    public static func databaseMetadata(database: String) -> String {
        let qualified = SQLQuoting.identifier(database, quote: .bracket)
        return """
            SELECT
                (SELECT SUM(CAST(size AS bigint)) * 8192 FROM \(qualified).sys.database_files) AS size_bytes,
                (SELECT COUNT(*) FROM \(qualified).sys.tables) AS table_count
            """
    }

    /// Every database's file size from the server-wide view, for a database whose own catalog cannot be read
    /// because it is offline or the login has no access to it.
    public static let allDatabaseSizes = """
        SELECT d.name, SUM(CAST(mf.size AS bigint)) * 8192 AS size_bytes
        FROM sys.databases d
        LEFT JOIN sys.master_files mf ON d.database_id = mf.database_id
        GROUP BY d.name
        """

    // Rows are `name, type_desc, is_unique, filter_definition, column_name, is_included_column, is_descending_key`.
    public static func indexStatements(
        rows: [[String?]],
        schema: String,
        table: String
    ) throws -> [String] {
        var order: [String] = []
        var keys: [String: [String]] = [:]
        var included: [String: [String]] = [:]
        var kind: [String: String] = [:]
        var unique: [String: Bool] = [:]
        var filter: [String: String] = [:]

        for row in rows {
            guard let name = row[safe: 0] ?? nil, let column = row[safe: 4] ?? nil else { continue }
            if keys[name] == nil, included[name] == nil {
                order.append(name)
                keys[name] = []
                included[name] = []
                kind[name] = MSSQLDefinitionText.indexKind(row[safe: 1] ?? nil) ?? "NONCLUSTERED"
                unique[name] = (row[safe: 2] ?? nil) == "1"
                if let predicate = row[safe: 3] ?? nil, !predicate.isEmpty {
                    filter[name] = predicate
                }
            }
            let quoted = SQLQuoting.identifier(column, quote: .bracket)
            if (row[safe: 5] ?? nil) == "1" {
                included[name]?.append(quoted)
            } else {
                let descending = (row[safe: 6] ?? nil) == "1"
                keys[name]?.append(descending ? "\(quoted) DESC" : quoted)
            }
        }

        return try order.compactMap { name -> String? in
            guard let keyColumns = keys[name], !keyColumns.isEmpty else { return nil }
            var statement = "CREATE "
            if unique[name] == true { statement += "UNIQUE " }
            statement += "\(kind[name] ?? "NONCLUSTERED") INDEX \(SQLQuoting.identifier(name, quote: .bracket))"
            statement += " ON \(bracketed(schema: schema, table: table))"
            statement += " (\(keyColumns.joined(separator: ", ")))"
            if let includedColumns = included[name], !includedColumns.isEmpty {
                statement += " INCLUDE (\(includedColumns.joined(separator: ", ")))"
            }
            if let predicate = filter[name] {
                guard let expression = MSSQLDefinitionText.expression(predicate) else {
                    throw MSSQLDefinitionRefusal.indexFilter(name)
                }
                statement += " WHERE \(expression)"
            }
            return statement + ";"
        }
    }

    // A column keeps COLLATE only where it differs from `databaseCollation`; nil writes every column's.
    public static func createTableStatement(
        schema: String,
        table: String,
        columns: [MSSQLColumnRow],
        keyConstraints: [MSSQLKeyConstraintRow] = [],
        checkConstraints: [MSSQLCheckConstraintRow] = [],
        foreignKeys: [MSSQLForeignKeyRow] = [],
        databaseCollation: String?
    ) throws -> String {
        var parts = try columns.map { try columnDefinition($0, databaseCollation: databaseCollation) }
        parts += keyConstraintDefinitions(keyConstraints)
        parts += try foreignKeyDefinitions(foreignKeys, schema: schema)
        parts += try checkConstraintDefinitions(checkConstraints, table: table)
        let body = parts.map { "    " + $0 }.joined(separator: ",\n")
        let created = "CREATE TABLE \(bracketed(schema: schema, table: table)) (\n\(body)\n);"
        // CREATE TABLE has no way to declare a check disabled or untrusted, and rows the source let past one would
        // fail the restore, so it is switched off before any row goes in.
        let unchecked = checkConstraints.filter { $0.definition != nil && ($0.isDisabled || $0.isNotTrusted) }
            .map { "ALTER TABLE \(bracketed(schema: schema, table: table)) NOCHECK CONSTRAINT \(SQLQuoting.identifier($0.name, quote: .bracket));" }
        return ([created] + unchecked).joined(separator: "\n")
    }

    // After the rows: a check the source enforced without having checked its rows is turned back on the same way.
    public static func checkConstraintReenableStatements(
        schema: String,
        table: String,
        checkConstraints: [MSSQLCheckConstraintRow]
    ) -> [String] {
        checkConstraints.filter { $0.definition != nil && $0.isNotTrusted && !$0.isDisabled }.map {
            "ALTER TABLE \(bracketed(schema: schema, table: table)) WITH NOCHECK CHECK CONSTRAINT "
                + "\(SQLQuoting.identifier($0.name, quote: .bracket));"
        }
    }

    private static func columnDefinition(_ column: MSSQLColumnRow, databaseCollation: String?) throws -> String {
        let name = SQLQuoting.identifier(column.name, quote: .bracket)
        if column.isComputed {
            guard let expression = column.computedDefinition.flatMap(MSSQLDefinitionText.expression) else {
                throw MSSQLDefinitionRefusal.computedColumn(column.name)
            }
            // NOT NULL is allowed on a computed column only with PERSISTED.
            guard column.isPersisted else { return "\(name) AS \(expression)" }
            return "\(name) AS \(expression) PERSISTED" + (column.isNullable ? "" : " NOT NULL")
        }
        let type = column.displayType.uppercased()
        guard MSSQLDefinitionText.isColumnType(type) else {
            throw MSSQLDefinitionRefusal.columnType(column.name, type)
        }
        var definition = "\(name) \(type)"
        if let collation = column.collation, collation != databaseCollation {
            guard MSSQLDefinitionText.isCollationName(collation) else {
                throw MSSQLDefinitionRefusal.collation(column.name, collation)
            }
            definition += " COLLATE \(collation)"
        }
        if column.isIdentity {
            let identity = "\(column.identitySeed ?? ""),\(column.identityIncrement ?? "")"
            guard MSSQLDefinitionText.isIdentitySpecification(identity) else {
                throw MSSQLDefinitionRefusal.identity(column.name, identity)
            }
            definition += " IDENTITY(\(identity))"
        }
        definition += column.isNullable ? " NULL" : " NOT NULL"
        if let value = column.defaultValue {
            guard let expression = MSSQLDefinitionText.expression(value) else {
                throw MSSQLDefinitionRefusal.columnDefault(column.name)
            }
            definition += " DEFAULT \(expression)"
        }
        return definition
    }

    private static func keyConstraintDefinitions(_ rows: [MSSQLKeyConstraintRow]) -> [String] {
        let constraints = grouped(rows, by: { $0.name })
        let primaryFirst = constraints.filter { $0.first?.isPrimaryKey == true }
            + constraints.filter { $0.first?.isPrimaryKey != true }
        return primaryFirst.compactMap { keyRows -> String? in
            guard let first = keyRows.first else { return nil }
            var definition = "CONSTRAINT \(SQLQuoting.identifier(first.name, quote: .bracket))"
            definition += first.isPrimaryKey ? " PRIMARY KEY" : " UNIQUE"
            if let kind = MSSQLDefinitionText.indexKind(first.indexKind) {
                definition += " \(kind)"
            }
            let keys = keyRows.map { key in
                SQLQuoting.identifier(key.columnName, quote: .bracket) + (key.isDescending ? " DESC" : "")
            }
            return definition + " (\(keys.joined(separator: ", ")))"
        }
    }

    // A referenced table without a schema resolves against the login's default schema, so it is always qualified.
    private static func foreignKeyDefinitions(_ rows: [MSSQLForeignKeyRow], schema: String) throws -> [String] {
        try grouped(rows, by: { $0.constraintName }).compactMap { keyRows -> String? in
            guard let first = keyRows.first else { return nil }
            guard let onDelete = MSSQLDefinitionText.referentialAction(first.onDelete) else {
                throw MSSQLDefinitionRefusal.foreignKeyAction(first.constraintName, first.onDelete)
            }
            guard let onUpdate = MSSQLDefinitionText.referentialAction(first.onUpdate) else {
                throw MSSQLDefinitionRefusal.foreignKeyAction(first.constraintName, first.onUpdate)
            }
            let columns = keyRows.map { SQLQuoting.identifier($0.columnName, quote: .bracket) }
            let referencedColumns = keyRows.map { SQLQuoting.identifier($0.referencedColumn, quote: .bracket) }
            let referencedSchema = first.referencedSchema.flatMap { $0.isEmpty ? nil : $0 } ?? schema
            var definition: String = "CONSTRAINT \(SQLQuoting.identifier(first.constraintName, quote: .bracket))"
                + " FOREIGN KEY (\(columns.joined(separator: ", ")))"
                + " REFERENCES \(bracketed(schema: referencedSchema, table: first.referencedTable))"
                + " (\(referencedColumns.joined(separator: ", ")))"
            if onDelete != "NO ACTION" { definition += " ON DELETE \(onDelete)" }
            if onUpdate != "NO ACTION" { definition += " ON UPDATE \(onUpdate)" }
            return definition
        }
    }

    // An unreadable definition is left out, as an unreadable default is.
    private static func checkConstraintDefinitions(_ rows: [MSSQLCheckConstraintRow], table: String) throws -> [String] {
        try rows.compactMap { row -> String? in
            guard let definition = row.definition else { return nil }
            guard let expression = MSSQLDefinitionText.expression(definition) else {
                throw MSSQLDefinitionRefusal.checkConstraint(table)
            }
            return "CONSTRAINT \(SQLQuoting.identifier(row.name, quote: .bracket)) CHECK \(expression)"
        }
    }

    private static func grouped<Row>(_ rows: [Row], by key: (Row) -> String) -> [[Row]] {
        var order: [String] = []
        var groups: [String: [Row]] = [:]
        for row in rows {
            let name = key(row)
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(row)
        }
        return order.compactMap { groups[$0] }
    }

    // SQL Server gives a column altered without COLLATE the database default, so a character column restates the
    // collation the new definition carries, or else the one it had.
    public static func alterColumnCollation(type: String, collation: String?, previous: String?) -> String? {
        guard MSSQLDefinitionText.isCharacterType(type) else { return nil }
        return collation.flatMap(nonEmpty) ?? previous.flatMap(nonEmpty)
    }

    public static func alterColumnStatement(
        qualifiedTable: String,
        column: String,
        type: String,
        collation: String?,
        isNullable: Bool
    ) throws -> String {
        guard MSSQLDefinitionText.isColumnType(type) else {
            throw MSSQLDefinitionRefusal.columnType(column, type)
        }
        var statement = "ALTER TABLE \(qualifiedTable) ALTER COLUMN \(SQLQuoting.identifier(column, quote: .bracket)) \(type)"
        if let collation {
            guard MSSQLDefinitionText.isCollationName(collation) else {
                throw MSSQLDefinitionRefusal.collation(column, collation)
            }
            statement += " COLLATE \(collation)"
        }
        return statement + (isNullable ? " NULL" : " NOT NULL")
    }

    private static func nonEmpty(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }

    public static func qualifiedName(schema: String?, table: String) -> String {
        guard let schema, !schema.isEmpty else {
            return SQLQuoting.identifier(table, quote: .bracket)
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

    /// Unordered, because SQL Server rejects an `ORDER BY` in a subquery and the all-schema table
    /// listing filters by this query.
    internal static let listedSchemaNames = """
        SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA
        WHERE SCHEMA_NAME NOT IN (
            'information_schema','sys','db_owner','db_accessadmin',
            'db_securityadmin','db_ddladmin','db_backupoperator',
            'db_datareader','db_datawriter','db_denydatareader',
            'db_denydatawriter','guest'
        )
        """

    public static let schemas = listedSchemaNames + "\nORDER BY SCHEMA_NAME"

    public static func tables(schema: String) -> String {
        tables(in: .schema(schema))
    }

    /// The same listing over one schema, a named set of them, or every schema `schemas` returns. The
    /// last filters by that query itself rather than dropping the schema predicate, so a table is
    /// listed here exactly when its schema is listed there. Both multi-schema listings project each
    /// row's schema as a third column.
    public static func tables(in scope: MSSQLTableListingScope) -> String {
        let schemaFilter: String
        let schemaColumn: String
        let orderBy: String
        switch scope {
        case .schema(let schema):
            schemaFilter = "t.TABLE_SCHEMA = \(MSSQLStringLiteral.quoted(schema))"
            schemaColumn = ""
            orderBy = "t.TABLE_NAME"
        case .schemas(let schemas):
            schemaFilter = schemas.isEmpty
                ? "1 = 0"
                : "t.TABLE_SCHEMA IN (\(schemas.map(MSSQLStringLiteral.quoted).joined(separator: ", ")))"
            schemaColumn = ", t.TABLE_SCHEMA"
            orderBy = "t.TABLE_SCHEMA, t.TABLE_NAME"
        case .allSchemas:
            schemaFilter = "t.TABLE_SCHEMA IN (\n\(listedSchemaNames)\n)"
            schemaColumn = ", t.TABLE_SCHEMA"
            orderBy = "t.TABLE_SCHEMA, t.TABLE_NAME"
        }
        return """
            SELECT t.TABLE_NAME, t.TABLE_TYPE\(schemaColumn)
            FROM INFORMATION_SCHEMA.TABLES t
            WHERE \(schemaFilter)
              AND t.TABLE_TYPE IN ('BASE TABLE', 'VIEW')
            ORDER BY \(orderBy)
            """
    }

    // One column per row, in the order `parseColumnRow` reads.
    public static func columns(schema: String, table: String) -> String {
        let s = MSSQLStringLiteral.quoted(schema)
        let t = MSSQLStringLiteral.quoted(table)
        return """
            SELECT
            \(columnSelectList)
            FROM INFORMATION_SCHEMA.COLUMNS c
            \(columnCatalogJoin)
            LEFT JOIN (
                SELECT kcu.COLUMN_NAME
                FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
                JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu
                    ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
                    AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA
                WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
                    AND tc.TABLE_SCHEMA = \(s)
                    AND tc.TABLE_NAME = \(t)
            ) pk ON c.COLUMN_NAME = pk.COLUMN_NAME
            WHERE c.TABLE_NAME = \(t)
              AND c.TABLE_SCHEMA = \(s)
            ORDER BY c.ORDINAL_POSITION
            """
    }

    // Each row carries its table name after the columns `parseColumnRow` reads, at `allColumnsTableNameIndex`.
    public static func allColumns(schema: String) -> String {
        let s = MSSQLStringLiteral.quoted(schema)
        return """
            SELECT
            \(columnSelectList),
                c.TABLE_NAME
            FROM INFORMATION_SCHEMA.COLUMNS c
            \(columnCatalogJoin)
            LEFT JOIN (
                SELECT kcu.TABLE_NAME, kcu.COLUMN_NAME
                FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
                JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu
                    ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
                    AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA
                WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
                    AND tc.TABLE_SCHEMA = \(s)
            ) pk ON c.TABLE_NAME = pk.TABLE_NAME AND c.COLUMN_NAME = pk.COLUMN_NAME
            WHERE c.TABLE_SCHEMA = \(s)
            ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION
            """
    }

    public static let allColumnsTableNameIndex = 16

    // A `rowversion` column reports its type as `timestamp`, and a system-versioned period or ledger column reports a
    // `GeneratedAlwaysType` above zero. Neither is identity or computed, and the server refuses a written value for
    // both. Before SQL Server 2016 the property does not exist and reads NULL, which is not above zero.
    // `sys.identity_columns` keeps seed and increment as `sql_variant`, read here as text.
    private static let columnSelectList = """
                c.COLUMN_NAME,
                c.DATA_TYPE,
                c.CHARACTER_MAXIMUM_LENGTH,
                c.NUMERIC_PRECISION,
                c.NUMERIC_SCALE,
                c.IS_NULLABLE,
                dc.definition AS COLUMN_DEFAULT,
                COLUMNPROPERTY(\(columnObjectID), c.COLUMN_NAME, 'IsIdentity') AS IS_IDENTITY,
                CASE WHEN pk.COLUMN_NAME IS NOT NULL THEN 1 ELSE 0 END AS IS_PK,
                COLUMNPROPERTY(\(columnObjectID), c.COLUMN_NAME, 'IsComputed') AS IS_COMPUTED,
                CASE
                    WHEN c.DATA_TYPE = 'timestamp' THEN 1
                    WHEN COLUMNPROPERTY(\(columnObjectID), c.COLUMN_NAME, 'GeneratedAlwaysType') > 0 THEN 1
                    ELSE 0
                END AS IS_SERVER_GENERATED,
        \(columnDefinitionSelectList)
        """

    // The parts a CREATE TABLE restates, after the flags every reader takes, read the same way for a `#name` table.
    private static let columnDefinitionSelectList = """
                c.COLLATION_NAME,
                cc.definition AS COMPUTED_DEFINITION,
                cc.is_persisted AS IS_PERSISTED,
                CONVERT(varchar(40), idc.seed_value) AS IDENTITY_SEED,
                CONVERT(varchar(40), idc.increment_value) AS IDENTITY_INCREMENT
        """

    private static let columnObjectID = "OBJECT_ID(QUOTENAME(c.TABLE_SCHEMA) + '.' + QUOTENAME(c.TABLE_NAME))"

    // `INFORMATION_SCHEMA.COLUMNS.COLUMN_DEFAULT` stops at 4,000 characters, which can leave a literal open.
    private static let columnCatalogJoin = """
        LEFT JOIN sys.columns sc ON sc.object_id = \(columnObjectID) AND sc.name = c.COLUMN_NAME
        LEFT JOIN sys.default_constraints dc ON dc.object_id = sc.default_object_id
        LEFT JOIN sys.computed_columns cc ON cc.object_id = sc.object_id AND cc.column_id = sc.column_id
        LEFT JOIN sys.identity_columns idc ON idc.object_id = sc.object_id AND idc.column_id = sc.column_id
        """

    // A `#name` table lives in `tempdb` whatever database the session is on.
    public static func namesTemporaryTable(_ table: String) -> Bool {
        table.hasPrefix("#")
    }

    // `OBJECT_ID` reaches only the calling session's own `#name`, never another session's table of that name.
    public static func temporaryObjectID(_ table: String) -> String {
        "OBJECT_ID(N'tempdb..' + QUOTENAME(\(MSSQLStringLiteral.quoted(table))))"
    }

    // `tempdb.sys.tables` lists every session's tables, each padded with underscores to 116 characters before a
    // 12-digit suffix (measured on SQL Server 2022), so the name is the prefix `OBJECT_ID` resolves back to the row.
    // Trailing underscores of the name itself are lost to the padding, so up to three are tried: every candidate is
    // tried against every session's tables, and trying all 116 took 1.4 s with 300 temporary tables on the server.
    public static let temporaryTables = """
        SELECT LEFT(t.name, n.length) AS name
        FROM tempdb.sys.tables AS t
        CROSS APPLY (
            SELECT TOP (1) c.length
            FROM (VALUES (0), (1), (2), (3)) AS extra(underscores)
            CROSS APPLY (
                SELECT LEN(REPLACE(LEFT(t.name, LEN(t.name) - 12), N'_', N' ')) + extra.underscores AS length
            ) AS c
            WHERE OBJECT_ID(N'tempdb..' + QUOTENAME(LEFT(t.name, c.length))) = t.object_id
            ORDER BY c.length
        ) AS n
        WHERE t.name LIKE N'#[^#]%' AND LEN(t.name) = 128
        ORDER BY name
        """

    // `COLUMNPROPERTY` resolves an object id in the current database and answers NULL for a `tempdb` table, so the
    // flags come from `tempdb.sys.columns`.
    public static func temporaryColumns(table: String) -> String {
        let object = temporaryObjectID(table)
        return """
            SELECT
                c.COLUMN_NAME,
                c.DATA_TYPE,
                c.CHARACTER_MAXIMUM_LENGTH,
                c.NUMERIC_PRECISION,
                c.NUMERIC_SCALE,
                c.IS_NULLABLE,
                dc.definition AS COLUMN_DEFAULT,
                CAST(sc.is_identity AS int) AS IS_IDENTITY,
                CASE WHEN EXISTS (
                    SELECT 1
                    FROM tempdb.sys.indexes i
                    JOIN tempdb.sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
                    WHERE i.object_id = sc.object_id AND i.is_primary_key = 1 AND ic.column_id = sc.column_id
                ) THEN 1 ELSE 0 END AS IS_PK,
                CAST(sc.is_computed AS int) AS IS_COMPUTED,
                CASE
                    WHEN c.DATA_TYPE = 'timestamp' THEN 1
                    WHEN sc.generated_always_type > 0 THEN 1
                    ELSE 0
                END AS IS_SERVER_GENERATED,
            \(columnDefinitionSelectList)
            FROM tempdb.INFORMATION_SCHEMA.COLUMNS c
            JOIN tempdb.sys.columns sc ON sc.object_id = \(object) AND sc.name = c.COLUMN_NAME
            LEFT JOIN tempdb.sys.default_constraints dc ON dc.object_id = sc.default_object_id
            LEFT JOIN tempdb.sys.computed_columns cc ON cc.object_id = sc.object_id AND cc.column_id = sc.column_id
            LEFT JOIN tempdb.sys.identity_columns idc ON idc.object_id = sc.object_id AND idc.column_id = sc.column_id
            WHERE c.TABLE_NAME = OBJECT_NAME(\(object), DB_ID(N'tempdb'))
            ORDER BY c.ORDINAL_POSITION
            """
    }

    public static func temporaryIndexes(table: String) -> String {
        """
        SELECT i.name, i.is_unique, i.is_primary_key, c.name AS column_name, i.type_desc
        FROM tempdb.sys.indexes i
        JOIN tempdb.sys.index_columns ic
            ON i.object_id = ic.object_id AND i.index_id = ic.index_id
        JOIN tempdb.sys.columns c
            ON ic.object_id = c.object_id AND ic.column_id = c.column_id
        WHERE i.object_id = \(temporaryObjectID(table))
          AND i.name IS NOT NULL
        ORDER BY i.index_id, ic.key_ordinal
        """
    }

    public static func indexes(schema: String, table: String) -> String {
        let object = MSSQLStringLiteral.quoted(bracketed(schema: schema, table: table))
        return """
            SELECT i.name, i.is_unique, i.is_primary_key, c.name AS column_name
            FROM sys.indexes i
            JOIN sys.index_columns ic
                ON i.object_id = ic.object_id AND i.index_id = ic.index_id
            JOIN sys.columns c
                ON ic.object_id = c.object_id AND ic.column_id = c.column_id
            WHERE i.object_id = OBJECT_ID(\(object))
              AND i.name IS NOT NULL
            ORDER BY i.index_id, ic.key_ordinal
            """
    }

    // Rows are what `indexStatements` reads. A primary key's or UNIQUE constraint's index is left out:
    // `createTableStatement` declares the constraint, which builds it.
    public static func indexDefinitions(schema: String, table: String) -> String {
        let object = MSSQLStringLiteral.quoted(bracketed(schema: schema, table: table))
        return """
            SELECT i.name, i.type_desc, i.is_unique, i.filter_definition,
                   c.name AS column_name, ic.is_included_column, ic.is_descending_key
            FROM sys.indexes i
            JOIN sys.index_columns ic
                ON i.object_id = ic.object_id AND i.index_id = ic.index_id
            JOIN sys.columns c
                ON ic.object_id = c.object_id AND ic.column_id = c.column_id
            WHERE i.object_id = OBJECT_ID(\(object))
              AND i.name IS NOT NULL
              AND i.is_primary_key = 0
              AND i.is_unique_constraint = 0
              AND i.type IN (1, 2)
            ORDER BY i.index_id, ic.is_included_column, ic.key_ordinal
            """
    }

    // Rows are `name, type, type_desc, column_name, is_descending_key`, one per key column in key order.
    public static func keyConstraints(schema: String, table: String) -> String {
        let (catalog, object) = catalogObject(schema: schema, table: table)
        return """
            SELECT kc.name, kc.type, i.type_desc, c.name AS column_name, ic.is_descending_key
            FROM \(catalog)sys.key_constraints kc
            JOIN \(catalog)sys.indexes i
                ON i.object_id = kc.parent_object_id AND i.index_id = kc.unique_index_id
            JOIN \(catalog)sys.index_columns ic
                ON ic.object_id = i.object_id AND ic.index_id = i.index_id
            JOIN \(catalog)sys.columns c
                ON c.object_id = ic.object_id AND c.column_id = ic.column_id
            WHERE kc.parent_object_id = \(object)
              AND ic.key_ordinal > 0
            ORDER BY CASE kc.type WHEN 'PK' THEN 0 ELSE 1 END, kc.name, ic.key_ordinal
            """
    }

    // Rows are `name, definition, is_disabled, is_not_trusted`.
    public static func checkConstraints(schema: String, table: String) -> String {
        let (catalog, object) = catalogObject(schema: schema, table: table)
        return """
            SELECT cc.name, cc.definition, cc.is_disabled, cc.is_not_trusted
            FROM \(catalog)sys.check_constraints cc
            WHERE cc.parent_object_id = \(object)
            ORDER BY cc.name
            """
    }

    // A `#name` table's columns take tempdb's default, not the current database's.
    public static func databaseCollation(forTable table: String) -> String {
        let database = namesTemporaryTable(table) ? "N'tempdb'" : "DB_NAME()"
        return "SELECT CONVERT(nvarchar(128), DATABASEPROPERTYEX(\(database), 'Collation'))"
    }

    private static func catalogObject(schema: String, table: String) -> (catalog: String, object: String) {
        if namesTemporaryTable(table) {
            return ("tempdb.", temporaryObjectID(table))
        }
        return ("", "OBJECT_ID(\(MSSQLStringLiteral.quoted(bracketed(schema: schema, table: table))))")
    }

    // One statement for a table's keys and a schema's, so the two reads cannot drift apart.
    public static func foreignKeys(schema: String, table: String?) -> String {
        let s = MSSQLStringLiteral.quoted(schema)
        let tableFilter = table.map { " AND tp.name = \(MSSQLStringLiteral.quoted($0))" } ?? ""
        return """
            SELECT
                fk.name AS constraint_name,
                cp.name AS column_name,
                tr.name AS ref_table,
                cr.name AS ref_column,
                sr.name AS ref_schema,
                fk.delete_referential_action_desc AS on_delete,
                fk.update_referential_action_desc AS on_update,
                tp.name AS table_name
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
            WHERE s.name = \(s)\(tableFilter)
            ORDER BY tp.name, fk.name, fkc.constraint_column_id
            """
    }
}

public struct MSSQLTableRow: Sendable, Equatable {
    public let name: String
    public let isView: Bool
    public let schema: String?

    public init(name: String, isView: Bool, schema: String? = nil) {
        self.name = name
        self.isView = isView
        self.schema = schema
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
    public let isComputed: Bool
    public let isServerGenerated: Bool
    public let collation: String?
    public let computedDefinition: String?
    public let isPersisted: Bool
    public let identitySeed: String?
    public let identityIncrement: String?

    public init(
        name: String,
        dataType: String,
        characterMaxLength: Int?,
        numericPrecision: Int?,
        numericScale: Int?,
        isNullable: Bool,
        defaultValue: String?,
        isIdentity: Bool,
        isPrimaryKey: Bool,
        isComputed: Bool = false,
        isServerGenerated: Bool = false,
        collation: String? = nil,
        computedDefinition: String? = nil,
        isPersisted: Bool = false,
        identitySeed: String? = nil,
        identityIncrement: String? = nil
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
        self.isComputed = isComputed
        self.isServerGenerated = isServerGenerated
        self.collation = collation
        self.computedDefinition = computedDefinition
        self.isPersisted = isPersisted
        self.identitySeed = identitySeed
        self.identityIncrement = identityIncrement
    }

    /// Whether the server refuses any value written to the column, which is what the host treats as generated.
    public var isGenerated: Bool {
        isComputed || isServerGenerated
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

public struct MSSQLKeyConstraintRow: Sendable, Equatable {
    public let name: String
    public let isPrimaryKey: Bool
    public let indexKind: String?
    public let columnName: String
    public let isDescending: Bool

    public init(name: String, isPrimaryKey: Bool, indexKind: String?, columnName: String, isDescending: Bool = false) {
        self.name = name
        self.isPrimaryKey = isPrimaryKey
        self.indexKind = indexKind
        self.columnName = columnName
        self.isDescending = isDescending
    }
}

public struct MSSQLCheckConstraintRow: Sendable, Equatable {
    public let name: String
    public let definition: String?
    public let isDisabled: Bool
    public let isNotTrusted: Bool

    public init(name: String, definition: String?, isDisabled: Bool = false, isNotTrusted: Bool = false) {
        self.name = name
        self.definition = definition
        self.isDisabled = isDisabled
        self.isNotTrusted = isNotTrusted
    }
}

public struct MSSQLForeignKeyRow: Sendable, Equatable {
    public let constraintName: String
    public let columnName: String
    public let referencedTable: String
    public let referencedColumn: String
    public let referencedSchema: String?
    public let onDelete: String
    public let onUpdate: String
    public let table: String?

    public init(
        constraintName: String,
        columnName: String,
        referencedTable: String,
        referencedColumn: String,
        referencedSchema: String? = nil,
        onDelete: String = "NO ACTION",
        onUpdate: String = "NO ACTION",
        table: String? = nil
    ) {
        self.constraintName = constraintName
        self.columnName = columnName
        self.referencedTable = referencedTable
        self.referencedColumn = referencedColumn
        self.referencedSchema = referencedSchema
        self.onDelete = onDelete
        self.onUpdate = onUpdate
        self.table = table
    }
}

public extension MSSQLSchemaQueries {
    static func parseTableRow(_ row: [String?]) -> MSSQLTableRow? {
        guard let name = row[safe: 0] ?? nil else { return nil }
        let typeRaw = (row[safe: 1] ?? nil) ?? "BASE TABLE"
        return MSSQLTableRow(name: name, isView: typeRaw == "VIEW", schema: row[safe: 2] ?? nil)
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
            isPrimaryKey: (row[safe: 8] ?? nil) == "1",
            isComputed: (row[safe: 9] ?? nil) == "1",
            isServerGenerated: (row[safe: 10] ?? nil) == "1",
            collation: (row[safe: 11] ?? nil).flatMap { $0.isEmpty ? nil : $0 },
            computedDefinition: row[safe: 12] ?? nil,
            isPersisted: (row[safe: 13] ?? nil) == "1",
            identitySeed: row[safe: 14] ?? nil,
            identityIncrement: row[safe: 15] ?? nil
        )
    }

    static func parseKeyConstraintRow(_ row: [String?]) -> MSSQLKeyConstraintRow? {
        guard let name = row[safe: 0] ?? nil, let column = row[safe: 3] ?? nil else { return nil }
        return MSSQLKeyConstraintRow(
            name: name,
            isPrimaryKey: (row[safe: 1] ?? nil)?.trimmingCharacters(in: .whitespaces) == "PK",
            indexKind: row[safe: 2] ?? nil,
            columnName: column,
            isDescending: (row[safe: 4] ?? nil) == "1"
        )
    }

    static func parseCheckConstraintRow(_ row: [String?]) -> MSSQLCheckConstraintRow? {
        guard let name = row[safe: 0] ?? nil else { return nil }
        return MSSQLCheckConstraintRow(
            name: name,
            definition: row[safe: 1] ?? nil,
            isDisabled: (row[safe: 2] ?? nil) == "1",
            isNotTrusted: (row[safe: 3] ?? nil) == "1"
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
            referencedSchema: row[safe: 4] ?? nil,
            onDelete: referentialAction(row[safe: 5] ?? nil),
            onUpdate: referentialAction(row[safe: 6] ?? nil),
            table: row[safe: 7] ?? nil
        )
    }

    // sys.foreign_keys spells the actions `NO_ACTION`, `SET_NULL` and `SET_DEFAULT`.
    static func referentialAction(_ description: String?) -> String {
        guard let description, !description.isEmpty else { return "NO ACTION" }
        return description.replacingOccurrences(of: "_", with: " ")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
