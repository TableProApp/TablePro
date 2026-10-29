using System.Data.Common;
using System.Globalization;
using System.Text;
using Npgsql;
using TablePro.Core.Connections;
using TablePro.Core.Data;
using TablePro.Core.Drivers;
using TablePro.Core.Localization;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.PostgreSql;

public sealed partial class PostgreSqlSession
    : AdoNetSession, IDatabaseSession, ISchemaDdlProvider, IServerActivityProvider, IUserListProvider, IDatabaseAdministration, IServerVariablesProvider
{
    private const string DefaultSchemaName = "public";

    private readonly NpgsqlDataSource _dataSource;
    private readonly string[] _startupCommands;

    public PostgreSqlSession(ConnectionRequest request)
        : base(request, PostgreSqlDialect.Instance)
    {
        _startupCommands = StartupCommands.Split(request.Profile.StartupCommands, Dialect);
        var builder = new NpgsqlDataSourceBuilder(PostgreSqlConnectionStringFactory.Build(request));

        // Runs once per physical connection rather than on every pool checkout, and session state such as a
        // search_path survives the pool's DISCARD ALL only because it is reapplied here.
        if (_startupCommands.Length > 0)
        {
            builder.UsePhysicalConnectionInitializer(RunStartupCommands, RunStartupCommandsAsync);
        }

        // An IAM or Entra token lives for minutes and the pool opens connections long after the first, so the token
        // is refreshed ahead of expiry and every new physical connection signs in with a current one.
        if (request.Profile.UsesSignInToken())
        {
            var profile = request.Profile;
            var secret = request.Password;
            builder.UsePeriodicPasswordProvider(
                async (_, cancellationToken) => await SignInTokens.GetAsync(profile, secret, cancellationToken),
                SignInTokenRefresh.Interval,
                SignInTokenRefresh.RetryInterval);
        }

        _dataSource = builder.Build();
    }

    public override string? DefaultSchema => DefaultSchemaName;

    public IReadOnlyList<string> CommonDataTypes => PostgreSqlDdl.CommonDataTypes;

    public string ProcessIdColumn => "pid";

    public override async ValueTask DisposeAsync()
    {
        await _dataSource.DisposeAsync();
        await base.DisposeAsync();
    }

    protected override DbConnection CreateConnection() => _dataSource.CreateConnection();

    protected override void AttachMessages(DbConnection connection, Action<string> onMessage) =>
        ((NpgsqlConnection)connection).Notice += (_, e) => onMessage(string.Concat(e.Notice.Severity, ": ", e.Notice.MessageText));

    protected override Task<IReadOnlyList<string>> LoadDatabasesAsync(DbConnection connection, CancellationToken cancellationToken) =>
        QueryAsync(connection, PostgreSqlCatalog.Databases, static r => r.GetString(0), cancellationToken);

    protected override Task<IReadOnlyList<string>> LoadSchemasAsync(DbConnection connection, CancellationToken cancellationToken) =>
        QueryAsync(connection, PostgreSqlCatalog.Schemas, static r => r.GetString(0), cancellationToken);

    protected override Task<IReadOnlyList<DatabaseObject>> LoadObjectsAsync(DbConnection connection, string? schema, CancellationToken cancellationToken)
    {
        var resolved = SchemaOrDefault(schema);
        return QueryAsync(
            connection,
            PostgreSqlCatalog.Objects,
            r =>
            {
                var kind = r.GetString(1) switch
                {
                    "v" => ObjectKind.View,
                    "m" => ObjectKind.MaterializedView,
                    "S" => ObjectKind.Sequence,
                    "F" => ObjectKind.Function,
                    "P" => ObjectKind.Procedure,
                    _ => ObjectKind.Table,
                };
                long? estimate = kind is ObjectKind.Table or ObjectKind.MaterializedView && !r.IsDBNull(2) ? r.GetInt64(2) : null;
                return new DatabaseObject(new ObjectName(resolved, r.GetString(0)), kind, estimate, r.IsDBNull(3) ? null : r.GetString(3));
            },
            cancellationToken,
            ("@schema", resolved));
    }

    protected override Task<IReadOnlyList<ColumnInfo>> LoadColumnsAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var ordinal = 0;
        return QueryAsync(
            connection,
            PostgreSqlCatalog.Columns,
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

    protected override Task<IReadOnlyList<IndexInfo>> LoadIndexesAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken) =>
        QueryAsync(
            connection,
            PostgreSqlCatalog.Indexes,
            static r => new IndexInfo(r.GetString(0), r.GetFieldValue<string[]>(4), r.GetBoolean(1), r.GetBoolean(2), r.GetString(3)),
            cancellationToken,
            Bind(table));

    protected override Task<IReadOnlyList<ForeignKeyInfo>> LoadForeignKeysAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken) =>
        QueryAsync(
            connection,
            PostgreSqlCatalog.ForeignKeys,
            static r => new ForeignKeyInfo(
                r.GetString(0),
                r.GetFieldValue<string[]>(1),
                new ObjectName(r.GetString(2), r.GetString(3)),
                r.GetFieldValue<string[]>(4),
                PostgreSqlDdl.ReferentialAction(r.GetString(5)),
                PostgreSqlDdl.ReferentialAction(r.GetString(6))),
            cancellationToken,
            Bind(table));

    protected override Task<IReadOnlyList<TriggerInfo>> LoadTriggersAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken) =>
        QueryAsync(
            connection,
            PostgreSqlCatalog.Triggers,
            static r =>
            {
                var type = r.GetInt16(1);
                return new TriggerInfo(r.GetString(0), TriggerTiming(type), TriggerEvents(type), r.GetString(2));
            },
            cancellationToken,
            Bind(table));

    protected override async Task<string> LoadDefinitionAsync(DbConnection connection, DatabaseObject obj, CancellationToken cancellationToken)
    {
        var parameters = Bind(obj.Name);
        switch (obj.Kind)
        {
            case ObjectKind.View or ObjectKind.MaterializedView:
                return await ViewDefinitionAsync(connection, obj, parameters, cancellationToken);
            case ObjectKind.Function or ObjectKind.Procedure:
                var routines = await QueryAsync(connection, PostgreSqlCatalog.RoutineDefinitions, static r => r.GetString(0).TrimEnd(), cancellationToken, parameters);
                return routines.Count > 0 ? string.Join(";\n\n", routines) + ";" : throw NotFound(obj);
            case ObjectKind.Sequence:
                var sequences = await QueryAsync(
                    connection,
                    PostgreSqlCatalog.SequenceDefinition,
                    r => PostgreSqlDdl.Sequence(
                        Dialect.Qualify(obj.Name), r.GetString(0), r.GetInt64(1), r.GetInt64(2), r.GetInt64(3), r.GetInt64(4), r.GetInt64(5), r.GetBoolean(6)),
                    cancellationToken,
                    parameters);
                return sequences.Count > 0 ? sequences[0] : throw NotFound(obj);
            case ObjectKind.Trigger:
                return await ScalarAsync(connection, PostgreSqlCatalog.TriggerDefinition, cancellationToken, parameters) is string trigger
                    ? trigger + ";"
                    : throw NotFound(obj);
            default:
                return await TableDefinitionAsync(connection, obj, parameters, cancellationToken);
        }
    }

    public IReadOnlyList<string> BuildDdl(ObjectName table, SchemaChange change) =>
        PostgreSqlDdl.Build(table.Schema is null ? table with { Schema = DefaultSchemaName } : table, change);

    public Task<ResultSet> GetActivityAsync(CancellationToken cancellationToken) => ReadResultAsync(PostgreSqlCatalog.Activity, cancellationToken);

    public Task TerminateAsync(object processId, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            (connection, ct) => ScalarAsync(connection, PostgreSqlCatalog.Terminate, ct, ("@pid", Convert.ToInt32(processId, CultureInfo.InvariantCulture))),
            cancellationToken);

    public Task<ResultSet> GetUsersAsync(CancellationToken cancellationToken) => ReadResultAsync(PostgreSqlCatalog.Users, cancellationToken);

    public Task<ResultSet> GetVariablesAsync(CancellationToken cancellationToken) => ReadResultAsync(PostgreSqlCatalog.Settings, cancellationToken);

    public string BuildCreateDatabase(string name) => PostgreSqlDdl.CreateDatabase(name);

    public string BuildDropDatabase(string name) => PostgreSqlDdl.DropDatabase(name);

    private async Task<string> TableDefinitionAsync(DbConnection connection, DatabaseObject obj, (string, object?)[] parameters, CancellationToken cancellationToken)
    {
        var relations = await QueryAsync(connection, PostgreSqlCatalog.RelationKind, static r => (Kind: r.GetString(0), PartitionKey: r.IsDBNull(1) ? null : r.GetString(1)), cancellationToken, parameters);
        if (relations.Count == 0)
        {
            throw NotFound(obj);
        }

        var (kind, partitionKey) = relations[0];
        if (kind is "v" or "m")
        {
            return await ViewDefinitionAsync(connection, obj, parameters, cancellationToken);
        }

        var parts = new List<string>(await QueryAsync(connection, PostgreSqlCatalog.ColumnDefinitions, static r => r.GetString(0), cancellationToken, parameters));
        parts.AddRange(await QueryAsync(connection, PostgreSqlCatalog.ConstraintDefinitions, static r => r.GetString(0), cancellationToken, parameters));

        var sql = new StringBuilder("CREATE ").Append(kind == "f" ? "FOREIGN TABLE " : "TABLE ").Append(Dialect.Qualify(obj.Name)).Append(" (\n  ")
            .AppendJoin(",\n  ", parts).Append("\n)");
        if (partitionKey is not null)
        {
            sql.Append(" PARTITION BY ").Append(partitionKey);
        }

        sql.Append(';');
        await AppendStatementsAsync(sql, connection, PostgreSqlCatalog.StandaloneIndexDefinitions, parameters, cancellationToken);
        await AppendStatementsAsync(sql, connection, PostgreSqlCatalog.CommentStatements, parameters, cancellationToken);
        return sql.ToString();
    }

    private async Task<string> ViewDefinitionAsync(DbConnection connection, DatabaseObject obj, (string, object?)[] parameters, CancellationToken cancellationToken)
    {
        var views = await QueryAsync(connection, PostgreSqlCatalog.ViewDefinition, static r => (Kind: r.GetString(0), Body: r.GetString(1)), cancellationToken, parameters);
        if (views.Count == 0)
        {
            throw NotFound(obj);
        }

        var (kind, body) = views[0];
        var sql = new StringBuilder(kind == "m" ? "CREATE MATERIALIZED VIEW " : "CREATE OR REPLACE VIEW ")
            .Append(Dialect.Qualify(obj.Name)).Append(" AS\n").Append(body.TrimEnd().TrimEnd(';')).Append(';');
        if (kind == "m")
        {
            await AppendStatementsAsync(sql, connection, PostgreSqlCatalog.StandaloneIndexDefinitions, parameters, cancellationToken);
        }

        await AppendStatementsAsync(sql, connection, PostgreSqlCatalog.CommentStatements, parameters, cancellationToken);
        return sql.ToString();
    }

    private static async Task AppendStatementsAsync(StringBuilder sql, DbConnection connection, string query, (string, object?)[] parameters, CancellationToken cancellationToken)
    {
        foreach (var statement in await QueryAsync(connection, query, static r => r.GetString(0), cancellationToken, parameters))
        {
            sql.Append("\n\n").Append(statement).Append(';');
        }
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

    private void RunStartupCommands(NpgsqlConnection connection)
    {
        foreach (var sql in _startupCommands)
        {
            using var command = new NpgsqlCommand(sql, connection);
            command.ExecuteNonQuery();
        }
    }

    private async Task RunStartupCommandsAsync(NpgsqlConnection connection)
    {
        foreach (var sql in _startupCommands)
        {
            await using var command = new NpgsqlCommand(sql, connection);
            await command.ExecuteNonQueryAsync();
        }
    }

    // tgtype bits, from PostgreSQL's pg_trigger.h: 2 BEFORE, 64 INSTEAD; 4 INSERT, 8 DELETE, 16 UPDATE, 32 TRUNCATE.
    internal static string TriggerTiming(short type) => (type & 64) != 0 ? "INSTEAD OF" : (type & 2) != 0 ? "BEFORE" : "AFTER";

    internal static string TriggerEvents(short type)
    {
        var events = new List<string>(4);
        if ((type & 4) != 0)
        {
            events.Add("INSERT");
        }

        if ((type & 16) != 0)
        {
            events.Add("UPDATE");
        }

        if ((type & 8) != 0)
        {
            events.Add("DELETE");
        }

        if ((type & 32) != 0)
        {
            events.Add("TRUNCATE");
        }

        return string.Join(" OR ", events);
    }

    private static (string, object?)[] Bind(ObjectName name) => [("@schema", SchemaOrDefault(name.Schema)), ("@table", name.Name)];

    private static string SchemaOrDefault(string? schema) => string.IsNullOrEmpty(schema) ? DefaultSchemaName : schema;

    private static InvalidOperationException NotFound(DatabaseObject obj) => new(CoreStrings.Format("Driver/NoDefinitionFor", obj.Name));
}
