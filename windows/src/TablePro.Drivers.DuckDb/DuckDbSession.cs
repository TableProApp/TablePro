using System.Data.Common;
using System.Globalization;
using System.Text;
using TablePro.Core.Data;
using TablePro.Core.Drivers;
using TablePro.Core.Localization;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.DuckDb;

public sealed partial class DuckDbSession : AdoNetSession, ISchemaDdlProvider, IServerVariablesProvider
{
    private const string DefaultSchemaName = "main";

    private readonly string _connectionString;
    private readonly string[] _startupCommands;
    private DbConnection? _keepAlive;
    private string _catalog = string.Empty;

    public DuckDbSession(ConnectionRequest request)
        : base(request, DuckDbDialect.Instance)
    {
        _connectionString = DuckDbConnectionStringFactory.Build(request);
        _startupCommands = StartupCommands.Split(request.Profile.StartupCommands, Dialect);
    }

    public override string? DefaultSchema => DefaultSchemaName;

    public IReadOnlyList<string> CommonDataTypes => DuckDbDdl.CommonDataTypes;

    /// <summary>
    /// Holds one connection for the session's lifetime. DuckDB.NET closes the database once its last connection
    /// closes, so without it every sidebar read would reopen the file and replay its write-ahead log.
    /// </summary>
    internal async Task StartAsync(CancellationToken cancellationToken)
    {
        _keepAlive = await OpenAsync(cancellationToken);
        _catalog = Convert.ToString(await ScalarAsync(_keepAlive, DuckDbCatalog.CurrentCatalog, cancellationToken), CultureInfo.InvariantCulture) ?? string.Empty;
        CurrentDatabase = _catalog;
    }

    public override async ValueTask DisposeAsync()
    {
        if (_keepAlive is not null)
        {
            await _keepAlive.DisposeAsync();
            _keepAlive = null;
        }

        await base.DisposeAsync();
    }

    protected override DbConnection CreateConnection() => new DuckDbSessionConnection(_connectionString);

    protected override async Task InitializeConnectionAsync(DbConnection connection, CancellationToken cancellationToken)
    {
        foreach (var sql in _startupCommands)
        {
            await using var command = connection.CreateCommand();
            command.CommandText = sql;
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
    }

    protected override Task<IReadOnlyList<string>> LoadDatabasesAsync(DbConnection connection, CancellationToken cancellationToken) =>
        QueryAsync(connection, DuckDbCatalog.Databases, static r => r.GetString(0), cancellationToken);

    protected override Task<IReadOnlyList<string>> LoadSchemasAsync(DbConnection connection, CancellationToken cancellationToken) =>
        QueryAsync(connection, DuckDbCatalog.Schemas, static r => r.GetString(0), cancellationToken, ("catalog", _catalog));

    protected override Task<IReadOnlyList<DatabaseObject>> LoadObjectsAsync(DbConnection connection, string? schema, CancellationToken cancellationToken)
    {
        var resolved = SchemaOrDefault(schema);
        return QueryAsync(
            connection,
            DuckDbCatalog.Objects,
            r => new DatabaseObject(
                new ObjectName(resolved, r.GetString(0)),
                r.GetInt32(1) switch
                {
                    0 => ObjectKind.Table,
                    1 => ObjectKind.View,
                    2 => ObjectKind.Sequence,
                    _ => ObjectKind.Function,
                },
                r.IsDBNull(2) ? null : Convert.ToInt64(r.GetValue(2), CultureInfo.InvariantCulture),
                r.IsDBNull(3) ? null : r.GetString(3)),
            cancellationToken,
            ("catalog", _catalog),
            ("schema", resolved));
    }

    protected override async Task<IReadOnlyList<ColumnInfo>> LoadColumnsAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var primaryKey = await QueryAsync(connection, DuckDbCatalog.PrimaryKeyColumns, static r => r.GetString(0), cancellationToken, Bind(table));
        var columns = await QueryAsync(
            connection,
            DuckDbCatalog.Columns,
            static r => new ColumnInfo(
                r.GetString(0),
                r.GetString(1),
                r.GetBoolean(2),
                r.IsDBNull(3) ? null : r.GetString(3),
                IsPrimaryKey: false,
                IsIdentity: false,
                Ordinal: 0,
                Comment: r.IsDBNull(4) ? null : r.GetString(4)),
            cancellationToken,
            Bind(table));

        var result = new ColumnInfo[columns.Count];
        for (var i = 0; i < columns.Count; i++)
        {
            var column = columns[i];
            var isPrimaryKey = Contains(primaryKey, column.Name);
            var isIdentity = column.DefaultValue is { } value && value.StartsWith("nextval(", StringComparison.OrdinalIgnoreCase);
            result[i] = column with { IsPrimaryKey = isPrimaryKey, IsIdentity = isIdentity, Ordinal = i, IsNullable = column.IsNullable && !isPrimaryKey };
        }

        return result;
    }

