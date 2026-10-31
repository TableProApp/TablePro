using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using TablePro.Drivers.Etcd.Localization;

namespace TablePro.Drivers.Etcd;

/// <summary>
/// An etcd cluster through its v3 JSON gateway. Keys under the connection's key prefix are the objects; a key, or a
/// prefix ending in <c>/</c> or <c>*</c>, browses as rows of key, value, version, revisions and lease.
/// </summary>
internal sealed class EtcdSession : IDatabaseSession, IKeySearchProvider
{
    /// <summary>How many keys the sidebar lists before the search box takes over.</summary>
    internal const int SidebarLimit = 1_000;

    /// <summary>How many keys a filtered browse or count reads at most, since etcd cannot filter values itself.</summary>
    internal const int MaxScan = 100_000;

    private const int ScanChunk = 1_000;

    private readonly HttpClient _http;

    private EtcdSession(ConnectionRequest request, HttpClient http, EtcdClient client, string root, string version)
    {
        Profile = request.Profile;
        _http = http;
        Client = client;
        Root = root;
        ServerVersion = version;
    }

    public ConnectionProfile Profile { get; }

    public SqlDialect Dialect => EtcdDialect.Instance;

    public string ServerVersion { get; }

    public string? CurrentDatabase => null;

    public string? DefaultSchema => null;

    internal EtcdClient Client { get; }

    internal string Root { get; }

    public static async Task<EtcdSession> ConnectAsync(ConnectionRequest request, HttpMessageHandler? handler, CancellationToken cancellationToken)
    {
        var settings = EtcdSettings.From(request);
        handler ??= settings.CreateHandler(request.Profile.ConnectTimeoutSeconds);
        var http = new HttpClient(handler, disposeHandler: true) { Timeout = Timeout.InfiniteTimeSpan };
        try
        {
            using var connect = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            connect.CancelAfter(TimeSpan.FromSeconds(Math.Max(1, request.Profile.ConnectTimeoutSeconds)));
            var client = new EtcdClient(http, settings.BaseUri, request.Profile.Username, request.Password);
            await client.ConnectAsync(connect.Token);
            string? version = null;
            try
            {
                version = (await client.StatusAsync(connect.Token)).Version;
            }
            catch (EtcdException)
            {
                // Status needs a role with maintenance rights; the gateway's /version answers anyone.
            }

            version ??= await client.GatewayVersionAsync(connect.Token);
            return new EtcdSession(request, http, client, settings.KeyPrefix, version is null ? "etcd" : "etcd " + version);
        }
        catch
        {
            http.Dispose();
            throw;
        }
    }

    public async Task PingAsync(CancellationToken cancellationToken)
    {
        await Yield();
        await Client.RangeAsync(new EtcdRangeRequest { Key = EtcdClient.Utf8("health"), Limit = 1, KeysOnly = true }, cancellationToken);
    }

    public Task<IReadOnlyList<string>> GetDatabasesAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>([]);

    public Task<IReadOnlyList<string>> GetSchemasAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>([]);

    public async Task<IReadOnlyList<DatabaseObject>> GetObjectsAsync(string? schema, CancellationToken cancellationToken)
    {
        await Yield();
        var (key, end) = EtcdRows.Prefix(Root);
        var response = await Client.RangeAsync(new EtcdRangeRequest { Key = key, RangeEnd = end, Limit = SidebarLimit, KeysOnly = true }, cancellationToken);
        return (response.Kvs ?? []).Select(ToObject).ToArray();
    }

    public async Task<KeySearchResult> SearchKeysAsync(string? database, string pattern, int limit, CancellationToken cancellationToken)
    {
        await Yield();
        var literal = EtcdRows.GlobPrefix(pattern);
        var (start, end) = EtcdRows.Prefix(literal);
        var found = new List<DatabaseObject>(Math.Min(limit, SidebarLimit));
        if (!EtcdRows.IsGlob(pattern))
        {
            // Without wildcards the pattern is a prefix, which etcd ranges over directly.
            var page = await Client.RangeAsync(new EtcdRangeRequest { Key = start, RangeEnd = end, Limit = limit, KeysOnly = true }, cancellationToken);
            return new KeySearchResult((page.Kvs ?? []).Select(ToObject).ToArray(), page.More);
        }

        var scanned = 0;
        while (scanned < MaxScan)
        {
            var page = await Client.RangeAsync(new EtcdRangeRequest { Key = start, RangeEnd = end, Limit = ScanChunk, KeysOnly = true }, cancellationToken);
            var kvs = page.Kvs ?? [];
            scanned += kvs.Count;
            foreach (var kv in kvs)
            {
                if (EtcdRows.GlobMatch(pattern, EtcdRows.KeyText(kv.Key)))
                {
                    found.Add(ToObject(kv));
                    if (found.Count >= limit)
                    {
                        return new KeySearchResult(found, true);
                    }
                }
            }

            if (!page.More || kvs.Count == 0)
            {
                return new KeySearchResult(found, false);
            }

            start = After(kvs[^1].Key!);
        }

        return new KeySearchResult(found, true);
    }

