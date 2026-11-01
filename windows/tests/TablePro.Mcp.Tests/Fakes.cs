using System.Runtime.CompilerServices;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using TablePro.Mcp.Audit;
using TablePro.Mcp.Auth;

namespace TablePro.Mcp.Tests;

/// <summary>A clock tests move by hand, in UTC so local and universal times agree.</summary>
internal sealed class ManualTime(DateTimeOffset start) : TimeProvider
{
    private DateTimeOffset _now = start;

    public ManualTime()
        : this(new DateTimeOffset(2026, 10, 28, 12, 0, 0, TimeSpan.Zero))
    {
    }

    public override TimeZoneInfo LocalTimeZone => TimeZoneInfo.Utc;

    public override DateTimeOffset GetUtcNow() => _now;

    public void Advance(TimeSpan by) => _now += by;
}

internal sealed class FakeHost : IMcpHost
{
    public Func<McpPairingRequest, CancellationToken, Task<McpPairingApproval?>> ApprovePairing { get; set; } =
        (_, _) => Task.FromResult<McpPairingApproval?>(null);

    public List<McpPairingRequest> PairingRequests { get; } = [];

    /// <summary>The saved grants, as a credential vault and file would hold them.</summary>
    public Dictionary<Guid, McpClientGrant> SavedClients { get; } = [];

    public int ClientSaves { get; private set; }

    public List<McpAuditEntry> Audit { get; } = [];

    public Task<McpPairingApproval?> RequestPairingApprovalAsync(McpPairingRequest request, CancellationToken cancellationToken)
    {
        lock (_lock)
        {
            PairingRequests.Add(request);
        }

        return ApprovePairing(request, cancellationToken);
    }

    public Exception? AuditFailure { get; init; }

    public Exception? ClientsFailure { get; init; }

    public int AuditAttempts { get; private set; }

    public ValueTask<IReadOnlyList<McpClientGrant>> LoadClientsAsync(CancellationToken cancellationToken)
    {
        if (ClientsFailure is { } failure)
        {
            throw failure;
        }

        lock (_lock)
        {
            return ValueTask.FromResult<IReadOnlyList<McpClientGrant>>([.. SavedClients.Values]);
        }
    }

    public ValueTask SaveClientAsync(McpClientGrant client, CancellationToken cancellationToken)
    {
        lock (_lock)
        {
            SavedClients[client.Id] = client;
            ClientSaves++;
        }

        return ValueTask.CompletedTask;
    }

    public ValueTask DeleteClientAsync(Guid clientId, CancellationToken cancellationToken)
    {
        lock (_lock)
        {
            SavedClients.Remove(clientId);
        }

        return ValueTask.CompletedTask;
    }

    public ValueTask RecordAuditAsync(McpAuditEntry entry, CancellationToken cancellationToken)
    {
        lock (_lock)
        {
            AuditAttempts++;
            if (AuditFailure is { } failure)
            {
                throw failure;
            }

            Audit.Add(entry);
        }

        return ValueTask.CompletedTask;
    }

    private readonly Lock _lock = new();

    public List<ConnectionProfile> Profiles { get; } = [];

    public Dictionary<Guid, FakeSession> Sessions { get; } = [];

    public Func<McpWriteApprovalRequest, CancellationToken, Task<bool>> Approve { get; set; } = (_, _) => Task.FromResult(false);

    public Func<Guid, McpOpenResult> Open { get; set; } = _ => McpOpenResult.Failed();

    public List<McpWriteApprovalRequest> ApprovalRequests { get; } = [];

    public List<McpHistoryEntry> History { get; } = [];

    public FakeSession Add(ConnectionProfile profile, bool open = true)
    {
        Profiles.Add(profile);
        var session = new FakeSession(profile);
        if (open)
        {
            Sessions[profile.Id] = session;
        }

        return session;
    }

    public Exception? ProfilesFailure { get; set; }

    public ValueTask<IReadOnlyList<ConnectionProfile>> GetProfilesAsync(CancellationToken cancellationToken)
    {
        if (ProfilesFailure is { } failure)
        {
            throw failure;
        }

        lock (_lock)
        {
            return ValueTask.FromResult<IReadOnlyList<ConnectionProfile>>([.. Profiles]);
        }
    }

    public IDatabaseSession? GetOpenSession(Guid connectionId)
    {
        lock (_lock)
        {
            return Sessions.GetValueOrDefault(connectionId);
        }
    }

    public Task<McpOpenResult> OpenSessionAsync(Guid connectionId, CancellationToken cancellationToken) => Task.FromResult(Open(connectionId));