    protected override async Task<IReadOnlyList<IndexInfo>> LoadIndexesAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var keys = await QueryAsync(
            connection,
            DuckDbCatalog.KeyConstraints,
            static r => (Index: Convert.ToInt64(r.GetValue(0), CultureInfo.InvariantCulture), Name: r.GetString(1), Primary: r.GetString(2) == "PRIMARY KEY", Column: r.GetString(3)),
            cancellationToken,
            Bind(table));

        var indexes = new List<IndexInfo>();
        var start = 0;
        while (start < keys.Count)
        {
            var end = start;
            var columns = new List<string>();
            while (end < keys.Count && keys[end].Index == keys[start].Index && keys[end].Primary == keys[start].Primary)
            {
                columns.Add(keys[end].Column);
                end++;
            }

            indexes.Add(new IndexInfo(keys[start].Name, columns, IsUnique: true, IsPrimary: keys[start].Primary, "ART"));
            start = end;
        }

        var created = await QueryAsync(
            connection,
            DuckDbCatalog.Indexes,
            static r => new IndexInfo(r.GetString(0), DuckDbDdl.IndexColumns(r.IsDBNull(2) ? null : r.GetString(2)), r.GetBoolean(1), IsPrimary: false, "ART"),
            cancellationToken,
            Bind(table));
        indexes.AddRange(created);
        return indexes;
    }

    protected override async Task<IReadOnlyList<ForeignKeyInfo>> LoadForeignKeysAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var rows = await QueryAsync(
            connection,
            DuckDbCatalog.ForeignKeys,
            static r => (Index: Convert.ToInt64(r.GetValue(0), CultureInfo.InvariantCulture), Name: r.GetString(1), Parent: r.IsDBNull(2) ? null : r.GetString(2), Column: r.GetString(3), Referenced: r.GetString(4)),
            cancellationToken,
            Bind(table));

        var keys = new List<ForeignKeyInfo>();
        var start = 0;
        while (start < rows.Count)
        {
            var end = start;
            var columns = new List<string>();
            var referenced = new List<string>();
            while (end < rows.Count && rows[end].Index == rows[start].Index)
            {
                columns.Add(rows[end].Column);
                referenced.Add(rows[end].Referenced);
                end++;
            }

            // DuckDB lists a key on the parent as well; only the child's entry names a referenced table.
            if (rows[start].Parent is { } parent)
            {
                keys.Add(new ForeignKeyInfo(rows[start].Name, columns, new ObjectName(SchemaOrDefault(table.Schema), parent), referenced, "NO ACTION", "NO ACTION"));
            }

            start = end;
        }

        return keys;
    }

    protected override async Task<string> LoadDefinitionAsync(DbConnection connection, DatabaseObject obj, CancellationToken cancellationToken)
    {
        var parameters = Bind(obj.Name);
        switch (obj.Kind)
        {
            case ObjectKind.Table:
                var table = new StringBuilder(Statement(await ScalarAsync(connection, DuckDbCatalog.TableSql, cancellationToken, parameters), obj));
                foreach (var index in await QueryAsync(connection, DuckDbCatalog.IndexSql, static r => r.GetString(0), cancellationToken, parameters))
                {
                    table.Append("\n\n").Append(index.TrimEnd().TrimEnd(';')).Append(';');
                }

                return table.ToString();
            case ObjectKind.View:
                return DuckDbDdl.ReplaceableView(Statement(await ScalarAsync(connection, DuckDbCatalog.ViewSql, cancellationToken, parameters), obj));
            case ObjectKind.Sequence:
                return Statement(await ScalarAsync(connection, DuckDbCatalog.SequenceSql, cancellationToken, parameters), obj);
            case ObjectKind.Function:
                return await MacroDefinitionAsync(connection, obj, parameters, cancellationToken);
            default:
                throw new NotSupportedException(CoreStrings.Format("Driver/EngineHasNoDefinitionFor", "DuckDB", obj.Name));
        }
    }

    public IReadOnlyList<string> BuildDdl(ObjectName table, SchemaChange change) => change switch
    {
        CreateTable create => DuckDbDdl.CreateTable(create),
        AddColumn add => DuckDbDdl.AddColumn(table, add.Column),
        DropColumn drop => [DuckDbDdl.DropColumn(table, drop.Column)],
        RenameColumn rename => [DuckDbDdl.RenameColumn(table, rename.From, rename.To)],
        AlterColumn alter => DuckDbDdl.AlterColumn(table, alter.Before, alter.After),
        CreateIndex index => [DuckDbDdl.CreateIndex(table, index.Index)],
        DropIndex index => [DuckDbDdl.DropIndex(table, index.Index)],
        RenameTable rename => [DuckDbDdl.RenameTable(table, rename.NewName)],
        DropObject drop => DuckDbDdl.DropObject(drop.Object, drop.Cascade) is { } sql ? [sql] : [],
        TruncateTable => [DuckDbDdl.Truncate(table)],
        SetTableOptions options => DuckDbDdl.SetOptions(table, options.Changes),

        // DuckDB's ALTER TABLE cannot add or drop a foreign key or a check; both are only declared at CREATE TABLE.
        _ => [],
    };

    public Task<ResultSet> GetVariablesAsync(CancellationToken cancellationToken) =>
        WithConnectionAsync(
            static async (connection, ct) =>
            {
                await using var command = connection.CreateCommand();
                command.CommandText = DuckDbCatalog.Settings;
                await using var reader = await command.ExecuteReaderAsync(ct);
                return await ResultSetReader.ReadAsync(reader, int.MaxValue, ct);
            },
            cancellationToken);

    private async Task<string> MacroDefinitionAsync(DbConnection connection, DatabaseObject obj, (string, object?)[] parameters, CancellationToken cancellationToken)
    {
        // DuckDB keeps the parsed body, not the text the user typed, so the statement is rebuilt from its parts.
        var overloads = await QueryAsync(
            connection,
            DuckDbCatalog.Macros,
            static r => (Type: r.GetString(0), Body: r.IsDBNull(1) ? string.Empty : r.GetString(1), Parameters: r.IsDBNull(2) ? string.Empty : r.GetString(2)),
            cancellationToken,
            parameters);
        if (overloads.Count == 0)
        {
            throw new InvalidOperationException(CoreStrings.Format("Driver/NoDefinitionFor", obj.Name));
        }

        var sql = new StringBuilder();
        foreach (var (type, body, arguments) in overloads)
        {
            if (sql.Length > 0)
            {
                sql.Append("\n\n");
            }

            sql.Append("CREATE OR REPLACE MACRO ").Append(Dialect.Qualify(obj.Name)).Append('(').Append(arguments).Append(") AS ")
                .Append(type == "table_macro" ? "TABLE " : string.Empty).Append(body).Append(';');
        }

        return sql.ToString();
    }

    private (string, object?)[] Bind(ObjectName name) => [("catalog", _catalog), ("schema", SchemaOrDefault(name.Schema)), ("table", name.Name)];

    private static string SchemaOrDefault(string? schema) => string.IsNullOrEmpty(schema) ? DefaultSchemaName : schema;

    private static string Statement(object? sql, DatabaseObject obj) =>
        sql is string text
            ? text.TrimEnd().TrimEnd(';') + ";"
            : throw new InvalidOperationException(CoreStrings.Format("Driver/NoDefinitionFor", obj.Name));

    private static bool Contains(IReadOnlyList<string> names, string name)
    {
        foreach (var candidate in names)
        {
            if (string.Equals(candidate, name, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }
}
