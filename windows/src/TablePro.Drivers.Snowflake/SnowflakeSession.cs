using System.Data;
using System.Data.Common;
using System.Globalization;
using System.Net;
using Snowflake.Data.Client;
using TablePro.Core.Browse;
using TablePro.Core.Data;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Localization;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.Snowflake;

/// <summary>
/// Snowflake over Snowflake.Data. Warehouse and role come from AdditionalOptions <c>warehouse</c> and <c>role</c> at
/// login; <c>USE WAREHOUSE</c> or <c>USE ROLE</c> in an editor tab switches them for that tab only.
/// </summary>
/// <remarks>
/// Browse and count are implemented here again (the class re-implements <see cref="IDatabaseSession"/>), and each saved
/// change is bound here, because Snowflake.Data names a positional binding <c>1</c>, not <c>:1</c> as the dialect
/// writes it in the SQL, and the base class binds names verbatim.
/// </remarks>
public sealed class SnowflakeSession : AdoNetSession, IDatabaseSession, IServerActivityProvider, ISchemaDdlProvider
{
    private readonly SnowflakeConnectionSettings _settings;
    private readonly string _defaultSchema;

    public SnowflakeSession(ConnectionRequest request)
        : base(request, SnowflakeDialect.Instance)
    {
        _settings = SnowflakeConnectionFactory.Build(request);
        _defaultSchema = SnowflakeConnectionFactory.Option(request.Profile.AdditionalOptions, SnowflakeConnectionFactory.SchemaOption) ?? "PUBLIC";
    }

    public override string? DefaultSchema => _defaultSchema;

    public string ProcessIdColumn => "QUERY_ID";

    public IReadOnlyList<string> CommonDataTypes => SnowflakeDdl.CommonDataTypes;

    public IReadOnlyList<string> BuildDdl(ObjectName table, SchemaChange change) => SnowflakeDdl.Build(table, change, TablePath);

    internal SnowflakeConnectionSettings Settings => _settings;

    protected override DbConnection CreateConnection()
    {
        var connection = new SnowflakeDbConnection(_settings.ConnectionString);
        if (_settings.Password is { } password)
        {
            connection.Password = new NetworkCredential(string.Empty, password).SecurePassword;
        }

        return connection;
    }

