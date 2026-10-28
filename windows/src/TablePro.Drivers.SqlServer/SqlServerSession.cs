using System.Data.Common;
using System.Text;
using Microsoft.Data.SqlClient;
using TablePro.Core.Data;
using TablePro.Core.Drivers;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.SqlServer;

public sealed partial class SqlServerSession
    : AdoNetSession, ISchemaDdlProvider, IServerActivityProvider, IUserListProvider, IDatabaseAdministration, IServerVariablesProvider
{
    private const string DefaultSchemaName = "dbo";

    private readonly string _connectionString;
    private readonly string[] _startupBatches;

    public SqlServerSession(ConnectionRequest request)
        : base(request, SqlServerDialect.Instance)
    {
        _connectionString = SqlServerConnectionStringFactory.Build(request);
        _startupBatches = StartupCommands.Split(request.Profile.StartupCommands, Dialect);
    }

    public override string? DefaultSchema => DefaultSchemaName;

    public IReadOnlyList<string> CommonDataTypes => SqlServerDdl.CommonDataTypes;

    public string ProcessIdColumn => "session_id";

    protected override DbConnection CreateConnection() => new SqlConnection(_connectionString);

    // The pool runs sp_reset_connection on reuse, which clears SET options, so the batches run on every open.
    protected override async Task InitializeConnectionAsync(DbConnection connection, CancellationToken cancellationToken)
    {
        foreach (var batch in _startupBatches)
        {
            await using var command = connection.CreateCommand();
            command.CommandText = batch;
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
    }

    protected override void AttachMessages(DbConnection connection, Action<string> onMessage) =>
        ((SqlConnection)connection).InfoMessage += (_, e) =>
        {
            foreach (SqlError error in e.Errors)
            {
                onMessage(error.Message);
            }
        };

    protected override Task<IReadOnlyList<string>> LoadDatabasesAsync(DbConnection connection, CancellationToken cancellationToken) =>
        QueryAsync(connection, SqlServerCatalog.Databases, static r => r.GetString(0), cancellationToken);

    protected override Task<IReadOnlyList<string>> LoadSchemasAsync(DbConnection connection, CancellationToken cancellationToken) =>
        QueryAsync(connection, SqlServerCatalog.Schemas, static r => r.GetString(0), cancellationToken);

    protected override Task<IReadOnlyList<DatabaseObject>> LoadObjectsAsync(DbConnection connection, string? schema, CancellationToken cancellationToken)
    {
        var resolved = SchemaOrDefault(schema);
        return QueryAsync(
            connection,
            SqlServerCatalog.Objects,
            r =>
            {
                var kind = r.GetString(1) switch
                {
                    "U" => ObjectKind.Table,
                    "V" => ObjectKind.View,
                    "P" or "PC" => ObjectKind.Procedure,
                    "SO" => ObjectKind.Sequence,
                    _ => ObjectKind.Function,
                };
                return new DatabaseObject(
                    new ObjectName(resolved, r.GetString(0)),
                    kind,
                    r.IsDBNull(2) ? null : r.GetInt64(2),
                    r.IsDBNull(3) ? null : r.GetString(3));
            },
            cancellationToken,
            ("@schema", resolved));
    }

    protected override Task<IReadOnlyList<ColumnInfo>> LoadColumnsAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var ordinal = 0;
        return QueryAsync(
            connection,
            SqlServerCatalog.Columns,
            r => new ColumnInfo(
                r.GetString(0),
                r.GetString(1),
                r.GetBoolean(2),
                r.IsDBNull(3) ? null : r.GetString(3),
                r.GetBoolean(4),
                r.GetBoolean(5),
                ordinal++,
                r.IsDBNull(6) ? null : r.GetString(6)),
            cancellationToken,
            Bind(table));
    }

    protected override async Task<IReadOnlyList<IndexInfo>> LoadIndexesAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var rows = await QueryAsync(
            connection,
            SqlServerCatalog.Indexes,
            static r => (Name: r.GetString(0), Unique: r.GetBoolean(1), Primary: r.GetBoolean(2), Method: r.GetString(3), Column: r.GetString(4)),
            cancellationToken,
            Bind(table));

        var indexes = new List<IndexInfo>();
        var start = 0;
        while (start < rows.Count)
        {
            var end = start;
            var columns = new List<string>();
            while (end < rows.Count && rows[end].Name == rows[start].Name)
            {
                columns.Add(rows[end].Column);
                end++;
            }

            var first = rows[start];
            indexes.Add(new IndexInfo(first.Name, columns, first.Unique, first.Primary, first.Method));
            start = end;
        }

        return indexes;
    }

    protected override async Task<IReadOnlyList<ForeignKeyInfo>> LoadForeignKeysAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var rows = await QueryAsync(
            connection,
            SqlServerCatalog.ForeignKeys,
            static r => (Name: r.GetString(0), Column: r.GetString(1), ReferencedSchema: r.GetString(2), ReferencedTable: r.GetString(3),
                ReferencedColumn: r.GetString(4), OnUpdate: r.GetString(5), OnDelete: r.GetString(6)),
            cancellationToken,
            Bind(table));

        var keys = new List<ForeignKeyInfo>();
        var start = 0;
        while (start < rows.Count)
        {
            var end = start;
            var columns = new List<string>();
            var referenced = new List<string>();
            while (end < rows.Count && rows[end].Name == rows[start].Name)
            {
                columns.Add(rows[end].Column);
                referenced.Add(rows[end].ReferencedColumn);
                end++;
            }

            var first = rows[start];
            keys.Add(new ForeignKeyInfo(
                first.Name,
                columns,
                new ObjectName(first.ReferencedSchema, first.ReferencedTable),
                referenced,
                SqlServerDdl.ReferentialAction(first.OnUpdate),
                SqlServerDdl.ReferentialAction(first.OnDelete)));
            start = end;
        }

        return keys;
    }

    protected override Task<IReadOnlyList<TriggerInfo>> LoadTriggersAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken) =>
        QueryAsync(
            connection,
            SqlServerCatalog.Triggers,
            static r => new TriggerInfo(r.GetString(0), r.GetString(1), r.IsDBNull(2) ? string.Empty : r.GetString(2), NullableString(r, 3)),
            cancellationToken,
            Bind(table));

    protected override async Task<string> LoadDefinitionAsync(DbConnection connection, DatabaseObject obj, CancellationToken cancellationToken)
    {
        var parameters = Bind(obj.Name);
        switch (obj.Kind)
        {
            case ObjectKind.Table:
                return await TableDefinitionAsync(connection, obj, parameters, cancellationToken);
            case ObjectKind.Sequence:
                return await ScalarAsync(connection, SqlServerCatalog.SequenceDefinition, cancellationToken, parameters) is string sequence
                    ? sequence + ";"
                    : throw NotFound(obj);
            default:
                // NULL when the module is encrypted or the account lacks VIEW DEFINITION.
                return await ScalarAsync(connection, SqlServerCatalog.ModuleDefinition, cancellationToken, parameters) is string module
                    ? module.Trim()
                    : throw NotFound(obj);
        }
    }

    public IReadOnlyList<string> BuildDdl(ObjectName table, SchemaChange change) =>
        SqlServerDdl.Build(table.Schema is null ? table with { Schema = DefaultSchemaName } : table, change);

    public Task<ResultSet> GetActivityAsync(CancellationToken cancellationToken) => ReadResultAsync(SqlServerCatalog.Activity, cancellationToken);

    public Task TerminateAsync(object processId, CancellationToken cancellationToken)
    {
        var sql = SqlServerDdl.Kill(processId);
        return WithConnectionAsync((connection, ct) => ScalarAsync(connection, sql, ct), cancellationToken);
    }

    public Task<ResultSet> GetUsersAsync(CancellationToken cancellationToken) => ReadResultAsync(SqlServerCatalog.Users, cancellationToken);

    public Task<ResultSet> GetVariablesAsync(CancellationToken cancellationToken) => ReadResultAsync(SqlServerCatalog.Configuration, cancellationToken);

    public string BuildCreateDatabase(string name) => SqlServerDdl.CreateDatabase(name);

    public string BuildDropDatabase(string name) => SqlServerDdl.DropDatabase(name);

    private static async Task<string> TableDefinitionAsync(DbConnection connection, DatabaseObject obj, (string, object?)[] parameters, CancellationToken cancellationToken)
    {
        var parts = new List<string>(await QueryAsync(connection, SqlServerCatalog.ColumnDefinitions, static r => r.GetString(0), cancellationToken, parameters));
        if (parts.Count == 0)
        {
            throw NotFound(obj);
        }

        parts.AddRange(await QueryAsync(connection, SqlServerCatalog.KeyConstraintDefinitions, static r => r.GetString(0), cancellationToken, parameters));
        parts.AddRange(await QueryAsync(connection, SqlServerCatalog.CheckConstraintDefinitions, static r => r.GetString(0), cancellationToken, parameters));
        parts.AddRange(await QueryAsync(connection, SqlServerCatalog.ForeignKeyDefinitions, static r => r.GetString(0), cancellationToken, parameters));

        var sql = new StringBuilder("CREATE TABLE ").Append(SqlServerDialect.Instance.Qualify(obj.Name)).Append(" (\n  ")
            .AppendJoin(",\n  ", parts).Append("\n);");
        foreach (var index in await QueryAsync(connection, SqlServerCatalog.IndexDefinitions, static r => r.GetString(0), cancellationToken, parameters))
        {
            sql.Append("\n\n").Append(index).Append(';');
        }

        return sql.ToString();
    }

    private Task<ResultSet> ReadResultAsync(string sql, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                await using var command = connection.CreateCommand();
                command.CommandText = sql;
                await using var reader = await command.ExecuteReaderAsync(ct);
                return await ResultSetReader.ReadAsync(reader, int.MaxValue, ct);
            },
            cancellationToken);

    private static (string, object?)[] Bind(ObjectName name) => [("@schema", SchemaOrDefault(name.Schema)), ("@table", name.Name)];

    private static string SchemaOrDefault(string? schema) => string.IsNullOrEmpty(schema) ? DefaultSchemaName : schema;

    private static InvalidOperationException NotFound(DatabaseObject obj) => new($"No definition was found for {obj.Name}.");
}
