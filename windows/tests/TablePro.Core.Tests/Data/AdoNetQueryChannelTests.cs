using System.Data;
using System.Data.Common;
using System.Diagnostics.CodeAnalysis;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Data;
using TablePro.Core.Drivers;
using TablePro.Core.Localization;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Data;

/// <summary>The editor channel against a scripted provider, for what a real server only does now and then.</summary>
public sealed class AdoNetQueryChannelTests
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public async Task ABrokenConnectionIsClosedAndOpenedAgain()
    {
        var connection = new ScriptedConnection(_ => Rows("x", 1));
        await using var session = new ScriptedSession(connection);
        await using var channel = await session.OpenChannelAsync(Ct);

        // What MySqlConnector does once the server ends the session: it refuses to open again until closed.
        connection.Break();
        var result = Assert.Single(await RunAsync(channel, ["SELECT 1"], Ct));

        Assert.True(result.Succeeded, result.Error);
        Assert.Equal(2, connection.Opens);
        Assert.Equal(2, session.Initialized);
    }

    [Fact]
    public async Task AStatementTheServerFinishedAfterACancelIsReportedAsCancelled()
    {
        using var cancel = CancellationTokenSource.CreateLinkedTokenSource(Ct);
        // MySQL's KILL QUERY makes SLEEP return 1 rather than fail, so the rows come back after the cancel.
        var connection = new ScriptedConnection(
            _ => Rows("x", 1),
            finished: sql =>
            {
                if (sql.StartsWith("SELECT SLEEP", StringComparison.Ordinal))
                {
                    cancel.Cancel();
                }
            });
        await using var session = new ScriptedSession(connection);
        await using var channel = await session.OpenChannelAsync(Ct);

        var results = await RunAsync(channel, ["SELECT SLEEP(30)", "SELECT 2"], cancel.Token);

        var cancelled = Assert.Single(results);
        Assert.Equal(CoreStrings.Get("Data/QueryCancelled"), cancelled.Error);
        Assert.Equal(["SELECT SLEEP(30)"], connection.Executed);

        var next = Assert.Single(await RunAsync(channel, ["SELECT 2"], Ct));
        Assert.True(next.Succeeded, next.Error);
    }

    [Fact]
    public async Task AQueryWithAnUnreadableTypeIsAskedAgainOnceTheTypesAreRead()
    {
        var connection = new ScriptedConnection(_ => Rows("mood", "happy"));
        await using var session = new ScriptedSession(connection) { UnreadableColumn = "mood" };
        await using var channel = await session.OpenChannelAsync(Ct);

        var result = Assert.Single(await RunAsync(channel, ["SELECT mood FROM t"], Ct));

        Assert.True(result.Succeeded, result.Error);
        Assert.Equal(["SELECT mood FROM t", "SELECT mood FROM t"], connection.Executed);
        Assert.Equal(1, session.Reloads);
        Assert.Equal("happy", result.ResultSets[0][0, 0]);
    }

    [Fact]
    public async Task AWriteWithAnUnreadableTypeRunsOnceAndTheTypesAreReadAfter()
    {
        var connection = new ScriptedConnection(_ => Rows("mood", "happy"));
        await using var session = new ScriptedSession(connection) { UnreadableColumn = "mood" };
        await using var channel = await session.OpenChannelAsync(Ct);

        var result = Assert.Single(await RunAsync(channel, ["INSERT INTO t VALUES ('happy') RETURNING mood"], Ct));

        Assert.True(result.Succeeded, result.Error);
        Assert.Single(connection.Executed);
        Assert.Equal(1, session.Reloads);
    }

    [Fact]
    public async Task AStatementThatChangesTypesReadsThemAgain()
    {
        var connection = new ScriptedConnection(_ => new DataTable().CreateDataReader());
        await using var session = new ScriptedSession(connection);
        await using var channel = await session.OpenChannelAsync(Ct);

        Assert.All(await RunAsync(channel, ["CREATE TYPE mood AS ENUM ('happy')", "CREATE TABLE t (id int)"], Ct), r => Assert.True(r.Succeeded, r.Error));

        Assert.Equal(1, session.Reloads);
    }

    [Fact]
    public async Task BrowseBindsThroughTheSessionsHookAndReadsAgainAfterReloadingTypes()
    {
        var connection = new ScriptedConnection(_ => Rows("mood", "happy"));
        await using var session = new ScriptedSession(connection) { UnreadableColumn = "mood" };

        var page = await session.BrowseAsync(
            new BrowseRequest(new ObjectName(null, "t"), new BrowseFilter([new FilterRule("mood", FilterOperator.Equals, "happy")]), [], 0, 10),
            Ct);

        Assert.Equal(1, page.RowCount);
        Assert.Equal(1, session.Reloads);
        Assert.Equal(2, connection.Executed.Count);
        Assert.All(connection.Commands, c => Assert.All(c.Parameters.Cast<DbParameter>(), p => Assert.Equal("bound", p.SourceColumn)));
    }

    private static DataTableReader Rows(string column, object value)
    {
        var table = new DataTable();
        table.Columns.Add(column, value.GetType());
        table.Rows.Add(value);
        return table.CreateDataReader();
    }

    private static async Task<List<StatementResult>> RunAsync(IQueryChannel channel, IReadOnlyList<string> statements, CancellationToken cancellationToken)
    {
        var results = new List<StatementResult>();
        await foreach (var result in channel.ExecuteAsync(statements, new ExecuteOptions(StopOnError: false), cancellationToken))
        {
            results.Add(result);
        }

        return results;
    }

    private sealed class ScriptedSession(ScriptedConnection connection)
        : AdoNetSession(ConnectionRequest.Direct(new ConnectionProfile { Name = "scripted", Engine = DatabaseEngine.Sqlite }, null), SqliteDialect.Instance)
    {
        private bool _typesRead;

        public string? UnreadableColumn { get; init; }

        public int Initialized { get; private set; }

        public int Reloads { get; private set; }

        protected override DbConnection CreateConnection() => connection;

        protected override Task InitializeConnectionAsync(DbConnection connection, CancellationToken cancellationToken)
        {
            Initialized++;
            return Task.CompletedTask;
        }

        protected override DbParameter CreateParameter(DbCommand command, string name, object? value)
        {
            var parameter = base.CreateParameter(command, name, value);
            parameter.SourceColumn = "bound";
            return parameter;
        }

        protected override bool HasUnreadableColumns(DbDataReader reader) =>
            !_typesRead && reader.FieldCount > 0 && reader.GetName(0) == UnreadableColumn;

        protected override Task ReloadTypesAsync(DbConnection connection, CancellationToken cancellationToken)
        {
            _typesRead = true;
            Reloads++;
            return Task.CompletedTask;
        }

        protected override bool ChangesServerTypes(string statement) => statement.StartsWith("CREATE TYPE", StringComparison.Ordinal);

        protected override Task<IReadOnlyList<string>> LoadDatabasesAsync(DbConnection connection, CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>([]);

        protected override Task<IReadOnlyList<string>> LoadSchemasAsync(DbConnection connection, CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>([]);

        protected override Task<IReadOnlyList<DatabaseObject>> LoadObjectsAsync(DbConnection connection, string? schema, CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<DatabaseObject>>([]);

        protected override Task<IReadOnlyList<ColumnInfo>> LoadColumnsAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<ColumnInfo>>([]);

        protected override Task<IReadOnlyList<IndexInfo>> LoadIndexesAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<IndexInfo>>([]);

        protected override Task<IReadOnlyList<ForeignKeyInfo>> LoadForeignKeysAsync(DbConnection connection, ObjectName table, CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<ForeignKeyInfo>>([]);

        protected override Task<string> LoadDefinitionAsync(DbConnection connection, DatabaseObject obj, CancellationToken cancellationToken) => Task.FromResult(string.Empty);
    }

    /// <summary>A connection that answers every command from a script and stays open across the session's disposals.</summary>
    private sealed class ScriptedConnection(Func<ScriptedCommand, DbDataReader> answer, Action<string>? finished = null) : DbConnection
    {
        private ConnectionState _state = ConnectionState.Closed;

        public int Opens { get; private set; }

        public List<string> Executed { get; } = [];

        public List<ScriptedCommand> Commands { get; } = [];

        [AllowNull]
        public override string ConnectionString { get; set; } = string.Empty;

        public override string Database => "main";

        public override string DataSource => "scripted";

        public override string ServerVersion => "1";

        public override ConnectionState State => _state;

        public void Break() => _state = ConnectionState.Broken;

        public override void Open()
        {
            if (_state == ConnectionState.Broken)
            {
                throw new InvalidOperationException("Cannot Open when State is Broken.");
            }

            _state = ConnectionState.Open;
            Opens++;
        }

        public override void Close() => _state = ConnectionState.Closed;

        // The session disposes a pooled connection after each browse; a pool would keep this one.
        protected override void Dispose(bool disposing)
        {
            _state = ConnectionState.Closed;
            base.Dispose(disposing);
        }

        public override void ChangeDatabase(string databaseName) => throw new NotSupportedException();

        protected override DbTransaction BeginDbTransaction(IsolationLevel isolationLevel) => throw new NotSupportedException();

        protected override DbCommand CreateDbCommand()
        {
            var command = new ScriptedCommand(this);
            Commands.Add(command);
            return command;
        }

        internal DbDataReader Answer(ScriptedCommand command)
        {
            Executed.Add(command.CommandText);
            return answer(command);
        }

        internal void Finished(ScriptedCommand command) => finished?.Invoke(command.CommandText);
    }

    internal sealed class ScriptedCommand(DbConnection connection) : DbCommand
    {
        private readonly ScriptedParameters _parameters = new();

        [AllowNull]
        public override string CommandText { get; set; } = string.Empty;

        public override int CommandTimeout { get; set; }

        public override CommandType CommandType { get; set; }

        public override bool DesignTimeVisible { get; set; }

        public override UpdateRowSource UpdatedRowSource { get; set; }

        protected override DbConnection? DbConnection { get; set; } = connection;

        protected override DbParameterCollection DbParameterCollection => _parameters;

        protected override DbTransaction? DbTransaction { get; set; }

        public override void Cancel()
        {
        }

        public override int ExecuteNonQuery() => -1;

        public override object? ExecuteScalar() => null;

        public override void Prepare()
        {
        }

        protected override DbParameter CreateDbParameter() => new ScriptedParameter();

        protected override DbDataReader ExecuteDbDataReader(CommandBehavior behavior) => ((ScriptedConnection)DbConnection!).Answer(this);

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                ((ScriptedConnection)DbConnection!).Finished(this);
            }

            base.Dispose(disposing);
        }
    }

    private sealed class ScriptedParameter : DbParameter
    {
        public override DbType DbType { get; set; }

        public override ParameterDirection Direction { get; set; }

        public override bool IsNullable { get; set; }

        [AllowNull]
        public override string ParameterName { get; set; } = string.Empty;

        [AllowNull]
        public override string SourceColumn { get; set; } = string.Empty;

        public override object? Value { get; set; }

        public override bool SourceColumnNullMapping { get; set; }

        public override int Size { get; set; }

        public override void ResetDbType()
        {
        }
    }

    private sealed class ScriptedParameters : DbParameterCollection, IEnumerable<DbParameter>
    {
        private readonly List<DbParameter> _items = [];

        public override int Count => _items.Count;

        public override object SyncRoot => _items;

        public override int Add(object value)
        {
            _items.Add((DbParameter)value);
            return _items.Count - 1;
        }

        public override void AddRange(Array values)
        {
            foreach (var value in values)
            {
                Add(value);
            }
        }

        public override void Clear() => _items.Clear();

        public override bool Contains(object value) => _items.Contains((DbParameter)value);

        public override bool Contains(string value) => _items.Exists(p => p.ParameterName == value);

        public override void CopyTo(Array array, int index) => ((System.Collections.ICollection)_items).CopyTo(array, index);

        public override System.Collections.IEnumerator GetEnumerator() => _items.GetEnumerator();

        IEnumerator<DbParameter> IEnumerable<DbParameter>.GetEnumerator() => _items.GetEnumerator();

        public override int IndexOf(object value) => _items.IndexOf((DbParameter)value);

        public override int IndexOf(string parameterName) => _items.FindIndex(p => p.ParameterName == parameterName);

        public override void Insert(int index, object value) => _items.Insert(index, (DbParameter)value);

        public override void Remove(object value) => _items.Remove((DbParameter)value);

        public override void RemoveAt(int index) => _items.RemoveAt(index);

        public override void RemoveAt(string parameterName) => _items.RemoveAt(IndexOf(parameterName));

        protected override DbParameter GetParameter(int index) => _items[index];

        protected override DbParameter GetParameter(string parameterName) => _items[IndexOf(parameterName)];

        protected override void SetParameter(int index, DbParameter value) => _items[index] = value;

        protected override void SetParameter(string parameterName, DbParameter value) => _items[IndexOf(parameterName)] = value;
    }
}
