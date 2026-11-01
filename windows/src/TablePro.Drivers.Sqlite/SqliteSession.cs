using System.Data.Common;
using System.Globalization;
using System.Text;
using Microsoft.Data.Sqlite;
using TablePro.Core.Connections;
using TablePro.Core.Data;
using TablePro.Core.Drivers;
using TablePro.Core.Localization;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.Sqlite;

public sealed partial class SqliteSession : AdoNetSession, ISchemaDdlProvider
{
    private readonly string _connectionString;
    private readonly string[] _startupCommands;
    private readonly IReadOnlyList<LoadableExtension> _extensions;

    public SqliteSession(ConnectionRequest request)
        : base(request, SqliteDialect.Instance)
    {
        _connectionString = SqliteConnectionStringFactory.Build(request);
        _startupCommands = StartupCommands.Split(request.Profile.StartupCommands, Dialect);

        // Refused here, before any file is opened, so a bad list fails the connect with nothing loaded.
        _extensions = LoadableExtensionList.Stored(request.Profile);
        LoadableExtensionPreflight.Validate(_extensions);
    }

    public override string? DefaultSchema => "main";

    public IReadOnlyList<string> CommonDataTypes => SqliteDdl.CommonDataTypes;

    protected override DbConnection CreateConnection() => new SqliteConnection(_connectionString);

    protected override async Task InitializeConnectionAsync(DbConnection connection, CancellationToken cancellationToken)
    {
        // Before the startup commands, which may call the extensions' functions.
        SqliteExtensionLoader.Load((SqliteConnection)connection, _extensions);
        foreach (var sql in _startupCommands)
        {
            await using var command = connection.CreateCommand();
            command.CommandText = sql;
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
    }

    // A SQLite file is one database; attached files are listed as schemas instead.
    protected override Task<IReadOnlyList<string>> LoadDatabasesAsync(DbConnection connection, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<string>>([]);

    protected override Task<IReadOnlyList<string>> LoadSchemasAsync(DbConnection connection, CancellationToken cancellationToken) =>
        QueryAsync(connection, SqliteCatalog.Schemas, static r => r.GetString(0), cancellationToken);

    protected override Task<IReadOnlyList<DatabaseObject>> LoadObjectsAsync(DbConnection connection, string? schema, CancellationToken cancellationToken)
    {
        var attached = SqliteCatalog.AttachedSchema(schema);
        return QueryAsync(
            connection,
            SqliteCatalog.Objects,
            r => new DatabaseObject(new ObjectName(attached, r.GetString(0)), r.GetString(1) == "view" ? ObjectKind.View : ObjectKind.Table),
            cancellationToken,
            ("@schema", SqliteCatalog.SchemaOrMain(schema)));
    }

    protected override async Task<IReadOnlyList<ColumnInfo>> LoadColumnsAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var rows = await QueryAsync(
            connection,
            SqliteCatalog.Columns,
            static r => new ColumnRow(
                r.GetString(0),
                r.IsDBNull(1) ? string.Empty : r.GetString(1),
                r.GetInt64(2) != 0,
                NullableString(r, 3),
                r.GetInt64(4)),
            cancellationToken,
            ("@table", table.Name),
            ("@schema", SqliteCatalog.SchemaOrMain(table.Schema)));

        var primaryKeyCount = 0;
        foreach (var row in rows)
        {
            if (row.PrimaryKeyPosition > 0)
            {
                primaryKeyCount++;
            }
        }

        var columns = new ColumnInfo[rows.Count];
        for (var i = 0; i < rows.Count; i++)
        {
            var row = rows[i];
            var isPrimaryKey = row.PrimaryKeyPosition > 0;

            // A lone INTEGER primary key is the rowid, which SQLite assigns when an insert leaves it out.
            var isIdentity = isPrimaryKey && primaryKeyCount == 1 && string.Equals(row.Type, "INTEGER", StringComparison.OrdinalIgnoreCase);
            columns[i] = new ColumnInfo(row.Name, row.Type, !row.NotNull && !isPrimaryKey, row.Default, isPrimaryKey, isIdentity, i);
        }

        return columns;
    }

    protected override async Task<IReadOnlyList<IndexInfo>> LoadIndexesAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var schema = SqliteCatalog.SchemaOrMain(table.Schema);
        var rows = await QueryAsync(
            connection,
            SqliteCatalog.Indexes,
            static r => new IndexRow(r.GetString(0), r.GetInt64(1) != 0, r.GetString(2), NullableString(r, 3)),
            cancellationToken,
            ("@table", table.Name),
            ("@schema", schema));

        var indexes = new List<IndexInfo>();
        var hasPrimary = false;
        var start = 0;
        while (start < rows.Count)
        {
            var end = start;
            var columns = new List<string>();
            while (end < rows.Count && rows[end].Name == rows[start].Name)
            {
                columns.Add(rows[end].Column ?? "(expression)");
                end++;
            }

            var first = rows[start];
            var isPrimary = first.Origin == "pk";
            hasPrimary |= isPrimary;
            indexes.Add(new IndexInfo(first.Name, columns, first.IsUnique, isPrimary));
            start = end;
        }

        // The rowid alias is the table's key without an index of its own, so it is listed from the column flags.
        if (!hasPrimary)
        {
            var primaryKey = await QueryAsync(
                connection,
                SqliteCatalog.PrimaryKeyColumns,
                static r => r.GetString(0),
                cancellationToken,
                ("@table", table.Name),
                ("@schema", schema));
            if (primaryKey.Count > 0)
            {
                indexes.Insert(0, new IndexInfo("PRIMARY", primaryKey, IsUnique: true, IsPrimary: true));
            }
        }

        return indexes;
    }

