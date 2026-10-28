using System.Globalization;
using System.Text;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.Sqlite;

internal sealed record SqliteDependent(string Type, string Name, string Sql);

/// <summary>What a rebuild of one table needs from the catalog, read in one pass before the script is written.</summary>
internal sealed record SqliteTableSnapshot(
    string Table,
    SqliteCreateTable Create,
    IReadOnlyList<string> CopyableColumns,
    IReadOnlyList<SqliteDependent> Dependents,
    IReadOnlyDictionary<string, List<string>> IndexColumns,
    IReadOnlyList<string> PrimaryKey,
    IReadOnlyList<string> ForeignKeyColumns,
    long? AutoincrementHighWaterMark,
    bool ForeignKeysOn,
    bool LegacyAlterTableOn);

/// <summary>The SQLite statements for each structure change. Pure, so the text is pinned by unit tests.</summary>
internal static class SqliteDdl
{
    public const string RebuildSuffix = "_tablepro_rebuild";

    public static readonly IReadOnlyList<string> CommonDataTypes =
        ["INTEGER", "TEXT", "REAL", "BLOB", "NUMERIC", "BOOLEAN", "DATETIME", "DATE", "VARCHAR(255)", "DECIMAL(10,2)"];

    private static readonly string[] RowidAliases = ["ROWID", "OID", "_ROWID_"];

    private static SqlDialect Dialect => SqliteDialect.Instance;

    public static string Qualify(ObjectName table) => Dialect.Qualify(new ObjectName(SqliteCatalog.AttachedSchema(table.Schema), table.Name));

    public static string ColumnSql(ColumnDefinition column, bool inlinePrimaryKey)
    {
        var sql = new StringBuilder(Dialect.QuoteIdentifier(column.Name));
        if (!string.IsNullOrWhiteSpace(column.DataType))
        {
            sql.Append(' ').Append(column.DataType.Trim());
        }

        if (inlinePrimaryKey)
        {
            sql.Append(" PRIMARY KEY");

            // AUTOINCREMENT is only legal on the rowid alias, which is exactly an INTEGER primary key.
            if (column.IsIdentity && string.Equals(column.DataType.Trim(), "INTEGER", StringComparison.OrdinalIgnoreCase))
            {
                sql.Append(" AUTOINCREMENT");
            }
        }

        if (!column.IsNullable)
        {
            sql.Append(" NOT NULL");
        }

        if (!string.IsNullOrWhiteSpace(column.DefaultExpression))
        {
            sql.Append(" DEFAULT ").Append(SqliteTableDdl.DefaultValue(column.DefaultExpression));
        }

        return sql.ToString();
    }

    public static string CreateTable(CreateTable change)
    {
        var primaryKey = new List<string>();
        foreach (var column in change.Columns)
        {
            if (column.IsPrimaryKey)
            {
                primaryKey.Add(column.Name);
            }
        }

        var entries = new List<SqliteTableEntry>(change.Columns.Count + 1);
        foreach (var column in change.Columns)
        {
            entries.Add(new SqliteTableEntry(ColumnSql(column, primaryKey.Count == 1 && column.IsPrimaryKey), column.Name));
        }

        if (primaryKey.Count > 1)
        {
            entries.Add(new SqliteTableEntry(string.Concat("PRIMARY KEY (", JoinQuoted(primaryKey), ")"), null));
        }

        return SqliteTableDdl.Render(Qualify(change.Table), entries, string.Empty);
    }

    // ADD COLUMN refuses a PRIMARY KEY or UNIQUE column, so the key part of the definition is left to a rebuild.
    public static string AddColumn(ObjectName table, ColumnDefinition column) =>
        string.Concat("ALTER TABLE ", Qualify(table), " ADD COLUMN ", ColumnSql(column with { IsPrimaryKey = false }, inlinePrimaryKey: false));

    public static string RenameColumn(ObjectName table, string from, string to) =>
        string.Concat("ALTER TABLE ", Qualify(table), " RENAME COLUMN ", Dialect.QuoteIdentifier(from), " TO ", Dialect.QuoteIdentifier(to));

    public static string DropColumn(ObjectName table, string column) =>
        string.Concat("ALTER TABLE ", Qualify(table), " DROP COLUMN ", Dialect.QuoteIdentifier(column));

