using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using StackExchange.Redis;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.Redis;

/// <summary>
/// One Redis deployment over one multiplexed connection: a single server, the primary Sentinel names, or every node of
/// a cluster. The sidebar, key tabs, saves and every editor tab share it; each call names its logical database, so a
/// tab's <c>SELECT</c> never moves anyone else.
/// </summary>
public sealed partial class RedisSession : IDatabaseSession, IKeySearchProvider, IKeyBrowseProvider, IServerActivityProvider, IServerVariablesProvider, ISchemaDdlProvider, IChangePreviewProvider
{
    /// <summary>How many keys the sidebar lists before it asks for a search instead.</summary>
    public const int SidebarKeyLimit = 5_000;

    private const int ScanCount = 1_000;
    private const int DescribeBatch = 500;
    private const int FallbackDatabaseCount = 16;

    // A MATCH that hits little walks the whole keyspace; past this the search reports what it found as partial.
    private static readonly TimeSpan SearchBudget = TimeSpan.FromSeconds(5);

    private readonly ConnectionMultiplexer _connection;
    private readonly ConnectionMultiplexer? _sentinel;
    private readonly RedisScanPager _pager = new();
    private readonly ConcurrentDictionary<(int Database, string Key), (long Offset, string NextId)> _streamPositions = new();

    // The type each opened key had when last read, so the save review can show its commands without a round trip.
    private readonly ConcurrentDictionary<(int Database, string Key), RedisKeyType> _browsedTypes = new();
    private readonly RedisSignInPassword? _signIn;

    private RedisSession(ConnectionRequest request, ConnectionMultiplexer connection, ConnectionMultiplexer? sentinel, int database, string serverVersion, bool isCluster, RedisSignInPassword? signIn)
    {
        Profile = request.Profile;
        _connection = connection;
        _sentinel = sentinel;
        _signIn = signIn;
        DatabaseIndex = database;
        ServerVersion = serverVersion;
        IsCluster = isCluster;
    }

    public ConnectionProfile Profile { get; }

    public SqlDialect Dialect => RedisDialect.Instance;

    public string ServerVersion { get; }

    /// <summary>The logical database the connection opened on, also what a new editor tab starts in.</summary>
    public int DatabaseIndex { get; }

    /// <summary>Whether the keyspace is spread over the primaries of a Redis Cluster, which serves database 0 only.</summary>
    public bool IsCluster { get; }

    public string? CurrentDatabase => RedisConnectionOptions.SchemaName(DatabaseIndex);

    public string? DefaultSchema => RedisConnectionOptions.SchemaName(DatabaseIndex);

    public string ProcessIdColumn => "id";

    public IReadOnlyList<string> CommonDataTypes => [];

    /// <summary>The separator the sidebar's key tree splits names at; the macOS default <c>:</c> when the profile names none.</summary>
    public string KeySeparator => RedisTopologyKeys.ReadSeparator(Profile.AdditionalOptions);

    internal ConnectionMultiplexer Connection => _connection;