    protected override async Task<IReadOnlyList<ForeignKeyInfo>> LoadForeignKeysAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var schema = SqliteCatalog.SchemaOrMain(table.Schema);
        var rows = await QueryAsync(
            connection,
            SqliteCatalog.ForeignKeys,
            static r => new ForeignKeyRow(r.GetInt64(0), r.GetString(1), r.GetString(2), NullableString(r, 3), NullableString(r, 4), NullableString(r, 5)),
            cancellationToken,
            ("@table", table.Name),
            ("@schema", schema));
        if (rows.Count == 0)
        {
            return [];
        }

        // PRAGMA foreign_key_list reports no constraint name, so the name comes from the stored CREATE TABLE.
        var createSql = await ScalarAsync(connection, SqliteCatalog.TableSql(Dialect.QuoteIdentifier(schema)), cancellationToken, ("@table", table.Name)) as string;
        var declared = createSql is null ? null : SqliteTableDdl.Parse(createSql) is { } parsed ? SqliteTableDdl.DeclaredForeignKeys(parsed) : null;

        var attached = SqliteCatalog.AttachedSchema(table.Schema);
        var keys = new List<ForeignKeyInfo>();
        var start = 0;
        while (start < rows.Count)
        {
            var end = start;
            var columns = new List<string>();
            var referenced = new List<string>();
            while (end < rows.Count && rows[end].Id == rows[start].Id)
            {
                columns.Add(rows[end].From);
                referenced.Add(rows[end].To ?? string.Empty);
                end++;
            }

            var first = rows[start];
            var name = DeclaredName(declared, columns) ?? SqliteTableDdl.SynthesizedForeignKeyName(table.Name, columns);
            keys.Add(new ForeignKeyInfo(name, columns, new ObjectName(attached, first.Table), referenced, first.OnUpdate, first.OnDelete));
            start = end;
        }