    // An index lives in its table's database, so the index name is qualified and the table is not.
    public static string CreateIndex(ObjectName table, IndexDefinition index) =>
        string.Concat(
            "CREATE ", index.IsUnique ? "UNIQUE " : string.Empty, "INDEX ",
            Dialect.Qualify(new ObjectName(SqliteCatalog.AttachedSchema(table.Schema), index.Name)),
            " ON ", Dialect.QuoteIdentifier(table.Name), " (", JoinQuoted(index.Columns), ")");

    public static string DropIndex(ObjectName table, string index) =>
        string.Concat("DROP INDEX ", Dialect.Qualify(new ObjectName(SqliteCatalog.AttachedSchema(table.Schema), index)));

    public static string RenameTable(ObjectName table, string newName) =>
        string.Concat("ALTER TABLE ", Qualify(table), " RENAME TO ", Dialect.QuoteIdentifier(newName));

    public static string? DropObject(DatabaseObject obj) => obj.Kind switch
    {
        ObjectKind.Table => "DROP TABLE " + Qualify(obj.Name),
        ObjectKind.View => "DROP VIEW " + Qualify(obj.Name),
        ObjectKind.Trigger => "DROP TRIGGER " + Qualify(obj.Name),
        _ => null,
    };

    // SQLite has no TRUNCATE; an unqualified DELETE takes its truncate optimization.
    public static string Truncate(ObjectName table) => "DELETE FROM " + Qualify(table);

    public static string CheckEntry(CheckConstraintDefinition check) =>
        string.Concat("CONSTRAINT ", Dialect.QuoteIdentifier(check.Name.Trim()), " CHECK (", check.Expression.Trim(), ")");

    /// <summary>
    /// The table's entries with one check removed, replaced or added. <paramref name="existing"/> names the check to
    /// remove or replace, or is null to add <paramref name="replacement"/> at the end. Null when the check is not there.
    /// </summary>
    public static List<SqliteTableEntry>? WithCheck(SqliteCreateTable create, string table, string? existing, CheckConstraintDefinition? replacement)
    {
        var entries = new List<SqliteTableEntry>(create.Entries);
        if (existing is null)
        {
            if (replacement is null)
            {
                return null;
            }

            entries.Add(new SqliteTableEntry(CheckEntry(replacement), null));
            return entries;
        }

        var check = SqliteTableDdl.CheckConstraints(create, table).Find(c => string.Equals(c.Name, existing, StringComparison.OrdinalIgnoreCase));
        if (check is null)
        {
            return null;
        }

        if (replacement is null)
        {
            entries.RemoveAt(check.EntryIndex);
        }
        else
        {
            entries[check.EntryIndex] = new SqliteTableEntry(CheckEntry(replacement), null);
        }

        return entries;
    }

    /// <summary>The options SQLite stores after the column list; they are fixed when the table is made.</summary>
    public static List<TableOption> ReadOptions(SqliteCreateTable table) =>
    [
        new(TableOptionNames.WithoutRowid, table.WithoutRowid ? "YES" : "NO"),
        new(TableOptionNames.Strict, SqliteTableDdl.IsStrict(table.Suffix) ? "YES" : "NO"),
    ];

    public static string ForeignKeyEntry(ForeignKeyDefinition key)
    {
        var sql = new StringBuilder();
        if (!string.IsNullOrEmpty(key.Name))
        {
            sql.Append("CONSTRAINT ").Append(Dialect.QuoteIdentifier(key.Name)).Append(' ');
        }

        // A SQLite foreign key cannot name another database; the parent always lives beside the child.
        sql.Append("FOREIGN KEY (").Append(JoinQuoted(key.Columns)).Append(") REFERENCES ")
            .Append(Dialect.QuoteIdentifier(key.ReferencedTable.Name));
        if (key.ReferencedColumns.Count > 0)
        {
            sql.Append(" (").Append(JoinQuoted(key.ReferencedColumns)).Append(')');
        }

        if (!string.IsNullOrWhiteSpace(key.OnDelete))
        {
            sql.Append(" ON DELETE ").Append(key.OnDelete.Trim().ToUpperInvariant());
        }

        if (!string.IsNullOrWhiteSpace(key.OnUpdate))
        {
            sql.Append(" ON UPDATE ").Append(key.OnUpdate.Trim().ToUpperInvariant());
        }

        return sql.ToString();
    }

