using System.Data.Common;
using System.Globalization;
using MySqlConnector;
using TablePro.Core.Connections;
using TablePro.Core.Data;
using TablePro.Core.Drivers;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.MySql;

/// <summary>Serves MySQL and MariaDB, which share the protocol, the catalog and SHOW CREATE.</summary>
public sealed partial class MySqlSession
    : AdoNetSession, ISchemaDdlProvider, IServerActivityProvider, IUserListProvider, IDatabaseAdministration, IServerVariablesProvider
{
    private readonly MySqlDataSource _dataSource;

    // One batch, so a pooled connection costs one round trip to set up rather than one per statement.
    private readonly string? _initializeSql;

    public MySqlSession(ConnectionRequest request)
        : base(request, MySqlDialect.Instance)
    {
        var builder = new MySqlDataSourceBuilder(MySqlConnectionStringFactory.Build(request));

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
        _initializeSql = BuildInitializeSql(request.Profile.IsReadOnly, StartupCommands.Split(request.Profile.StartupCommands, Dialect));
    }

    public IReadOnlyList<string> CommonDataTypes => MySqlDdl.CommonDataTypes;

    public string ProcessIdColumn => "Id";

    private bool IsMariaDb => Profile.Engine == DatabaseEngine.MariaDb;

    /// <summary>Databend answers BEGIN but cannot roll a write back, so it keeps the table-by-table path.</summary>
    public override bool SupportsChangeTransactions => Profile.Engine != DatabaseEngine.Databend;

    public override async ValueTask DisposeAsync()
    {
        await _dataSource.DisposeAsync();
        await base.DisposeAsync();
    }

    protected override DbConnection CreateConnection() => _dataSource.CreateConnection();

    /// <summary>
    /// The pool resets session state when a connection comes back, so read-only and the startup commands are
    /// applied on every open rather than once per physical connection.
    /// </summary>
    protected override async Task InitializeConnectionAsync(DbConnection connection, CancellationToken cancellationToken)
    {
        if (_initializeSql is null)
        {
            return;
        }

        await using var command = connection.CreateCommand();
        command.CommandText = _initializeSql;
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    protected override void AttachMessages(DbConnection connection, Action<string> onMessage) =>
        ((MySqlConnection)connection).InfoMessage += (_, e) =>
        {
            foreach (var error in e.Errors)
            {
                onMessage(string.Concat(error.Level, " ", ((int)error.ErrorCode).ToString(CultureInfo.InvariantCulture), ": ", error.Message));
            }
        };

    protected override Task<IReadOnlyList<string>> LoadDatabasesAsync(DbConnection connection, CancellationToken cancellationToken) =>
        QueryAsync(connection, MySqlCatalog.Databases, static r => r.GetString(0), cancellationToken);

    // A MySQL database has no schemas below it; the sidebar lists databases instead.
    protected override Task<IReadOnlyList<string>> LoadSchemasAsync(DbConnection connection, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<string>>([]);

    protected override Task<IReadOnlyList<DatabaseObject>> LoadObjectsAsync(DbConnection connection, string? schema, CancellationToken cancellationToken)
    {
        var database = string.IsNullOrEmpty(schema) ? null : schema;
        return QueryAsync(
            connection,
            MySqlCatalog.Objects,
            r =>
            {
                var kind = r.GetString(1) switch
                {
                    "VIEW" or "SYSTEM VIEW" => ObjectKind.View,
                    "SEQUENCE" => ObjectKind.Sequence,
                    "FUNCTION" => ObjectKind.Function,
                    "PROCEDURE" => ObjectKind.Procedure,
                    _ => ObjectKind.Table,
                };
                long? estimate = kind == ObjectKind.Table && !r.IsDBNull(2) ? Convert.ToInt64(r.GetValue(2), CultureInfo.InvariantCulture) : null;
                var comment = r.IsDBNull(3) ? null : r.GetString(3);
                return new DatabaseObject(new ObjectName(database, r.GetString(0)), kind, estimate, string.IsNullOrEmpty(comment) || kind == ObjectKind.View ? null : comment);
            },
            cancellationToken,
            ("@schema", database));
    }

    protected override Task<IReadOnlyList<ColumnInfo>> LoadColumnsAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var ordinal = 0;
        return QueryAsync(
            connection,
            MySqlCatalog.Columns,
            r =>
            {
                var comment = r.IsDBNull(6) ? null : r.GetString(6);
                return new ColumnInfo(
                    r.GetString(0),
                    r.GetString(1),
                    Truthy(r, 2),
                    NullableString(r, 3),
                    Truthy(r, 4),
                    Truthy(r, 5),
                    ordinal++,
                    string.IsNullOrEmpty(comment) ? null : comment);
            },
            cancellationToken,
            Bind(table));
    }

    protected override async Task<IReadOnlyList<IndexInfo>> LoadIndexesAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var rows = await QueryAsync(
            connection,
            MySqlCatalog.Indexes,
            static r => (Name: r.GetString(0), Unique: !Truthy(r, 1), Column: r.GetString(2), Method: NullableString(r, 3)),
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
            indexes.Add(new IndexInfo(first.Name, columns, first.Unique, first.Name == "PRIMARY", first.Method));
            start = end;
        }

        return indexes;
    }

    protected override async Task<IReadOnlyList<ForeignKeyInfo>> LoadForeignKeysAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken)
    {
        var rows = await QueryAsync(
            connection,
            MySqlCatalog.ForeignKeys,
            static r => (Name: r.GetString(0), Column: r.GetString(1), Schema: r.GetString(2), ReferencedSchema: r.GetString(3),
                ReferencedTable: r.GetString(4), ReferencedColumn: r.GetString(5), OnUpdate: r.GetString(6), OnDelete: r.GetString(7)),
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

            // A parent in the same database keeps the child's own spelling, so an unqualified table stays unqualified.
            var parentSchema = string.Equals(first.ReferencedSchema, first.Schema, StringComparison.Ordinal) ? table.Schema : first.ReferencedSchema;
            keys.Add(new ForeignKeyInfo(first.Name, columns, new ObjectName(parentSchema, first.ReferencedTable), referenced, first.OnUpdate, first.OnDelete));
            start = end;
        }

        return keys;
    }

    protected override Task<IReadOnlyList<TriggerInfo>> LoadTriggersAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken) =>
        QueryAsync(
            connection,
            MySqlCatalog.Triggers,
            static r => new TriggerInfo(r.GetString(0), r.GetString(1), r.GetString(2), NullableString(r, 3)),
            cancellationToken,
            Bind(table));

    protected override async Task<string> LoadDefinitionAsync(DbConnection connection, DatabaseObject obj, CancellationToken cancellationToken)
    {
        if (MySqlDdl.ShowCreate(obj) is not var (sql, ordinal))
        {
            throw new NotSupportedException($"MySQL has no {obj.Kind} objects.");
        }

        await using var command = connection.CreateCommand();
        command.CommandText = sql;
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
        {
            throw new InvalidOperationException($"No definition was found for {obj.Name}.");
        }

        // The server answers NULL rather than an error when the account may run the routine but not read it.
        return reader.IsDBNull(ordinal)
            ? throw new InvalidOperationException($"The account cannot read the definition of {obj.Name}.")
            : reader.GetString(ordinal) + ";";
    }

    public IReadOnlyList<string> BuildDdl(ObjectName table, SchemaChange change) => MySqlDdl.Build(table, change, Server);

    public Task<ResultSet> GetActivityAsync(CancellationToken cancellationToken) => ReadResultAsync(MySqlCatalog.ProcessList, cancellationToken);

    public Task TerminateAsync(object processId, CancellationToken cancellationToken)
    {
        var sql = MySqlDdl.Kill(processId);
        return WithConnectionAsync((connection, ct) => ScalarAsync(connection, sql, ct), cancellationToken);
    }

    public Task<ResultSet> GetUsersAsync(CancellationToken cancellationToken) =>
        ReadResultAsync(IsMariaDb ? MySqlCatalog.MariaDbUsers : MySqlCatalog.MySqlUsers, cancellationToken);

    public Task<ResultSet> GetVariablesAsync(CancellationToken cancellationToken) =>
        ReadResultAsync(IsMariaDb ? MySqlCatalog.MariaDbVariables : MySqlCatalog.MySqlVariables, cancellationToken);

    public string BuildCreateDatabase(string name) => MySqlDdl.CreateDatabase(name);

    public string BuildDropDatabase(string name) => MySqlDdl.DropDatabase(name);

    internal static string? BuildInitializeSql(bool readOnly, string[] startupCommands)
    {
        var statements = new List<string>(startupCommands.Length + 1);
        if (readOnly)
        {
            statements.Add(MySqlCatalog.ReadOnlySession);
        }

        statements.AddRange(startupCommands);
        return statements.Count == 0 ? null : string.Join(";\n", statements);
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

    private static (string, object?)[] Bind(ObjectName name) =>
        [("@schema", string.IsNullOrEmpty(name.Schema) ? null : name.Schema), ("@table", name.Name)];
}