        return keys;
    }

    protected override Task<IReadOnlyList<TriggerInfo>> LoadTriggersAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken) =>
        QueryAsync(
            connection,
            SqliteCatalog.Triggers(Dialect.QuoteIdentifier(SqliteCatalog.SchemaOrMain(table.Schema))),
            static r =>
            {
                var sql = r.GetString(1);
                var (timing, evt) = SqliteTableDdl.TriggerTimingAndEvent(sql);
                return new TriggerInfo(r.GetString(0), timing, evt, sql);
            },
            cancellationToken,
            ("@table", table.Name));

    protected override async Task<string> LoadDefinitionAsync(DbConnection connection, DatabaseObject obj, CancellationToken cancellationToken)
    {
        var schema = Dialect.QuoteIdentifier(SqliteCatalog.SchemaOrMain(obj.Name.Schema));
        var rows = await QueryAsync(
            connection,
            SqliteCatalog.ObjectSql(schema),
            static r => (Type: r.GetString(0), Sql: NullableString(r, 1)),
            cancellationToken,
            ("@name", obj.Name.Name));
        if (rows.Count == 0 || rows[0].Sql is not { } sql)
        {
            throw new InvalidOperationException(CoreStrings.Format("Driver/NoDefinitionFor", obj.Name));
        }

        if (rows[0].Type != "table")
        {
            return sql;
        }

        var definition = new StringBuilder(sql.TrimEnd()).Append(';');
        var dependents = await QueryAsync(
            connection,
            SqliteCatalog.Dependents(schema),
            static r => r.GetString(2),
            cancellationToken,
            ("@table", obj.Name.Name));
        foreach (var dependent in dependents)
        {
            definition.Append("\n\n").Append(dependent.TrimEnd()).Append(';');
        }

        return definition.ToString();
    }

    public IReadOnlyList<string> BuildDdl(ObjectName table, SchemaChange change) => change switch
    {
        CreateTable create => [SqliteDdl.CreateTable(create)],
        AddColumn add => [SqliteDdl.AddColumn(table, add.Column)],
        RenameColumn rename => [SqliteDdl.RenameColumn(table, rename.From, rename.To)],
        DropColumn drop => BuildDropColumn(table, drop.Column),
        AlterColumn alter => BuildAlterColumn(table, alter.Before, alter.After),
        CreateIndex index => [SqliteDdl.CreateIndex(table, index.Index)],
        DropIndex index => [SqliteDdl.DropIndex(table, index.Index)],
        AddForeignKey key => BuildAddForeignKey(table, key.ForeignKey),
        DropForeignKey key => BuildDropForeignKey(table, key.Name),
        RenameTable rename => [SqliteDdl.RenameTable(table, rename.NewName)],
        DropObject drop => SqliteDdl.DropObject(drop.Object) is { } sql ? [sql] : [],
        TruncateTable => [SqliteDdl.Truncate(table)],
        AddCheckConstraint add => add.Constraint.IsComplete ? BuildCheckRebuild(table, null, add.Constraint) : [],
        DropCheckConstraint drop => BuildCheckRebuild(table, drop.Name, null),
        AlterCheckConstraint alter => alter.After.IsComplete ? BuildCheckRebuild(table, alter.Before.Name, alter.After) : [],
        _ => [],
    };

    /// <summary>
    /// SQLite's DROP COLUMN refuses a column that is part of a key, an index or a table constraint, so only those
    /// go through a rebuild; every other column keeps the one-statement drop.
    /// </summary>
    private List<string> BuildDropColumn(ObjectName table, string column)
    {
        var simple = new List<string> { SqliteDdl.DropColumn(table, column) };
        if (SqliteCatalog.AttachedSchema(table.Schema) is not null || ReadSnapshot(table.Name) is not { } snapshot)
        {
            return simple;
        }

        var needsRebuild = ContainsName(snapshot.PrimaryKey, column) || ContainsName(snapshot.ForeignKeyColumns, column);
        foreach (var columns in snapshot.IndexColumns.Values)
        {
            needsRebuild |= ContainsName(columns, column);
        }

        var entries = new List<SqliteTableEntry>(snapshot.Create.Entries.Count);
        foreach (var entry in snapshot.Create.Entries)
        {
            if (entry.IsColumn)
            {
                if (!string.Equals(entry.ColumnName, column, StringComparison.OrdinalIgnoreCase))
                {
                    entries.Add(entry);
                }
            }
            else if (SqliteTableDdl.ConstraintMentions(entry.Text, column))
            {
                needsRebuild = true;
            }
            else
            {
                entries.Add(entry);
            }
        }

        if (!needsRebuild)
        {
            return simple;
        }

        var copy = new List<string>(snapshot.CopyableColumns.Count);
        foreach (var name in snapshot.CopyableColumns)
        {
            if (!string.Equals(name, column, StringComparison.OrdinalIgnoreCase))
            {
                copy.Add(name);
            }
        }

        return SqliteDdl.Rebuild(
            snapshot,
            entries,
            copy,
            dependent => dependent.Type != "index"
                || !(snapshot.IndexColumns.TryGetValue(dependent.Name, out var columns) && ContainsName(columns, column)));
    }

    private List<string> BuildAlterColumn(ObjectName table, ColumnDefinition before, ColumnDefinition after)
    {
        var renames = !string.Equals(before.Name, after.Name, StringComparison.Ordinal);
        var rename = renames ? new List<string> { SqliteDdl.RenameColumn(table, before.Name, after.Name) } : [];
        var sameDefinition = string.Equals(before.DataType.Trim(), after.DataType.Trim(), StringComparison.OrdinalIgnoreCase)
            && before.IsNullable == after.IsNullable
            && string.Equals(before.DefaultExpression?.Trim(), after.DefaultExpression?.Trim(), StringComparison.Ordinal);

        // SQLite keeps no column comments, so a comment-only edit has nothing to run.
        if (sameDefinition)
        {
            return rename;
        }

        if (SqliteCatalog.AttachedSchema(table.Schema) is not null || ReadSnapshot(table.Name) is not { } snapshot)
        {
            return [];
        }

        var entries = new List<SqliteTableEntry>(snapshot.Create.Entries);
        var index = entries.FindIndex(e => string.Equals(e.ColumnName, before.Name, StringComparison.OrdinalIgnoreCase));
        if (index < 0
            || SqliteTableDdl.RewriteColumn(entries[index].Text, Dialect.QuoteIdentifier(before.Name), after.DataType, after.IsNullable, after.DefaultExpression)
                is not { } rewritten)
        {
            return [];
        }

        entries[index] = new SqliteTableEntry(rewritten, before.Name);
        return SqliteDdl.Rebuild(snapshot, entries, snapshot.CopyableColumns, static _ => true, rename);
    }

    // SQLite's ALTER TABLE cannot add or drop a foreign key at any version, so both rebuild the table.
    private List<string> BuildAddForeignKey(ObjectName table, ForeignKeyDefinition key)
    {
        if (SqliteCatalog.AttachedSchema(table.Schema) is not null || ReadSnapshot(table.Name) is not { } snapshot)
        {
            return [];
        }

        var entries = new List<SqliteTableEntry>(snapshot.Create.Entries) { new(SqliteDdl.ForeignKeyEntry(key), null) };
        return SqliteDdl.Rebuild(snapshot, entries, snapshot.CopyableColumns, static _ => true);
    }

    private List<string> BuildDropForeignKey(ObjectName table, string name)
    {
        if (SqliteCatalog.AttachedSchema(table.Schema) is not null || ReadSnapshot(table.Name) is not { } snapshot)
        {
            return [];
        }

        foreach (var key in SqliteTableDdl.DeclaredForeignKeys(snapshot.Create))
        {
            var keyName = key.Name ?? SqliteTableDdl.SynthesizedForeignKeyName(table.Name, key.Columns);
            if (!string.Equals(keyName, name, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            var entries = new List<SqliteTableEntry>(snapshot.Create.Entries);
            if (key.InlineClause is { } clause)
            {
                var entry = entries[key.EntryIndex];
                entries[key.EntryIndex] = entry with { Text = SqliteTableDdl.RemoveClause(entry.Text, clause) };
            }
            else
            {
                entries.RemoveAt(key.EntryIndex);
            }

            return SqliteDdl.Rebuild(snapshot, entries, snapshot.CopyableColumns, static _ => true);
        }

        return [];
    }

    /// <summary>
    /// Reads what a rebuild needs. <see cref="ISchemaDdlProvider.BuildDdl"/> is synchronous, and SQLite's API is
    /// natively synchronous, so these are plain blocking reads of the local file rather than async work waited on.
    /// </summary>
    private SqliteTableSnapshot? ReadSnapshot(string table)
    {
        using var connection = new SqliteConnection(_connectionString);
        connection.Open();

        if (Scalar(connection, SqliteCatalog.TableSql("\"main\""), table) is not string createSql || SqliteTableDdl.Parse(createSql) is not { } create)
        {
            return null;
        }

        var copyable = ReadStrings(connection, SqliteCatalog.CopyableColumns, table, 0);
        var primaryKey = ReadStrings(connection, SqliteCatalog.PrimaryKeyColumns, table, 0);
        var foreignKeyColumns = ReadStrings(connection, SqliteCatalog.ForeignKeyColumns, table, 0);

        var indexColumns = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        using (var command = Command(connection, SqliteCatalog.Indexes, table))
        using (var reader = command.ExecuteReader())
        {
            while (reader.Read())
            {
                var name = reader.GetString(0);
                if (!indexColumns.TryGetValue(name, out var columns))
                {
                    indexColumns[name] = columns = [];
                }

                if (!reader.IsDBNull(3))
                {
                    columns.Add(reader.GetString(3));
                }
            }
        }

        var dependents = new List<SqliteDependent>();
        using (var command = Command(connection, SqliteCatalog.Dependents("\"main\""), table))
        using (var reader = command.ExecuteReader())
        {
            while (reader.Read())
            {
                dependents.Add(new SqliteDependent(reader.GetString(0), reader.GetString(1), reader.GetString(2)));
            }
        }

        long? highWaterMark = null;
        if (createSql.Contains("AUTOINCREMENT", StringComparison.OrdinalIgnoreCase)
            && Scalar(connection, SqliteCatalog.AutoincrementHighWaterMark, table) is { } seq)
        {
            highWaterMark = Convert.ToInt64(seq, CultureInfo.InvariantCulture);
        }

        var foreignKeysOn = Convert.ToInt64(Scalar(connection, SqliteCatalog.ForeignKeysPragma, table) ?? 0L, CultureInfo.InvariantCulture) != 0;
        var legacyAlterTable = Convert.ToInt64(Scalar(connection, SqliteCatalog.LegacyAlterTablePragma, table) ?? 0L, CultureInfo.InvariantCulture) != 0;

        return new SqliteTableSnapshot(
            table, create, copyable, dependents, indexColumns, primaryKey, foreignKeyColumns, highWaterMark, foreignKeysOn, legacyAlterTable);
    }

    private static SqliteCommand Command(SqliteConnection connection, string sql, string table)
    {
        var command = connection.CreateCommand();
        command.CommandText = sql;
        if (sql.Contains("@table", StringComparison.Ordinal))
        {
            command.Parameters.AddWithValue("@table", table);
        }

        if (sql.Contains("@schema", StringComparison.Ordinal))
        {
            command.Parameters.AddWithValue("@schema", "main");
        }

        return command;
    }

    private static object? Scalar(SqliteConnection connection, string sql, string table)
    {
        using var command = Command(connection, sql, table);
        var value = command.ExecuteScalar();
        return value is DBNull ? null : value;
    }

    private static List<string> ReadStrings(SqliteConnection connection, string sql, string table, int ordinal)
    {
        using var command = Command(connection, sql, table);
        using var reader = command.ExecuteReader();
        var values = new List<string>();
        while (reader.Read())
        {
            values.Add(reader.GetString(ordinal));
        }

        return values;
    }

    private static string? DeclaredName(List<SqliteDeclaredForeignKey>? declared, List<string> columns)
    {
        if (declared is null)
        {
            return null;
        }

        foreach (var key in declared)
        {
            if (key.Name is not null && SqliteTableDdl.SameColumns(key.Columns, columns))
            {
                return key.Name;
            }
        }

        return null;
    }

    private static bool ContainsName(IReadOnlyList<string> names, string name)
    {
        foreach (var candidate in names)
        {
            if (string.Equals(candidate, name, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    private readonly record struct ColumnRow(string Name, string Type, bool NotNull, string? Default, long PrimaryKeyPosition);

    private readonly record struct IndexRow(string Name, bool IsUnique, string Origin, string? Column);

    private readonly record struct ForeignKeyRow(long Id, string Table, string From, string? To, string? OnUpdate, string? OnDelete);
}
