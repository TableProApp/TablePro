namespace TablePro.Drivers.Sqlite;

/// <summary>
/// Catalog reads. The table-valued pragmas take the table and schema as bound arguments; only <c>sqlite_master</c>
/// has to be addressed through a quoted schema name, which the builders below take.
/// </summary>
internal static class SqliteCatalog
{
    public const string Schemas = "SELECT name FROM pragma_database_list WHERE name <> 'temp' ORDER BY seq";

    // 'shadow' tables belong to an FTS or R-tree table and are not the user's to browse.
    public const string Objects = """
        SELECT name, type
        FROM pragma_table_list
        WHERE schema = @schema
          AND type IN ('table', 'view', 'virtual')
          AND name NOT LIKE 'sqlite!_%' ESCAPE '!'
        ORDER BY name
        """;

    // table_xinfo rather than table_info: table_info leaves out generated columns. hidden = 1 is a virtual table's
    // hidden column, which no statement can address by position.
    public const string Columns = """
        SELECT name, type, "notnull", dflt_value, pk, hidden
        FROM pragma_table_xinfo(@table, @schema)
        WHERE hidden <> 1
        ORDER BY cid
        """;

    public const string CopyableColumns = """
        SELECT name FROM pragma_table_xinfo(@table, @schema) WHERE hidden = 0 ORDER BY cid
        """;

    public const string PrimaryKeyColumns = """
        SELECT name FROM pragma_table_info(@table, @schema) WHERE pk > 0 ORDER BY pk
        """;

    public const string Indexes = """
        SELECT il.name, il."unique", il.origin, ii.name
        FROM pragma_index_list(@table, @schema) AS il
        JOIN pragma_index_xinfo(il.name, @schema) AS ii
        WHERE ii.key = 1
        ORDER BY il.origin = 'pk' DESC, il.name, ii.seqno
        """;

    // A key that names no parent columns points at the parent's primary key, which table_info gives by position.
    public const string ForeignKeys = """
        SELECT f.id, f."table", f."from",
               ifnull(f."to", (SELECT k.name FROM pragma_table_info(f."table", @schema) AS k WHERE k.pk = f.seq + 1)),
               f.on_update, f.on_delete
        FROM pragma_foreign_key_list(@table, @schema) AS f
        ORDER BY f.id, f.seq
        """;

    public const string ForeignKeyColumns = """SELECT "from" FROM pragma_foreign_key_list(@table, @schema)""";

    public const string ForeignKeysPragma = "PRAGMA foreign_keys";

    public const string LegacyAlterTablePragma = "PRAGMA legacy_alter_table";

    public const string AutoincrementHighWaterMark = "SELECT seq FROM sqlite_sequence WHERE name = @table";

    private const string ObjectSqlTail = ".sqlite_master WHERE name = @name AND type IN ('table', 'view', 'trigger', 'index')";

    private const string TableSqlTail = ".sqlite_master WHERE type = 'table' AND name = @table";

    private const string TriggersTail = ".sqlite_master WHERE type = 'trigger' AND tbl_name = @table AND sql IS NOT NULL ORDER BY name";

    // A null sql is an index SQLite made for a UNIQUE or PRIMARY KEY constraint; it comes back with the table.
    private const string DependentsTail =
        ".sqlite_master WHERE tbl_name = @table AND type IN ('index', 'trigger') AND sql IS NOT NULL ORDER BY type, name";

    public static string ObjectSql(string quotedSchema) => string.Concat("SELECT type, sql FROM ", quotedSchema, ObjectSqlTail);

    public static string TableSql(string quotedSchema) => string.Concat("SELECT sql FROM ", quotedSchema, TableSqlTail);

    public static string Triggers(string quotedSchema) => string.Concat("SELECT name, sql FROM ", quotedSchema, TriggersTail);

    public static string Dependents(string quotedSchema) => string.Concat("SELECT type, name, sql FROM ", quotedSchema, DependentsTail);

    /// <summary>Nil, empty and <c>main</c> all name the opened file.</summary>
    public static string SchemaOrMain(string? schema) => string.IsNullOrEmpty(schema) ? "main" : schema;

    /// <summary>Objects in the opened file carry no schema, so their names stay unqualified in generated SQL.</summary>
    public static string? AttachedSchema(string? schema) =>
        string.IsNullOrEmpty(schema) || string.Equals(schema, "main", StringComparison.OrdinalIgnoreCase) ? null : schema;
}