    public Task<TableStructure> GetStructureAsync(ObjectName table, CancellationToken cancellationToken) =>
        Task.FromResult(new TableStructure(table, EtcdRows.Columns, [], [], []));

    public async Task<string> GetDefinitionAsync(DatabaseObject obj, CancellationToken cancellationToken)
    {
        await Yield();
        var (key, end) = EtcdRows.Target(obj.Name.Name, Root);
        var response = await Client.RangeAsync(new EtcdRangeRequest { Key = key, RangeEnd = end, Limit = 1 }, cancellationToken);
        var kv = response.Kvs is { Count: > 0 } kvs ? kvs[0] : null;
        if (kv is null || end is not null)
        {
            return $"get {Quote(obj.Name.Name)}{(end is null ? string.Empty : " --prefix")}";
        }

        var lease = kv.Lease == 0 ? string.Empty : " --lease=" + EtcdCommandParser.LeaseHex(kv.Lease);
        return $"put {Quote(EtcdRows.KeyText(kv.Key))} {Quote(EtcdRows.KeyText(kv.Value))}{lease}";
    }

    public async Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken)
    {
        await Yield();
        var (key, end) = EtcdRows.Target(request.Table.Name, Root);
        if (!request.Filter.IsEmpty)
        {
            return await BrowseFilteredAsync(request, key, end, cancellationToken);
        }

        var (target, order) = SortOf(request.Sort);
        if (target is null)
        {
            // Key order is etcd's own, so a page starts right after the key that ends the skipped rows.
            var start = key;
            if (request.Offset > 0)
            {
                var skipped = await Client.RangeAsync(new EtcdRangeRequest { Key = key, RangeEnd = end, Limit = request.Offset, KeysOnly = true }, cancellationToken);
                if ((skipped.Kvs?.Count ?? 0) < request.Offset || !skipped.More)
                {
                    return EtcdRows.ToResultSet([]);
                }

                start = After(skipped.Kvs![^1].Key!);
            }

            var page = await Client.RangeAsync(new EtcdRangeRequest { Key = start, RangeEnd = end, Limit = request.Limit }, cancellationToken);
            return EtcdRows.ToResultSet(page.Kvs ?? []);
        }

        // Any other order is sorted by the server over the whole range, then the skipped rows are dropped here.
        var sorted = await Client.RangeAsync(
            new EtcdRangeRequest { Key = key, RangeEnd = end, Limit = (long)request.Offset + request.Limit, SortTarget = target, SortOrder = order },
            cancellationToken);
        return EtcdRows.ToResultSet((sorted.Kvs ?? []).Skip(request.Offset).Take(request.Limit).ToArray());
    }

    public async Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken)
    {
        await Yield();
        var (key, end) = EtcdRows.Target(table.Name, Root);
        if (filter.IsEmpty)
        {
            var response = await Client.RangeAsync(new EtcdRangeRequest { Key = key, RangeEnd = end, CountOnly = true }, cancellationToken);
            return response.Count;
        }

        var (matches, _) = await ScanAsync(key, end, filter, int.MaxValue, cancellationToken);
        return matches.Count;
    }

    public async Task<int> SaveChangesAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken)
    {
        await Yield();
        if (changes.Count == 0)
        {
            return 0;
        }

        var sources = new Dictionary<string, EtcdKeyValue>(StringComparer.Ordinal);
        foreach (var oldKey in EtcdSave.RenameSources(changes))
        {
            var current = await Client.RangeAsync(new EtcdRangeRequest { Key = oldKey }, cancellationToken);
            if (current.Kvs is { Count: > 0 } kvs)
            {
                sources[EtcdSave.KeyName(oldKey)] = kvs[0];
            }
        }

        // Past 128 operations the save splits into several transactions; each still applies whole or not at all.
        foreach (var transaction in EtcdSave.BuildTransactions(changes, sources))
        {
            var response = await Client.TxnAsync(transaction, cancellationToken);
            if (!response.Succeeded)
            {
                throw await DiagnoseAsync(transaction, cancellationToken);
            }
        }

        return changes.Count;
    }

    public Task<IQueryChannel> OpenChannelAsync(CancellationToken cancellationToken) =>
        Task.FromResult<IQueryChannel>(new EtcdChannel(Client));

    public ValueTask DisposeAsync()
    {
        Client.Dispose();
        _http.Dispose();
        return ValueTask.CompletedTask;
    }

    /// <summary>The first key after <paramref name="key"/>: the key with a zero byte appended.</summary>
    internal static byte[] After(byte[] key)
    {
        var next = new byte[key.Length + 1];
        key.CopyTo(next, 0);
        return next;
    }

    /// <summary>etcd sorts by one of its own targets; a sort on the lease or by key ascending needs no server sort.</summary>
    internal static (string? Target, string? Order) SortOf(IReadOnlyList<SortColumn> sort)
    {
        if (sort.Count == 0)
        {
            return (null, null);
        }

        var first = sort[0];
        var target = first.Column.ToLowerInvariant() switch
        {
            EtcdRows.KeyColumn => "KEY",
            EtcdRows.ValueColumn => "VALUE",
            EtcdRows.VersionColumn => "VERSION",
            EtcdRows.CreateRevisionColumn => "CREATE",
            EtcdRows.ModRevisionColumn => "MOD",
            _ => null,
        };
        return target is null || (target == "KEY" && !first.Descending) ? (null, null) : (target, first.Descending ? "DESCEND" : "ASCEND");
    }

    private async Task<ResultSet> BrowseFilteredAsync(BrowseRequest request, byte[] key, byte[]? end, CancellationToken cancellationToken)
    {
        var (matches, truncated) = await ScanAsync(key, end, request.Filter, request.Offset + request.Limit, cancellationToken);
        var (target, order) = SortOf(request.Sort);
        IEnumerable<EtcdKeyValue> ordered = matches;
        if (target is not null)
        {
            Func<EtcdKeyValue, IComparable> selector = target switch
            {
                "VALUE" => kv => EtcdRows.KeyText(kv.Value),
                "VERSION" => kv => kv.Version,
                "CREATE" => kv => kv.CreateRevision,
                "MOD" => kv => kv.ModRevision,
                _ => kv => EtcdRows.KeyText(kv.Key),
            };
            ordered = order == "DESCEND" ? matches.OrderByDescending(selector) : matches.OrderBy(selector);
        }

        return EtcdRows.ToResultSet(ordered.Skip(request.Offset).Take(request.Limit).ToArray(), truncated);
    }

    /// <summary>Reads the range in key order, keeping rows the filter accepts, until enough match or the scan cap is hit.</summary>
    private async Task<(List<EtcdKeyValue> Matches, bool Truncated)> ScanAsync(byte[] key, byte[]? end, BrowseFilter filter, int wanted, CancellationToken cancellationToken)
    {
        var accept = RowFilter.Compile(filter, EtcdRows.Columns.Select(c => c.Name).ToArray(), "etcd");
        var matches = new List<EtcdKeyValue>();
        var start = key;
        var scanned = 0;
        while (scanned < MaxScan)
        {
            var page = await Client.RangeAsync(new EtcdRangeRequest { Key = start, RangeEnd = end, Limit = ScanChunk }, cancellationToken);
            var kvs = page.Kvs ?? [];
            scanned += kvs.Count;
            var rows = EtcdRows.ToResultSet(kvs);
            for (var i = 0; i < kvs.Count; i++)
            {
                if (accept(rows.Rows[i]))
                {
                    matches.Add(kvs[i]);
                    if (matches.Count >= wanted)
                    {
                        return (matches, true);
                    }
                }
            }

            if (end is null || !page.More || kvs.Count == 0)
            {
                return (matches, false);
            }

            start = After(kvs[^1].Key!);
        }

        return (matches, true);
    }

    /// <summary>Finds which comparison failed, so the message names the key the grid was wrong about.</summary>
    private async Task<Exception> DiagnoseAsync(EtcdTxnRequest transaction, CancellationToken cancellationToken)
    {
        foreach (var compare in transaction.Compare)
        {
            var current = await Client.RangeAsync(new EtcdRangeRequest { Key = compare.Key }, cancellationToken);
            var kv = current.Kvs is { Count: > 0 } kvs ? kvs[0] : null;
            var name = EtcdRows.KeyText(compare.Key);
            switch (compare.Target, compare.Result)
            {
                case ("VERSION", "GREATER") when kv is null:
                    return new RowCountMismatchException(1, 0, EtcdStrings.Format("Etcd/KeyGoneStatement", name));
                case ("VERSION", "EQUAL") when kv is not null:
                    return new InvalidOperationException(EtcdStrings.Format("Etcd/KeyAlreadyExists", name));
                case ("MOD", _) when kv is null || kv.ModRevision != compare.ModRevision:
                    return new InvalidOperationException(EtcdStrings.Format("Etcd/KeyChangedSinceRead", name));
            }
        }

        return new InvalidOperationException(EtcdStrings.Get("Etcd/ConcurrentChange"));
    }

    private static DatabaseObject ToObject(EtcdKeyValue kv) =>
        new(new ObjectName(null, EtcdRows.KeyText(kv.Key)), ObjectKind.Key, null, EtcdRows.Describe(kv));

    internal static string Quote(string value)
    {
        if (value.Length > 0 && !value.Any(c => char.IsWhiteSpace(c) || c is '"' or '\''))
        {
            return value;
        }

        var quoted = new StringBuilder(value.Length + 2).Append('"');
        foreach (var c in value)
        {
            quoted.Append(c switch
            {
                '\\' => "\\\\",
                '"' => "\\\"",
                '\n' => "\\n",
                '\r' => "\\r",
                _ => c.ToString(CultureInfo.InvariantCulture),
            });
        }

        return quoted.Append('"').ToString();
    }

    private static ConfiguredTaskAwaitable Yield() => Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
}