    public Task<bool> RequestWriteApprovalAsync(McpWriteApprovalRequest request, CancellationToken cancellationToken)
    {
        lock (_lock)
        {
            ApprovalRequests.Add(request);
        }

        return Approve(request, cancellationToken);
    }

    public ValueTask RecordHistoryAsync(McpHistoryEntry entry, CancellationToken cancellationToken)
    {
        lock (_lock)
        {
            History.Add(entry);
        }

        return ValueTask.CompletedTask;
    }

    public void Replace(ConnectionProfile profile)
    {
        lock (_lock)
        {
            var index = Profiles.FindIndex(p => p.Id == profile.Id);
            Profiles[index] = profile;
        }
    }
}

internal sealed class FakeSession(ConnectionProfile profile) : IDatabaseSession
{
    public ConnectionProfile Profile { get; } = profile;

    public SqlDialect Dialect => SqlDialects.For(Profile.Engine);

    public string ServerVersion => "16.4";

    public string? CurrentDatabase => "shop";

    public string? DefaultSchema { get; set; } = "public";

    public List<DatabaseObject> Objects { get; } = [];

    public Dictionary<ObjectName, TableStructure> Structures { get; } = [];

    public List<BrowseRequest> BrowseRequests { get; } = [];

    public List<FakeChannel> Channels { get; } = [];

    /// <summary>What each statement a channel runs produces. The default is one empty result set.</summary>
    public Func<string, ExecuteOptions, StatementResult> Execute { get; set; } =
        (sql, _) => new StatementResult(sql, [new ResultSet([new ResultColumn("n", "int", typeof(int))], [[1]])], -1, TimeSpan.FromMilliseconds(1));

    public IEnumerable<string> Executed => Channels.SelectMany(c => c.Statements);

    /// <summary>Awaited before each statement, so a test can hold one until its token fires.</summary>
    public Func<CancellationToken, Task>? Delay { get; set; }

    public void AddTable(TableStructure structure, ObjectKind kind = ObjectKind.Table)
    {
        Structures[structure.Table] = structure;
        Objects.Add(new DatabaseObject(structure.Table, kind, 42));
    }

    public Task PingAsync(CancellationToken cancellationToken) => Task.CompletedTask;

    public Task<IReadOnlyList<string>> GetDatabasesAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>(["shop"]);

    public Task<IReadOnlyList<string>> GetSchemasAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>(["public", "sales"]);

    public Task<IReadOnlyList<DatabaseObject>> GetObjectsAsync(string? schema, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<DatabaseObject>>([.. Objects.Where(o => schema is null || o.Name.Schema == schema)]);

    public Task<TableStructure> GetStructureAsync(ObjectName table, CancellationToken cancellationToken) =>
        Task.FromResult(Structures.TryGetValue(table, out var s) ? s : new TableStructure(table, [], [], [], []));

    public Task<string> GetDefinitionAsync(DatabaseObject obj, CancellationToken cancellationToken) =>
        Task.FromResult($"CREATE {(obj.Kind == ObjectKind.View ? "VIEW" : "TABLE")} {obj.Name} (...)");

    public Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken)
    {
        BrowseRequests.Add(request);
        var rows = Enumerable.Range(0, request.Limit + 5).Select(i => new object?[] { (long)i, $"name {i}" }).ToList();
        return Task.FromResult(new ResultSet([new ResultColumn("id", "bigint", typeof(long)), new ResultColumn("name", "text", typeof(string))], rows));
    }

    public Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken) => Task.FromResult(1234L);

    public Task<int> SaveChangesAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken) =>
        throw new NotSupportedException();

    public Task<IQueryChannel> OpenChannelAsync(CancellationToken cancellationToken)
    {
        var channel = new FakeChannel(this);
        lock (Channels)
        {
            Channels.Add(channel);
        }

        return Task.FromResult<IQueryChannel>(channel);
    }

    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}

internal sealed class FakeChannel(FakeSession session) : IQueryChannel
{
    public List<string> Statements { get; } = [];

    public List<ExecuteOptions> Options { get; } = [];

    public bool Disposed { get; private set; }

    public async IAsyncEnumerable<StatementResult> ExecuteAsync(IReadOnlyList<string> statements, ExecuteOptions options, [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        foreach (var sql in statements)
        {
            await Task.Yield();
            if (session.Delay is { } delay)
            {
                await delay(cancellationToken);
            }

            Statements.Add(sql);
            Options.Add(options);
            var result = session.Execute(sql, options);
            yield return result;
            if (!result.Succeeded && options.StopOnError)
            {
                yield break;
            }
        }
    }

    public ValueTask DisposeAsync()
    {
        Disposed = true;
        return ValueTask.CompletedTask;
    }
}