    internal static async Task<RedisSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var signIn = request.Profile.UsesSignInToken() ? await RedisSignInPassword.StartAsync(request, cancellationToken) : null;
        try
        {
            return await ConnectAsync(request, signIn, cancellationToken);
        }
        catch
        {
            if (signIn is not null)
            {
                await signIn.DisposeAsync();
            }

            throw;
        }
    }

    private static async Task<RedisSession> ConnectAsync(ConnectionRequest request, RedisSignInPassword? signIn, CancellationToken cancellationToken)
    {
        var plan = RedisConnectionOptions.Plan(request, signIn);
        ConnectionMultiplexer? sentinel = null;
        ConnectionMultiplexer connection;
        try
        {
            if (plan.Sentinel is { } sentinelOptions)
            {
                // The Sentinel connection stays open beside the data one: it is how the library hears of a failover
                // and moves the data connection to the new primary.
                sentinel = await LandAsync(ConnectionMultiplexer.SentinelConnectAsync(sentinelOptions), cancellationToken);
                var sentinels = sentinel;
                connection = await LandAsync(Task.Run(() => sentinels.GetSentinelMasterConnection(plan.Data), CancellationToken.None), cancellationToken);
            }
            else
            {
                connection = await LandAsync(ConnectionMultiplexer.ConnectAsync(plan.Data), cancellationToken);
            }
        }
        catch
        {
            sentinel?.Dispose();
            throw;
        }

        try
        {
            var home = HomeServer(connection);
            string? info = null;
            try
            {
                info = (await home.ExecuteAsync("INFO", "server").WaitAsync(cancellationToken)).ToString();
            }
            catch (RedisServerException)
            {
                // A login that may not run INFO still connects; the library's own reading of the server stands in.
            }

            var actual = RedisTopologyDiagnostics.ModeFromInfo(info) ?? home.ServerType switch
            {
                ServerType.Cluster => RedisConnectionMode.Cluster,
                ServerType.Sentinel => RedisConnectionMode.Sentinel,
                _ => RedisConnectionMode.Standalone,
            };
            if (RedisTopologyDiagnostics.Mismatch(plan.RequestedMode, actual, plan.Tunneled) is { } mismatch)
            {
                throw new InvalidOperationException(mismatch);
            }

            var isCluster = actual == RedisConnectionMode.Cluster;
            return new RedisSession(request, connection, sentinel, isCluster ? 0 : plan.Data.DefaultDatabase ?? 0, VersionFromInfo(info), isCluster, signIn);
        }
        catch
        {
            await connection.DisposeAsync();
            if (sentinel is not null)
            {
                await sentinel.DisposeAsync();
            }

            throw;
        }
    }

    /// <summary>The library has no cancellation of its own; a connection that lands after a cancel is closed so nothing leaks.</summary>
    private static async Task<ConnectionMultiplexer> LandAsync(Task<ConnectionMultiplexer> connecting, CancellationToken cancellationToken)
    {
        try
        {
            return await connecting.WaitAsync(cancellationToken);
        }
        catch (OperationCanceledException)
        {
            _ = connecting.ContinueWith(static t => t.Result.Dispose(), CancellationToken.None, TaskContinuationOptions.OnlyOnRanToCompletion, TaskScheduler.Default);
            throw;
        }
    }

    internal static string VersionFromInfo(string? info)
    {
        if (RedisServerText.InfoValue(info, "valkey_version") is { Length: > 0 } valkey)
        {
            return "Valkey " + valkey;
        }

        return RedisServerText.InfoValue(info, "redis_version") ?? string.Empty;
    }

    internal IDatabase Database(int index) => _connection.GetDatabase(index);

    internal int ResolveDatabase(string? schema) =>
        RedisConnectionOptions.TryParseDatabaseIndex(schema, out var index) ? index : DatabaseIndex;

    /// <summary>The primaries, in a stable order: every node a keyless command over the keyspace has to reach.</summary>
    internal IReadOnlyList<IServer> Primaries() => Primaries(_connection);

    /// <summary>Every connected node, replicas included.</summary>
    internal IReadOnlyList<IServer> Nodes() =>
        _connection.GetServers().Where(s => s.IsConnected).OrderBy(s => EndPointCollection.ToString(s.EndPoint), StringComparer.Ordinal).ToArray();

    /// <summary>
    /// The node the dashboard and keyless single-node commands talk to. It is always the same one, so a client listed
    /// by CLIENT LIST is killed on the node that listed it, as on macOS, where the panels describe one primary.
    /// </summary>
    internal IServer Home => HomeServer(_connection);

    private static IServer[] Primaries(ConnectionMultiplexer connection)
    {
        var servers = connection.GetServers().Where(s => s.IsConnected).OrderBy(s => EndPointCollection.ToString(s.EndPoint), StringComparer.Ordinal).ToArray();
        var primaries = servers.Where(s => !s.IsReplica).ToArray();

        // A connection to a lone replica has no primary, and the replica is what there is to read.
        return primaries.Length > 0 ? primaries : servers;
    }

    private static IServer HomeServer(ConnectionMultiplexer connection)
    {
        var primaries = Primaries(connection);
        if (primaries.Length > 0)
        {
            return primaries[0];
        }

        var servers = connection.GetServers();
        return servers.Length > 0 ? servers[0] : throw new InvalidOperationException("No Redis server is connected.");
    }

    public async Task PingAsync(CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        await Database(DatabaseIndex).PingAsync().WaitAsync(cancellationToken);
    }

    /// <summary>Redis has no databases above its numbered ones, which the sidebar lists as schemas.</summary>
    public Task<IReadOnlyList<string>> GetDatabasesAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>([]);

    public async Task<IReadOnlyList<string>> GetSchemasAsync(CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        if (IsCluster)
        {
            return [RedisConnectionOptions.SchemaName(0)];
        }

        var db = Database(DatabaseIndex);
        var configTask = TryExecuteAsync(db, "CONFIG", "GET", "databases");
        var keyspaceTask = TryExecuteAsync(db, "INFO", "keyspace");
        await Task.WhenAll(configTask, keyspaceTask).WaitAsync(cancellationToken);
        return ListDatabases(DatabaseCount(await configTask), (await keyspaceTask)?.Text, DatabaseIndex);
    }

    /// <summary>The <c>databases</c> setting from a <c>CONFIG GET databases</c> reply, or null when it was refused.</summary>
    internal static int? DatabaseCount(RedisReply? config)
    {
        if (config is null || config.Items.Count < 2)
        {
            return null;
        }

        return int.TryParse(config.Items[1].Text, NumberStyles.None, CultureInfo.InvariantCulture, out var count) && count > 0 ? count : null;
    }

    /// <summary>
    /// Every database when the server says how many it has. A login that may not read CONFIG sees the databases INFO
    /// lists as holding keys, and the one it is in; with neither answer, the default sixteen.
    /// </summary>
    internal static IReadOnlyList<string> ListDatabases(int? count, string? keyspaceInfo, int current)
    {
        if (count is { } n)
        {
            return Enumerable.Range(0, Math.Max(n, current + 1)).Select(RedisConnectionOptions.SchemaName).ToArray();
        }

        if (keyspaceInfo is null)
        {
            return Enumerable.Range(0, Math.Max(FallbackDatabaseCount, current + 1)).Select(RedisConnectionOptions.SchemaName).ToArray();
        }

        return RedisServerText.ParseKeyspace(keyspaceInfo).Keys
            .Append(current)
            .Distinct()
            .Order()
            .Select(RedisConnectionOptions.SchemaName)
            .ToArray();
    }

    public async Task<IReadOnlyList<DatabaseObject>> GetObjectsAsync(string? schema, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var index = ResolveDatabase(schema);
        var countTask = TryKeyCountAsync(index, cancellationToken);
        var (keys, _) = await ScanKeysAsync(index, null, SidebarKeyLimit, cancellationToken);
        var described = await DescribeKeysAsync(index, keys, cancellationToken);

        // The database itself comes first, as the table of all its keys that macOS opens a database as.
        var objects = new List<DatabaseObject>(described.Count + 1)
        {
            new(RedisKeyBrowse.TableName(index), ObjectKind.Table, await countTask),
        };
        objects.AddRange(described);
        return objects;
    }

    public async Task<KeySearchResult> SearchKeysAsync(string? database, string pattern, int limit, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var index = ResolveDatabase(database);
        var match = string.IsNullOrWhiteSpace(pattern) ? null : pattern.Trim();
        var (keys, truncated) = await ScanKeysAsync(index, match, Math.Max(1, limit), cancellationToken);
        return new KeySearchResult(await DescribeKeysAsync(index, keys, cancellationToken), truncated);
    }

    /// <summary>
    /// Walks the keyspace with SCAN, never KEYS, which would hold the server for the whole keyspace. A cluster's
    /// keyspace is the union of its primaries', each walked with a cursor of its own.
    /// </summary>
    private async Task<(List<string> Keys, bool Truncated)> ScanKeysAsync(int index, string? pattern, int limit, CancellationToken cancellationToken)
    {
        var db = Database(index);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var keys = new List<string>();
        var clock = Stopwatch.StartNew();
        var args = pattern is null ? new object[] { "0", "COUNT", ScanCount } : ["0", "MATCH", pattern, "COUNT", ScanCount];
        IServer?[] targets = IsCluster ? [.. Primaries()] : [null];
        foreach (var server in targets)
        {
            var cursor = "0";
            do
            {
                cancellationToken.ThrowIfCancellationRequested();
                args[0] = cursor;
                var pending = server is null ? db.ExecuteAsync("SCAN", args) : server.ExecuteAsync(index, "SCAN", args, CommandFlags.None);
                var reply = RedisReply.From(await pending.WaitAsync(cancellationToken));
                if (reply.Items.Count < 2)
                {
                    break;
                }

                cursor = reply.Items[0].Text ?? "0";
                foreach (var item in reply.Items[1].Items)
                {
                    // SCAN may return a key twice while the server rehashes.
                    if (item.Text is { } key && seen.Add(key))
                    {
                        if (keys.Count == limit)
                        {
                            return (Sorted(keys), true);
                        }

                        keys.Add(key);
                    }
                }

                if (pattern is not null && clock.Elapsed > SearchBudget && cursor != "0")
                {
                    return (Sorted(keys), true);
                }
            }
            while (cursor != "0");
        }

        return (Sorted(keys), false);

        static List<string> Sorted(List<string> list)
        {
            list.Sort(StringComparer.Ordinal);
            return list;
        }
    }

    /// <summary>Each key's type and length, pipelined: one round trip for the types of a batch, one for their lengths.</summary>
    private async Task<IReadOnlyList<DatabaseObject>> DescribeKeysAsync(int index, List<string> keys, CancellationToken cancellationToken)
    {
        var db = Database(index);
        var schema = RedisConnectionOptions.SchemaName(index);
        var objects = new List<DatabaseObject>(keys.Count);
        for (var start = 0; start < keys.Count; start += DescribeBatch)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var count = Math.Min(DescribeBatch, keys.Count - start);
            var typeTasks = new Task<RedisReply?>[count];
            for (var i = 0; i < count; i++)
            {
                typeTasks[i] = TryExecuteAsync(db, "TYPE", Key(keys[start + i]));
            }

            await Task.WhenAll(typeTasks).WaitAsync(cancellationToken);
            var lengthTasks = new Task<RedisReply?>?[count];
            for (var i = 0; i < count; i++)
            {
                var type = RedisKeyTypes.Parse(typeTasks[i].Result?.Text);
                if (RedisKeyTypes.LengthCommand(type) is { } command)
                {
                    lengthTasks[i] = TryExecuteAsync(db, command, Key(keys[start + i]));
                }
            }

            await Task.WhenAll(lengthTasks.OfType<Task<RedisReply?>>()).WaitAsync(cancellationToken);
            for (var i = 0; i < count; i++)
            {
                var typeName = typeTasks[i].Result?.Text;
                var type = RedisKeyTypes.Parse(typeName);
                if (type == RedisKeyType.None && typeName is not null)
                {
                    // Expired or deleted since the scan saw it.
                    continue;
                }

                long? length = type == RedisKeyType.String ? 1 : null;
                if (lengthTasks[i]?.Result?.Text is { } text && long.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var parsed))
                {
                    length = parsed;
                }

                // A key the ACL lets the login list but not read keeps its place, typed as unknown.
                objects.Add(new DatabaseObject(new ObjectName(schema, keys[start + i]), ObjectKind.Key, length, typeName ?? "unknown"));
            }
        }

        return objects;
    }

    public async Task<TableStructure> GetStructureAsync(ObjectName table, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        if (RedisKeyBrowse.IsKeyTable(table, out _))
        {
            return new TableStructure(table, RedisKeyBrowse.StructureColumns(), [new IndexInfo("key", [RedisKeyBrowse.Key], IsUnique: true, IsPrimary: true)], [], []);
        }

        var type = await KeyTypeAsync(ResolveDatabase(table.Schema), table.Name, cancellationToken);
        if (type == RedisKeyType.None)
        {
            throw new InvalidOperationException($"The key '{table.Name}' no longer exists.");
        }

        var columns = RedisKeyLayout.StructureColumns(type);
        IndexInfo[] indexes = [new IndexInfo("key", [RedisKeyLayout.KeyColumn(type)], IsUnique: true, IsPrimary: true)];
        return new TableStructure(table, columns, indexes, [], []);
    }

    public async Task<string> GetDefinitionAsync(DatabaseObject obj, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        if (RedisKeyBrowse.IsKeyTable(obj.Name, out var database))
        {
            return await DescribeDatabaseAsync(database, cancellationToken);
        }

        var db = Database(ResolveDatabase(obj.Name.Schema));
        var key = Key(obj.Name.Name);
        var typeTask = TryExecuteAsync(db, "TYPE", key);
        var ttlTask = TryExecuteAsync(db, "TTL", key);
        var encodingTask = TryExecuteAsync(db, "OBJECT", "ENCODING", key);
        var memoryTask = TryExecuteAsync(db, "MEMORY", "USAGE", key);
        await Task.WhenAll(typeTask, ttlTask, encodingTask, memoryTask).WaitAsync(cancellationToken);
        var type = RedisKeyTypes.Parse(typeTask.Result?.Text);
        RedisReply? length = null;
        if (RedisKeyTypes.LengthCommand(type) is { } command)
        {
            length = await TryExecuteAsync(db, command, key).WaitAsync(cancellationToken);
        }
        else if (type == RedisKeyType.String)
        {
            length = await TryExecuteAsync(db, "STRLEN", key).WaitAsync(cancellationToken);
        }

        return DescribeKey(obj.Name.Name, typeTask.Result?.Text, ttlTask.Result?.Text, encodingTask.Result?.Text, memoryTask.Result?.Text, type == RedisKeyType.String ? null : length?.Text, type == RedisKeyType.String ? length?.Text : null);
    }

    /// <summary>The key's facts as readable lines; a fact the server would not give is left out.</summary>
    internal static string DescribeKey(string key, string? type, string? ttl, string? encoding, string? memory, string? length, string? byteLength)
    {
        var builder = new StringBuilder();
        builder.Append("KEY ").AppendLine(RedisCommand.Quote(key));
        builder.Append("TYPE ").AppendLine(type ?? "unknown");
        if (ttl is not null)
        {
            builder.Append("TTL ").AppendLine(ttl switch
            {
                "-1" => "-1 (no expiry)",
                "-2" => "-2 (the key does not exist)",
                _ => ttl + " seconds",
            });
        }

        if (encoding is not null)
        {
            builder.Append("OBJECT ENCODING ").AppendLine(encoding);
        }

        if (memory is not null)
        {
            builder.Append("MEMORY USAGE ").Append(memory).AppendLine(" bytes");
        }

        if (length is not null)
        {
            builder.Append("LENGTH ").AppendLine(length);
        }

        if (byteLength is not null)
        {
            builder.Append("STRLEN ").Append(byteLength).AppendLine(" bytes");
        }

        return builder.ToString().TrimEnd();
    }

    public async Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        if (RedisKeyBrowse.IsKeyTable(request.Table, out var keyTable))
        {
            return await BrowseKeysAsync(keyTable, request, cancellationToken);
        }

        var index = ResolveDatabase(request.Table.Schema);
        var key = request.Table.Name;
        var db = Database(index);
        var type = await KeyTypeAsync(index, key, cancellationToken);
        _browsedTypes[(index, key)] = type;
        var offset = Math.Max(0, request.Offset);
        var limit = request.Limit > 0 ? request.Limit : 1_000;
        var count = Math.Clamp(limit, 100, ScanCount).ToString(CultureInfo.InvariantCulture);
        ResultSet page;
        switch (type)
        {
            case RedisKeyType.None:
                page = new ResultSet(RedisKeyLayout.Columns(RedisKeyType.String), []);
                break;
            case RedisKeyType.String:
                page = offset > 0
                    ? new ResultSet(RedisKeyLayout.Columns(type), [])
                    : RedisKeyLayout.StringRows(RedisReply.From(await db.ExecuteAsync("GET", Key(key)).WaitAsync(cancellationToken)).Text);
                break;
            case RedisKeyType.Hash:
            {
                var (items, more) = await _pager.PageAsync(index, key, "HSCAN", 2, offset, limit, ScanStep(db, "HSCAN", key, count), cancellationToken);
                page = RedisKeyLayout.HashRows(items, more);
                break;
            }

            case RedisKeyType.Set:
            {
                var (items, more) = await _pager.PageAsync(index, key, "SSCAN", 1, offset, limit, ScanStep(db, "SSCAN", key, count), cancellationToken);
                page = RedisKeyLayout.SetRows(items, more);
                break;
            }

            case RedisKeyType.List:
            {
                // One element past the page says whether another page follows, without an LLEN.
                var reply = RedisReply.From(await db.ExecuteAsync("LRANGE", Key(key), offset, offset + limit).WaitAsync(cancellationToken));
                var more = reply.Items.Count > limit;
                page = RedisKeyLayout.ListRows(more ? reply.Items.Take(limit).ToArray() : reply.Items, offset, more);
                break;
            }

            case RedisKeyType.SortedSet:
            {
                var descending = request.Sort.Count > 0 && request.Sort[0].Descending && string.Equals(request.Sort[0].Column, RedisKeyLayout.Score, StringComparison.OrdinalIgnoreCase);
                var reply = RedisReply.From(await db.ExecuteAsync(descending ? "ZREVRANGE" : "ZRANGE", Key(key), offset, offset + limit, "WITHSCORES").WaitAsync(cancellationToken));
                var items = reply.Items.Count > 0 && reply.Items[0].Kind == RedisReplyKind.Array ? reply.Items.SelectMany(i => i.Items).ToArray() : reply.Items;
                var more = items.Count > limit * 2;
                page = RedisKeyLayout.SortedSetRows(more ? items.Take(limit * 2).ToArray() : items, more);
                break;
            }

            case RedisKeyType.Stream:
                page = await BrowseStreamAsync(db, index, key, offset, limit, cancellationToken);
                break;
            case RedisKeyType.Json:
            {
                var reply = RedisReply.From(await db.ExecuteAsync("JSON.GET", Key(key)).WaitAsync(cancellationToken));
                page = RedisKeyLayout.JsonResult(RedisKeyLayout.JsonRows(reply.Text), offset, limit);
                break;
            }

            default:
                throw new NotSupportedException($"The key '{key}' holds a type the grid cannot show. Read it with a command in the query editor.");
        }

        return RedisKeyLayout.ApplySort(RedisKeyLayout.ApplyFilter(page, request.Filter), request.Sort);
    }

    private static RedisScanPager.ScanStep ScanStep(IDatabase db, string verb, string key, string count) =>
        async (cursor, cancellationToken) =>
        {
            var reply = RedisReply.From(await db.ExecuteAsync(verb, Key(key), cursor, "COUNT", count).WaitAsync(cancellationToken));
            return reply.Items.Count < 2 ? ("0", []) : (reply.Items[0].Text ?? "0", reply.Items[1].Items);
        };

    private async Task<ResultSet> BrowseStreamAsync(IDatabase db, int index, string key, long offset, int limit, CancellationToken cancellationToken)
    {
        // XRANGE has no offset: a page that follows the last one resumes after its final id, any other skips ahead.
        var resume = _streamPositions.TryGetValue((index, key), out var saved) && saved.Offset == offset;
        var start = resume ? saved.NextId : "-";
        var fetch = resume ? limit + 1 : offset + limit + 1;
        var reply = RedisReply.From(await db.ExecuteAsync("XRANGE", Key(key), start, "+", "COUNT", fetch).WaitAsync(cancellationToken));
        var entries = resume ? reply.Items : reply.Items.Skip((int)Math.Min(offset, int.MaxValue)).ToArray();
        var more = entries.Count > limit;
        var pageEntries = more ? entries.Take(limit).ToArray() : entries;
        if (more && pageEntries.Count > 0 && pageEntries[^1].Items.Count > 0 && pageEntries[^1].Items[0].Text is { } lastId)
        {
            _streamPositions[(index, key)] = (offset + pageEntries.Count, RedisScanPager.NextStreamId(lastId));
        }
        else
        {
            _streamPositions.TryRemove((index, key), out _);
        }

        return RedisKeyLayout.StreamRows(pageEntries, more);
    }

    public async Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        if (RedisKeyBrowse.IsKeyTable(table, out var keyTable))
        {
            return await CountKeysAsync(keyTable, filter, cancellationToken);
        }

        var index = ResolveDatabase(table.Schema);
        var db = Database(index);
        var type = await KeyTypeAsync(index, table.Name, cancellationToken);
        if (RedisKeyTypes.LengthCommand(type) is { } command)
        {
            return (long)await db.ExecuteAsync(command, Key(table.Name)).WaitAsync(cancellationToken);
        }

        return type switch
        {
            RedisKeyType.String => 1,
            RedisKeyType.Json => RedisKeyLayout.JsonRows(RedisReply.From(await db.ExecuteAsync("JSON.GET", Key(table.Name)).WaitAsync(cancellationToken)).Text).Count,
            _ => 0,
        };
    }

    public async Task<int> SaveChangesAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        if (Profile.IsReadOnly)
        {
            throw new InvalidOperationException("This connection is read-only, so nothing was saved.");
        }

        if (changes.Count == 0)
        {
            return 0;
        }

        if (RedisKeyBrowse.IsKeyTable(table, out var keyTable))
        {
            return await SaveKeysAsync(keyTable, changes, cancellationToken);
        }

        var index = ResolveDatabase(table.Schema);
        var key = table.Name;
        var db = Database(index);
        var type = await KeyTypeAsync(index, key, cancellationToken);
        var current = await ReadCurrentAsync(db, type, key, RedisChangePlanner.RequiredLookups(type, changes), cancellationToken);
        var plan = RedisChangePlanner.Plan(type, key, changes, current);
        if (plan.Commands.Count == 0)
        {
            return 0;
        }

        // A save touches one key, so even on a cluster the whole transaction runs on the primary that owns its slot.
        await RedisTransactionRunner.RunAsync(db, plan, cancellationToken);
        _pager.Forget(index, key);
        _streamPositions.TryRemove((index, key), out _);
        return changes.Count;
    }

    private static async Task<IReadOnlyDictionary<string, string?>> ReadCurrentAsync(IDatabase db, RedisKeyType type, string key, IReadOnlyList<string> lookups, CancellationToken cancellationToken)
    {
        var values = new Dictionary<string, string?>(StringComparer.Ordinal);
        if (lookups.Count == 0)
        {
            return values;
        }

        var tasks = lookups
            .Select(l => db.ExecuteAsync(type == RedisKeyType.Hash ? "HGET" : "ZSCORE", Key(key), l))
            .ToArray();
        await Task.WhenAll(tasks).WaitAsync(cancellationToken);
        for (var i = 0; i < lookups.Count; i++)
        {
            values[lookups[i]] = RedisReply.From(tasks[i].Result).Text;
        }

        return values;
    }

    /// <summary>
    /// Sidebar actions on a key, as redis-cli commands for the review sheet: Delete is <c>DEL</c> and Rename is
    /// <c>RENAME</c>, after a <c>SELECT</c> when the key is in another database than the one a new tab starts in.
    /// </summary>
    public IReadOnlyList<string> BuildDdl(ObjectName table, SchemaChange change) => KeyDdl(table, change, DatabaseIndex);

    internal static IReadOnlyList<string> KeyDdl(ObjectName table, SchemaChange change, int currentDatabase)
    {
        if (RedisKeyBrowse.IsKeyTable(table, out var database))
        {
            // Truncating a database is FLUSHDB, which names no database of its own; a database is never dropped or renamed.
            return change is TruncateTable ? Selecting(database, currentDatabase, "FLUSHDB") : [];
        }

        var key = RedisCommand.Quote(table.Name);
        var command = change switch
        {
            DropObject { Object.Kind: ObjectKind.Key } => "DEL " + key,
            RenameTable rename when !string.IsNullOrEmpty(rename.NewName) => $"RENAME {key} {RedisCommand.Quote(rename.NewName)}",
            _ => null,
        };
        if (command is null)
        {
            return [];
        }

        var index = RedisConnectionOptions.TryParseDatabaseIndex(table.Schema, out var parsed) ? parsed : currentDatabase;
        return Selecting(index, currentDatabase, command);
    }

    /// <summary>A command, after a <c>SELECT</c> when it is for another database than the one a new tab starts in.</summary>
    internal static IReadOnlyList<string> Selecting(int index, int currentDatabase, string command) =>
        index == currentDatabase ? [command] : [string.Create(CultureInfo.InvariantCulture, $"SELECT {index}"), command];

    public async Task<IQueryChannel> OpenChannelAsync(CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        return new RedisQueryChannel(this, DatabaseIndex, Profile.IsReadOnly);
    }

    public async Task<ResultSet> GetActivityAsync(CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var reply = await OnHomeAsync("CLIENT", "LIST").WaitAsync(cancellationToken);
        return RedisServerText.ParseClientList(reply.ToString());
    }

    public async Task TerminateAsync(object processId, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        if (Profile.IsReadOnly)
        {
            throw new InvalidOperationException("This connection is read-only, so the client was not disconnected.");
        }

        var id = Convert.ToString(processId, CultureInfo.InvariantCulture);
        if (!long.TryParse(id, NumberStyles.None, CultureInfo.InvariantCulture, out _))
        {
            throw new ArgumentException($"'{id}' is not a Redis client id.", nameof(processId));
        }

        await OnHomeAsync("CLIENT", "KILL", "ID", id).WaitAsync(cancellationToken);
    }

    public async Task<ResultSet> GetVariablesAsync(CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var reply = await OnHomeAsync("INFO").WaitAsync(cancellationToken);
        return RedisServerText.InfoResult(reply.ToString());
    }

    /// <summary>A keyless command on the home node of a cluster, or on the one primary otherwise.</summary>
    internal Task<RedisResult> OnHomeAsync(string command, params object[] args) =>
        IsCluster ? Home.ExecuteAsync(command, args) : Database(DatabaseIndex).ExecuteAsync(command, args);

    private async Task<RedisKeyType> KeyTypeAsync(int index, string key, CancellationToken cancellationToken)
    {
        var reply = await Database(index).ExecuteAsync("TYPE", Key(key)).WaitAsync(cancellationToken);
        return RedisKeyTypes.Parse(reply.ToString());
    }

    /// <summary>A key argument, typed so the library routes the command to the node that owns the key's slot.</summary>
    private static RedisKey Key(string key) => key;

    /// <summary>A reply, or null when the server refused the command (an ACL denial, a renamed command).</summary>
    private static async Task<RedisReply?> TryExecuteAsync(IDatabase db, string command, params object[] args)
    {
        try
        {
            return RedisReply.From(await db.ExecuteAsync(command, args));
        }
        catch (RedisServerException)
        {
            return null;
        }
    }

    public async ValueTask DisposeAsync()
    {
        await _connection.DisposeAsync();
        if (_sentinel is not null)
        {
            await _sentinel.DisposeAsync();
        }

        if (_signIn is not null)
        {
            await _signIn.DisposeAsync();
        }
    }
}
