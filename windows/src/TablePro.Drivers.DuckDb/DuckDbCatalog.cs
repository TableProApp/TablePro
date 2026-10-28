namespace TablePro.Drivers.DuckDb;

/// <summary>
/// Catalog reads over the <c>duckdb_*()</c> table functions, which span every attached catalog, so each query is
/// bound to the catalog as well as the schema. A predicate on the schema alone would also match the <c>main</c>
/// schema of every other attached database.
/// </summary>
internal static class DuckDbCatalog
{
    public const string CurrentCatalog = "SELECT current_database()";

    public const string Databases = "SELECT database_name FROM duckdb_databases() WHERE NOT internal ORDER BY database_name";

    // Never filters on the schema's internal flag: DuckDB marks the auto-created main schema internal.
    public const string Schemas = """
        SELECT schema_name
        FROM duckdb_schemas()
        WHERE database_name = $catalog
          AND schema_name NOT IN ('information_schema', 'pg_catalog')
        ORDER BY schema_name
        """;

    // Macros are the only routines a user can define; duckdb_functions() also lists every built-in.
    public const string Objects = """
        SELECT table_name AS name, 0 AS kind, estimated_size, comment
        FROM duckdb_tables()
        WHERE database_name = $catalog AND schema_name = $schema AND NOT internal
        UNION ALL
        SELECT view_name, 1, NULL, comment
        FROM duckdb_views()
        WHERE database_name = $catalog AND schema_name = $schema AND NOT internal
        UNION ALL
        SELECT sequence_name, 2, NULL, comment
        FROM duckdb_sequences()
        WHERE database_name = $catalog AND schema_name = $schema
        UNION ALL
        SELECT DISTINCT function_name, 3, NULL, NULL
        FROM duckdb_functions()
        WHERE database_name = $catalog AND schema_name = $schema AND NOT internal
          AND function_type IN ('macro', 'table_macro')
        ORDER BY 2, 1
        """;

    public const string Columns = """
        SELECT column_name, data_type, is_nullable, column_default, comment
        FROM duckdb_columns()
        WHERE database_name = $catalog AND schema_name = $schema AND table_name = $table
        ORDER BY column_index
        """;

    // constraint_column_names is a LIST; UNNEST keeps a composite key's columns in declaration order.
    public const string KeyConstraints = """
        SELECT constraint_index, constraint_name, constraint_type, UNNEST(constraint_column_names)
        FROM duckdb_constraints()
        WHERE database_name = $catalog AND schema_name = $schema AND table_name = $table
          AND constraint_type IN ('PRIMARY KEY', 'UNIQUE')
        ORDER BY constraint_type = 'UNIQUE', constraint_index
        """;

    public const string PrimaryKeyColumns = """
        SELECT UNNEST(constraint_column_names)
        FROM duckdb_constraints()
        WHERE database_name = $catalog AND schema_name = $schema AND table_name = $table
          AND constraint_type = 'PRIMARY KEY'
        """;

    // duckdb_indexes() lists only the indexes a user created; a key's backing index is absent.
    public const string Indexes = """
        SELECT index_name, is_unique, sql
        FROM duckdb_indexes()
        WHERE database_name = $catalog AND schema_name = $schema AND table_name = $table
        ORDER BY index_name
        """;

    // The two lists are parallel, so unnesting both in one SELECT pairs them by position. DuckDB refuses CASCADE,
    // SET NULL and SET DEFAULT when it parses a key, so every key is NO ACTION.
    public const string ForeignKeys = """
        SELECT constraint_index, constraint_name, referenced_table,
               UNNEST(constraint_column_names), UNNEST(referenced_column_names)
        FROM duckdb_constraints()
        WHERE database_name = $catalog AND schema_name = $schema AND table_name = $table
          AND constraint_type = 'FOREIGN KEY'
        ORDER BY constraint_index
        """;

    public const string TableSql = """
        SELECT sql FROM duckdb_tables() WHERE database_name = $catalog AND schema_name = $schema AND table_name = $table
        """;

    public const string ViewSql = """
        SELECT sql FROM duckdb_views() WHERE database_name = $catalog AND schema_name = $schema AND view_name = $table
        """;

    public const string SequenceSql = """
        SELECT sql FROM duckdb_sequences() WHERE database_name = $catalog AND schema_name = $schema AND sequence_name = $table
        """;

    public const string IndexSql = """
        SELECT sql FROM duckdb_indexes()
        WHERE database_name = $catalog AND schema_name = $schema AND table_name = $table AND sql IS NOT NULL
        ORDER BY index_name
        """;

    public const string Macros = """
        SELECT function_type, macro_definition, array_to_string(parameters, ', ')
        FROM duckdb_functions()
        WHERE database_name = $catalog AND schema_name = $schema AND function_name = $table AND NOT internal
          AND function_type IN ('macro', 'table_macro')
        """;

    public const string Settings = "SELECT name, value, description, input_type, scope FROM duckdb_settings() ORDER BY name";

    // expression is the check as DuckDB re-prints it; constraint_column_names lists the columns it reads.
    public const string CheckConstraints = """
        SELECT constraint_name, expression, constraint_column_names
        FROM duckdb_constraints()
        WHERE database_name = $catalog AND schema_name = $schema AND table_name = $table AND constraint_type = 'CHECK'
        ORDER BY constraint_index
        """;

    public const string TableComment = """
        SELECT comment FROM duckdb_tables() WHERE database_name = $catalog AND schema_name = $schema AND table_name = $table
        """;
}
