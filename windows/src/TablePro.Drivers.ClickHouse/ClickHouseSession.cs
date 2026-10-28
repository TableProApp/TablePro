using System.Data.Common;
using System.Globalization;
using ClickHouse.Client.ADO;
using ClickHouse.Client.ADO.Parameters;
using TablePro.Core.Browse;
using TablePro.Core.Data;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.ClickHouse;

/// <summary>
/// ClickHouse over its HTTP interface. Databases are listed both as databases and as the sidebar's schemas, since the
/// engine has one namespace level and the descriptor asks for schemas.
/// </summary>
/// <remarks>
/// It declares <see cref="IDatabaseSession"/> again so its own <see cref="BrowseAsync"/>, <see cref="CountAsync"/> and
/// <see cref="SaveChangesAsync"/> replace the base class's for every caller: ClickHouse binds <c>{p0:String}</c>
/// rather than the bare names Core writes, and it has no transaction for the base save to open.
/// </remarks>
public sealed class ClickHouseSession
    : AdoNetSession, IDatabaseSession, ISchemaDdlProvider, IServerActivityProvider, IServerVariablesProvider, IUserListProvider, IDatabaseAdministration
{
    private readonly string _connectionString;
    private readonly HttpClient _httpClient;
    private readonly IReadOnlyList<string> _startupStatements;

    public ClickHouseSession(ConnectionRequest request)
        : base(request, ClickHouseDialect.Instance)
    {
        var startup = ClickHouseStartup.Parse(request.Profile.StartupCommands);
        _startupStatements = startup.Statements;
        _connectionString = ClickHouseConnectionStringFactory.Build(request, startup.Settings);
        _httpClient = new HttpClient(ClickHouseConnectionStringFactory.CreateHandler(request.Profile), disposeHandler: true)
        {
            Timeout = Timeout.InfiniteTimeSpan,
        };
    }

    public override string? DefaultSchema => CurrentDatabase ?? ClickHouseConnectionStringFactory.DefaultDatabase;

    public IReadOnlyList<string> CommonDataTypes => ClickHouseDdl.CommonDataTypes;

    public string ProcessIdColumn => "query_id";

    private string Database(string? schema) => string.IsNullOrEmpty(schema) ? DefaultSchema! : schema;

    protected override DbConnection CreateConnection() => new ClickHouseConnection(_connectionString, _httpClient);

    protected override async Task InitializeConnectionAsync(DbConnection connection, CancellationToken cancellationToken)
    {
        foreach (var statement in _startupStatements)
        {
            await using var command = connection.CreateCommand();
            command.CommandText = statement;
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
    }

    protected override Task<IReadOnlyList<string>> LoadDatabasesAsync(DbConnection connection, CancellationToken cancellationToken) =>
        QueryAsync(connection, ClickHouseCatalog.Databases, static r => r.GetString(0), cancellationToken);

    protected override Task<IReadOnlyList<string>> LoadSchemasAsync(DbConnection connection, CancellationToken cancellationToken) =>
        LoadDatabasesAsync(connection, cancellationToken);

    protected override Task<IReadOnlyList<DatabaseObject>> LoadObjectsAsync(DbConnection connection, string? schema, CancellationToken cancellationToken)
    {
        var database = Database(schema);
        return QueryAsync(
            connection,
            ClickHouseCatalog.Objects,
            r =>
            {
                var engine = r.GetString(1);
                var kind = KindOf(engine);
                var comment = NullableString(r, 3);
                long? rows = r.IsDBNull(2) ? null : Convert.ToInt64(r.GetValue(2), CultureInfo.InvariantCulture);
                return new DatabaseObject(
                    new ObjectName(database, r.GetString(0)),
                    kind,
                    kind == ObjectKind.Table ? rows : null,
                    engine == ClickHouseDdl.DictionaryMarker ? ClickHouseDdl.DictionaryMarker : string.IsNullOrEmpty(comment) ? null : comment);
            },
            cancellationToken,
            ("db", database));
    }

    internal static ObjectKind KindOf(string engine) => engine switch
    {
        "View" or "LiveView" or "WindowView" => ObjectKind.View,
        "MaterializedView" => ObjectKind.MaterializedView,
        _ => ObjectKind.Table,
    };

    protected override Task<IReadOnlyList<ColumnInfo>> LoadColumnsAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var ordinal = 0;
        return QueryAsync(
            connection,
            ClickHouseCatalog.Columns,
            r =>
            {
                var type = r.GetString(1);
                var defaultKind = NullableString(r, 2);
                var expression = NullableString(r, 3);
                var comment = NullableString(r, 4);
                return new ColumnInfo(
                    r.GetString(0),
                    type,
                    ClickHouseDdl.IsNullableType(type),

                    // MATERIALIZED, ALIAS and EPHEMERAL keep their expression in the same field, and only DEFAULT is a
                    // default; reporting the others as one would restate them as DEFAULT on the next edit.
                    defaultKind == "DEFAULT" && !string.IsNullOrEmpty(expression) ? expression : null,
                    Truthy(r, 5) || Truthy(r, 6),
                    false,
                    ordinal++,
                    string.IsNullOrEmpty(comment) ? null : comment);
            },
            cancellationToken,
            Bind(table));
    }

    protected override async Task<IReadOnlyList<IndexInfo>> LoadIndexesAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var indexes = await QueryAsync(
            connection,
            ClickHouseCatalog.Indexes,
            static r => new IndexInfo(r.GetString(0), SplitExpression(r.GetString(2)), false, Truthy(r, 3), r.GetString(1)),
            cancellationToken,
            Bind(table));
        return indexes.OrderByDescending(i => i.IsPrimary).ToArray();
    }

    // ClickHouse has no foreign keys and no triggers.
    protected override Task<IReadOnlyList<ForeignKeyInfo>> LoadForeignKeysAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<ForeignKeyInfo>>([]);

    protected override async Task<string> LoadDefinitionAsync(DbConnection connection, DatabaseObject obj, CancellationToken cancellationToken)
    {
        var qualified = obj with { Name = obj.Name with { Schema = Database(obj.Name.Schema) } };
        var rows = await QueryAsync(connection, ClickHouseDdl.ShowCreate(qualified), static r => r.GetString(0), cancellationToken);
        return rows.Count > 0 ? rows[0] : throw new InvalidOperationException($"No definition was found for {obj.Name}.");
    }

    public new Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                await using var command = CreateBoundCommand(connection, Dialect.BuildBrowse(request));
                await using var reader = await command.ExecuteReaderAsync(ct);
                return await ResultSetReader.ReadAsync(reader, request.Limit, ct);
            },
            cancellationToken);

    public new Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                await using var command = CreateBoundCommand(connection, Dialect.BuildCount(table, filter));
                var value = await command.ExecuteScalarAsync(ct);
                return Convert.ToInt64(value, CultureInfo.InvariantCulture);
            },
            cancellationToken);

    /// <summary>
    /// Applies the changes statement by statement, since ClickHouse has no transaction. Every keyed change is counted
    /// before anything is sent, so a row that moved or repeats stops the save whole. Mutations are asynchronous on the
    /// server; <c>mutations_sync=1</c> makes each statement wait for its own mutation before the next is sent.
    /// </summary>
    public new Task<int> SaveChangesAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken) =>
        WithConnectionAsync(
            async (connection, ct) =>
            {
                var target = table with { Schema = Database(table.Schema) };
                if (changes.Any(static c => c is RowUpdate))
                {
                    var keyColumns = await QueryAsync(connection, ClickHouseCatalog.KeyColumns, static r => r.GetString(0), ct, Bind(target));
                    ClickHouseMutations.EnsureMutable(changes, keyColumns);
                }

                foreach (var change in changes)
                {
                    if (ClickHouseMutations.Probe(target, change) is not { } probe)
                    {
                        continue;
                    }

                    await using var command = CreateBoundCommand(connection, probe);
                    var count = Convert.ToInt64(await command.ExecuteScalarAsync(ct), CultureInfo.InvariantCulture);
                    if (count != 1)
                    {
                        throw new RowCountMismatchException(1, (int)Math.Min(count, int.MaxValue), ClickHouseMutations.Build(target, change).Text);
                    }
                }

                var total = 0;
                foreach (var change in changes)
                {
                    await using var command = CreateBoundCommand(connection, ClickHouseMutations.Build(target, change));
                    if (change is not RowInsert)
                    {
                        command.CustomSettings["mutations_sync"] = 1;
                    }

                    await command.ExecuteNonQueryAsync(ct);
                    total++;
                }

                return total;
            },
            cancellationToken);

    public IReadOnlyList<string> BuildDdl(ObjectName table, SchemaChange change) => ClickHouseDdl.Build(table, change);

    public Task<ResultSet> GetActivityAsync(CancellationToken cancellationToken) => ReadResultAsync(ClickHouseCatalog.Activity, cancellationToken);

    public Task TerminateAsync(object processId, CancellationToken cancellationToken)
    {
        var id = Convert.ToString(processId, CultureInfo.InvariantCulture) ?? string.Empty;
        return WithConnectionAsync((connection, ct) => ScalarAsync(connection, ClickHouseCatalog.Kill, ct, ("id", id)), cancellationToken);
    }

    public Task<ResultSet> GetVariablesAsync(CancellationToken cancellationToken) => ReadResultAsync(ClickHouseCatalog.Variables, cancellationToken);

    public Task<ResultSet> GetUsersAsync(CancellationToken cancellationToken) => ReadResultAsync(ClickHouseCatalog.Users, cancellationToken);

    public string BuildCreateDatabase(string name) => ClickHouseDdl.CreateDatabase(name);

    public string BuildDropDatabase(string name) => ClickHouseDdl.DropDatabase(name);

    public override async ValueTask DisposeAsync()
    {
        _httpClient.Dispose();
        await base.DisposeAsync();
    }

    internal static IReadOnlyList<string> SplitExpression(string expression)
    {
        // A key such as (a, toDate(b)) holds commas inside calls, so only top-level commas separate columns.
        var trimmed = expression.Trim();
        if (trimmed.StartsWith('(') && trimmed.EndsWith(')') && Balanced(trimmed[1..^1]))
        {
            trimmed = trimmed[1..^1];
        }

        var parts = new List<string>();
        var depth = 0;
        var start = 0;
        for (var i = 0; i < trimmed.Length; i++)
        {
            switch (trimmed[i])
            {
                case '(':
                    depth++;
                    break;
                case ')':
                    depth--;
                    break;
                case ',' when depth == 0:
                    parts.Add(trimmed[start..i].Trim());
                    start = i + 1;
                    break;
            }
        }

        var last = trimmed[start..].Trim();
        if (last.Length > 0)
        {
            parts.Add(last);
        }

        return parts;
    }

    private static bool Balanced(string text)
    {
        var depth = 0;
        foreach (var c in text)
        {
            depth += c switch { '(' => 1, ')' => -1, _ => 0 };
            if (depth < 0)
            {
                return false;
            }
        }

        return depth == 0;
    }

    private static ClickHouseCommand CreateBoundCommand(DbConnection connection, SqlCommandSpec spec)
    {
        var bound = ClickHouseParameters.Rewrite(spec);
        var command = (ClickHouseCommand)connection.CreateCommand();
        command.CommandText = bound.Text;
        foreach (var (name, value) in bound.Parameters)
        {
            var parameter = (ClickHouseDbParameter)command.CreateParameter();
            parameter.ParameterName = name;
            parameter.ClickHouseType = ClickHouseParameters.ParameterType;
            parameter.Value = value;
            command.Parameters.Add(parameter);
        }

        return command;
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

    private (string, object?)[] Bind(ObjectName table) => [("db", Database(table.Schema)), ("table", table.Name)];
}