    public new Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        return WithConnectionAsync(
            async (connection, ct) =>
            {
                await using var command = Bind(connection, Dialect.BuildBrowse(Qualified(request)));
                await using var reader = await command.ExecuteReaderAsync(ct);
                return await ResultSetReader.ReadAsync(reader, request.Limit, ct);
            },
            cancellationToken);
    }

    public new Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                await using var command = Bind(connection, Dialect.BuildCount(WithSchema(table), filter));
                return Convert.ToInt64(await command.ExecuteScalarAsync(ct), CultureInfo.InvariantCulture);
            },
            cancellationToken);

    /// <summary>
    /// The base class's save, sync and import all reach here, so each binds by position and names the schema the
    /// session opened on.
    /// </summary>
    protected override async Task<int> ExecuteChangeAsync(DbConnection connection, DbTransaction transaction, ObjectName table, RowChange change, CancellationToken cancellationToken)
    {
        var spec = ChangeSqlBuilder.Build(Dialect, WithSchema(table), change);
        await using var command = Bind(connection, spec);
        command.Transaction = transaction;
        var affected = await command.ExecuteNonQueryAsync(cancellationToken);
        return change is not RowInsert && affected != 1
            ? throw new RowCountMismatchException(1, affected, spec.Text)
            : Math.Max(affected, 0);
    }

    protected override Task<long> ExecuteDeleteAllAsync(DbConnection connection, DbTransaction transaction, ObjectName table, CancellationToken cancellationToken) =>
        base.ExecuteDeleteAllAsync(connection, transaction, WithSchema(table), cancellationToken);

    /// <summary>Binds by position under the name Snowflake.Data expects, with a type so a number is not sent as text.</summary>
    internal static DbCommand Bind(DbConnection connection, SqlCommandSpec spec)
    {
        var command = connection.CreateCommand();
        command.CommandText = spec.Text;
        foreach (var (name, value) in spec.Parameters)
        {
            var parameter = command.CreateParameter();
            parameter.ParameterName = name.TrimStart(':');
            parameter.DbType = DbTypeOf(value);
            parameter.Value = value ?? DBNull.Value;
            command.Parameters.Add(parameter);
        }

        return command;
    }

    internal static DbType DbTypeOf(object? value) => value switch
    {
        bool => DbType.Boolean,
        sbyte or byte or short or ushort or int => DbType.Int32,
        uint or long or ulong => DbType.Int64,
        decimal => DbType.Decimal,
        float or double => DbType.Double,
        DateTimeOffset => DbType.DateTimeOffset,
        DateTime => DbType.DateTime,
        DateOnly => DbType.Date,
        TimeOnly or TimeSpan => DbType.Time,
        byte[] => DbType.Binary,
        _ => DbType.String,
    };

    protected override Task<IReadOnlyList<string>> LoadDatabasesAsync(DbConnection connection, CancellationToken cancellationToken) =>
        ShowNamesAsync(connection, SnowflakeSql.ShowDatabases, cancellationToken);

    protected override Task<IReadOnlyList<string>> LoadSchemasAsync(DbConnection connection, CancellationToken cancellationToken) =>
        ShowNamesAsync(connection, SnowflakeSql.ShowSchemas(CurrentDatabase), cancellationToken);

    protected override async Task<IReadOnlyList<DatabaseObject>> LoadObjectsAsync(DbConnection connection, string? schema, CancellationToken cancellationToken)
    {
        var resolved = string.IsNullOrEmpty(schema) ? _defaultSchema : schema;
        var path = SnowflakeSql.SchemaPath(CurrentDatabase, resolved);
        var objects = new List<DatabaseObject>();
        await ReadAsync(connection, SnowflakeSql.ShowObjects(path), reader =>
        {
            var name = reader.GetString(reader.GetOrdinal("name"));
            var kind = reader.GetString(reader.GetOrdinal("kind")).ToUpperInvariant() switch
            {
                var k when k.Contains("MATERIALIZED", StringComparison.Ordinal) => ObjectKind.MaterializedView,
                var k when k.Contains("VIEW", StringComparison.Ordinal) => ObjectKind.View,
                _ => ObjectKind.Table,
            };
            objects.Add(new DatabaseObject(new ObjectName(resolved, name), kind));
        }, cancellationToken);

        await AddRoutinesAsync(connection, SnowflakeSql.ShowProcedures(path), ObjectKind.Procedure, resolved, objects, cancellationToken);
        await AddRoutinesAsync(connection, SnowflakeSql.ShowFunctions(path), ObjectKind.Function, resolved, objects, cancellationToken);
        await ReadAsync(
            connection,
            SnowflakeSql.ShowSequences(path),
            reader => objects.Add(new DatabaseObject(new ObjectName(resolved, reader.GetString(reader.GetOrdinal("name"))), ObjectKind.Sequence)),
            cancellationToken);
        return objects;
    }

    protected override async Task<IReadOnlyList<ColumnInfo>> LoadColumnsAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var path = TablePath(table);
        var columns = new List<ColumnInfo>();
        void Map(DbDataReader reader)
        {
            var kindOrdinal = reader.GetOrdinal("kind");
            if (!reader.IsDBNull(kindOrdinal) && !string.Equals(reader.GetString(kindOrdinal), "COLUMN", StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            var defaultValue = NullableString(reader, reader.GetOrdinal("default"));
            columns.Add(new ColumnInfo(
                reader.GetString(reader.GetOrdinal("name")),
                reader.GetString(reader.GetOrdinal("type")),
                string.Equals(NullableString(reader, reader.GetOrdinal("null?")), "Y", StringComparison.OrdinalIgnoreCase),
                defaultValue,
                string.Equals(NullableString(reader, reader.GetOrdinal("primary key")), "Y", StringComparison.OrdinalIgnoreCase),
                defaultValue?.Contains("IDENTITY", StringComparison.OrdinalIgnoreCase) == true || defaultValue?.Contains("AUTOINCREMENT", StringComparison.OrdinalIgnoreCase) == true,
                columns.Count,
                NullableString(reader, reader.GetOrdinal("comment"))));
        }

        try
        {
            await ReadAsync(connection, SnowflakeSql.Describe("TABLE", path), Map, cancellationToken);
        }
        catch (SnowflakeDbException)
        {
            // A view refuses DESCRIBE TABLE on some editions; DESCRIBE VIEW reads the same columns.
            columns.Clear();
            await ReadAsync(connection, SnowflakeSql.Describe("VIEW", path), Map, cancellationToken);
        }

        return columns;
    }

    protected override async Task<IReadOnlyList<IndexInfo>> LoadIndexesAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        // Snowflake has no indexes; primary and unique keys are the closest thing and are worth showing.
        var path = TablePath(table);
        var indexes = new List<IndexInfo>();
        indexes.AddRange(await ReadKeysAsync(connection, SnowflakeSql.ShowPrimaryKeys(path), isPrimary: true, cancellationToken));
        indexes.AddRange(await ReadKeysAsync(connection, SnowflakeSql.ShowUniqueKeys(path), isPrimary: false, cancellationToken));
        return indexes;
    }

    protected override async Task<IReadOnlyList<ForeignKeyInfo>> LoadForeignKeysAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var rows = new List<(string Name, int Sequence, string Column, string RefSchema, string RefTable, string RefColumn, string? OnUpdate, string? OnDelete)>();
        try
        {
            await ReadAsync(
                connection,
                SnowflakeSql.ShowImportedKeys(TablePath(table)),
                r => rows.Add((
                    r.GetString(r.GetOrdinal("fk_name")),
                    Convert.ToInt32(r.GetValue(r.GetOrdinal("key_sequence")), CultureInfo.InvariantCulture),
                    r.GetString(r.GetOrdinal("fk_column_name")),
                    r.GetString(r.GetOrdinal("pk_schema_name")),
                    r.GetString(r.GetOrdinal("pk_table_name")),
                    r.GetString(r.GetOrdinal("pk_column_name")),
                    NullableString(r, r.GetOrdinal("update_rule")),
                    NullableString(r, r.GetOrdinal("delete_rule")))),
                cancellationToken);
        }
        catch (SnowflakeDbException)
        {
            return [];
        }

        return [.. rows.GroupBy(r => (r.Name, r.RefSchema, r.RefTable)).Select(g =>
        {
            var ordered = g.OrderBy(r => r.Sequence).ToArray();
            return new ForeignKeyInfo(g.Key.Name, [.. ordered.Select(r => r.Column)], new ObjectName(g.Key.RefSchema, g.Key.RefTable), [.. ordered.Select(r => r.RefColumn)], ordered[0].OnUpdate, ordered[0].OnDelete);
        })];
    }

    protected override async Task<string> LoadDefinitionAsync(DbConnection connection, DatabaseObject obj, CancellationToken cancellationToken)
    {
        var sql = SnowflakeSql.GetDdl(obj.Kind, TablePath(obj.Name), obj.Comment);
        return await ScalarAsync(connection, sql, cancellationToken) as string ?? throw new InvalidOperationException(CoreStrings.Format("Driver/NoDefinitionFor", obj.Name));
    }

    public Task<ResultSet> GetActivityAsync(CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                await using var command = connection.CreateCommand();
                command.CommandText = SnowflakeSql.Activity;
                await using var reader = await command.ExecuteReaderAsync(ct);
                return await ResultSetReader.ReadAsync(reader, int.MaxValue, ct);
            },
            cancellationToken);

    public Task TerminateAsync(object processId, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                var id = Convert.ToString(processId, CultureInfo.InvariantCulture) ?? string.Empty;
                await using var command = Bind(connection, new SqlCommandSpec(SnowflakeSql.CancelQuery, [new(":1", id)]));
                return await command.ExecuteScalarAsync(ct);
            },
            cancellationToken);

    private ObjectName WithSchema(ObjectName table) => string.IsNullOrEmpty(table.Schema) ? table with { Schema = _defaultSchema } : table;

    private BrowseRequest Qualified(BrowseRequest request) => request with { Table = WithSchema(request.Table) };

    private string TablePath(ObjectName table) => SnowflakeSql.TablePath(CurrentDatabase, table, _defaultSchema);

    private static async Task ReadAsync(DbConnection connection, string sql, Action<DbDataReader> map, CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = sql;
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            map(reader);
        }
    }

    private static async Task<IReadOnlyList<string>> ShowNamesAsync(DbConnection connection, string sql, CancellationToken cancellationToken)
    {
        var names = new List<string>();
        await ReadAsync(connection, sql, r => names.Add(r.GetString(r.GetOrdinal("name"))), cancellationToken);
        return names;
    }

    private static async Task AddRoutinesAsync(DbConnection connection, string sql, ObjectKind kind, string schema, List<DatabaseObject> objects, CancellationToken cancellationToken)
    {
        try
        {
            await ReadAsync(connection, sql, r =>
            {
                var builtin = r.GetOrdinal("is_builtin");
                var schemaName = r.GetOrdinal("schema_name");
                if (string.Equals(NullableString(r, builtin), "Y", StringComparison.OrdinalIgnoreCase)
                    || !string.Equals(NullableString(r, schemaName), schema, StringComparison.OrdinalIgnoreCase))
                {
                    return;
                }

                // The arguments column carries the signature GET_DDL needs; the comment slot keeps it for the definition.
                objects.Add(new DatabaseObject(new ObjectName(schema, r.GetString(r.GetOrdinal("name"))), kind, Comment: NullableString(r, r.GetOrdinal("arguments"))));
            }, cancellationToken);
        }
        catch (SnowflakeDbException)
        {
            // A role without USAGE on routines still sees the tables.
        }
    }

    private static async Task<IReadOnlyList<IndexInfo>> ReadKeysAsync(DbConnection connection, string sql, bool isPrimary, CancellationToken cancellationToken)
    {
        var rows = new List<(string Name, int Sequence, string Column)>();
        try
        {
            await ReadAsync(
                connection,
                sql,
                r => rows.Add((
                    r.GetString(r.GetOrdinal("constraint_name")),
                    Convert.ToInt32(r.GetValue(r.GetOrdinal("key_sequence")), CultureInfo.InvariantCulture),
                    r.GetString(r.GetOrdinal("column_name")))),
                cancellationToken);
        }
        catch (SnowflakeDbException)
        {
            return [];
        }

        return [.. rows.GroupBy(r => r.Name).Select(g => new IndexInfo(g.Key, [.. g.OrderBy(r => r.Sequence).Select(r => r.Column)], IsUnique: true, isPrimary))];
    }
}