    /// <summary>
    /// SQLite's documented twelve-step rebuild: create the table as it should be, copy the rows, drop the original,
    /// rename, then put back the indexes and triggers the drop took with it.
    /// </summary>
    /// <remarks>
    /// <c>PRAGMA foreign_keys = OFF</c> runs before <c>BEGIN</c> because it is ignored inside a transaction, and
    /// without it the implicit delete of <c>DROP TABLE</c> fires <c>ON DELETE CASCADE</c> on every child table.
    /// The copy names <c>rowid</c> so a table without an INTEGER PRIMARY KEY keeps the row identities an open grid
    /// holds. <c>legacy_alter_table</c> is on for the rename so a view over the table does not fail the rename while
    /// the table is briefly gone, and off for any column ALTER afterwards so SQLite rewrites references.
    /// </remarks>
    public static List<string> Rebuild(
        SqliteTableSnapshot snapshot,
        IReadOnlyList<SqliteTableEntry> entries,
        IReadOnlyList<string> copyColumns,
        Func<SqliteDependent, bool> keepDependent,
        IReadOnlyList<string>? afterRebuild = null)
    {
        var original = Dialect.QuoteIdentifier(snapshot.Table);
        var temporary = Dialect.QuoteIdentifier(snapshot.Table + RebuildSuffix);

        var columns = new StringBuilder();
        if (CarriesRowid(snapshot, entries))
        {
            columns.Append("rowid");
        }

        foreach (var column in copyColumns)
        {
            if (columns.Length > 0)
            {
                columns.Append(", ");
            }

            columns.Append(Dialect.QuoteIdentifier(column));
        }

        var statements = new List<string>(16 + snapshot.Dependents.Count)
        {
            "PRAGMA foreign_keys = OFF",
            "BEGIN",
            "PRAGMA legacy_alter_table = ON",
            SqliteTableDdl.Render(temporary, entries, snapshot.Create.Suffix),
        };

        if (columns.Length > 0)
        {
            var list = columns.ToString();
            statements.Add(string.Concat("INSERT INTO ", temporary, " (", list, ") SELECT ", list, " FROM ", original));
        }

        statements.Add("DROP TABLE " + original);
        statements.Add(string.Concat("ALTER TABLE ", temporary, " RENAME TO ", original));

        // DROP TABLE takes the sqlite_sequence row with it, and AUTOINCREMENT promises never to hand an id out twice.
        if (snapshot.AutoincrementHighWaterMark is { } highWaterMark)
        {
            statements.Add(string.Concat(
                "UPDATE sqlite_sequence SET seq = ", highWaterMark.ToString(CultureInfo.InvariantCulture),
                " WHERE name = ", Dialect.StringLiteral(snapshot.Table)));
        }

        foreach (var dependent in snapshot.Dependents)
        {
            if (keepDependent(dependent))
            {
                statements.Add(dependent.Sql);
            }
        }

        if (afterRebuild is { Count: > 0 })
        {
            statements.Add("PRAGMA legacy_alter_table = OFF");
            statements.AddRange(afterRebuild);
        }

        statements.Add("PRAGMA legacy_alter_table = " + (snapshot.LegacyAlterTableOn ? "ON" : "OFF"));
        statements.Add("COMMIT");
        statements.Add("PRAGMA foreign_keys = " + (snapshot.ForeignKeysOn ? "ON" : "OFF"));
        return statements;
    }

    /// <summary>
    /// A table that declares a column named like a rowid alias shadows the alias, so the copy cannot name it, and a
    /// WITHOUT ROWID table has none to copy.
    /// </summary>
    private static bool CarriesRowid(SqliteTableSnapshot snapshot, IReadOnlyList<SqliteTableEntry> entries)
    {
        if (snapshot.Create.WithoutRowid)
        {
            return false;
        }

        foreach (var entry in entries)
        {
            if (entry.ColumnName is { } name && Array.Exists(RowidAliases, alias => string.Equals(alias, name, StringComparison.OrdinalIgnoreCase)))
            {
                return false;
            }
        }

        foreach (var name in snapshot.CopyableColumns)
        {
            if (Array.Exists(RowidAliases, alias => string.Equals(alias, name, StringComparison.OrdinalIgnoreCase)))
            {
                return false;
            }
        }

        return true;
    }

    private static string JoinQuoted(IReadOnlyList<string> names)
    {
        var sql = new StringBuilder();
        for (var i = 0; i < names.Count; i++)
        {
            if (i > 0)
            {
                sql.Append(", ");
            }

            sql.Append(Dialect.QuoteIdentifier(names[i]));
        }

        return sql.ToString();
    }
}
