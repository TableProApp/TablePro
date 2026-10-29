using System.Diagnostics;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text.Json;
using TablePro.Core.Drivers;
using TablePro.Core.Localization;
using TablePro.Core.Results;
using TablePro.Drivers.Etcd.Localization;

namespace TablePro.Drivers.Etcd;

/// <summary>An editor tab of etcdctl commands, each parsed and sent to the gateway as one call.</summary>
internal sealed class EtcdChannel(EtcdClient client) : IQueryChannel
{
    private readonly SemaphoreSlim _gate = new(1, 1);

    public async IAsyncEnumerable<StatementResult> ExecuteAsync(
        IReadOnlyList<string> statements,
        ExecuteOptions options,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            foreach (var command in statements)
            {
                var result = await RunAsync(command, options, cancellationToken);
                yield return result;
                if (!result.Succeeded && (options.StopOnError || cancellationToken.IsCancellationRequested))
                {
                    yield break;
                }
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    public ValueTask DisposeAsync()
    {
        _gate.Dispose();
        return ValueTask.CompletedTask;
    }

    private async Task<StatementResult> RunAsync(string command, ExecuteOptions options, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var stopwatch = Stopwatch.StartNew();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        if (options.CommandTimeoutSeconds > 0)
        {
            timeout.CancelAfter(TimeSpan.FromSeconds(options.CommandTimeoutSeconds));
        }

        try
        {
            var operation = EtcdCommandParser.Parse(command);
            var (sets, affected, messages) = await EtcdExecutor.RunAsync(client, operation, options.RowLimit, timeout.Token);
            return new StatementResult(command, sets, affected, stopwatch.Elapsed, Messages: messages);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && timeout.IsCancellationRequested)
        {
            return new StatementResult(command, [], -1, stopwatch.Elapsed, CoreStrings.Format("Driver/CommandTimedOutAfter", options.CommandTimeoutSeconds));
        }
        catch (OperationCanceledException)
        {
            return new StatementResult(command, [], -1, stopwatch.Elapsed, CoreStrings.Get("Driver/CommandCancelled"));
        }
        catch (Exception ex) when (ex is EtcdCommandException or EtcdException or HttpRequestException or JsonException)
        {
            return new StatementResult(command, [], -1, stopwatch.Elapsed, ex.Message);
        }
    }
}

/// <summary>Runs a parsed etcdctl command through the gateway and shapes its answer as etcdctl's table output.</summary>
internal static class EtcdExecutor
{
    private const int MaxWatchEvents = 10_000;

    public static async Task<(IReadOnlyList<ResultSet> Sets, int Affected, IReadOnlyList<string> Messages)> RunAsync(
        EtcdClient client, EtcdOperation operation, int rowLimit, CancellationToken cancellationToken)
    {
        switch (operation)
        {
            case EtcdGet get:
            {
                var request = BuildRange(get, rowLimit);
                var response = await client.RangeAsync(request, cancellationToken);
                if (get.CountOnly)
                {
                    return ([Table(["count"], [typeof(long)], [[response.Count]])], -1, []);
                }

                var kvs = response.Kvs ?? [];
                var set = EtcdRows.ToResultSet(kvs, response.More && (get.Limit == 0 || kvs.Count < get.Limit));
                return ([set], -1, response.More ? [CoreStrings.Format("Driver/ShowingOfKeys", kvs.Count, response.Count)] : []);
            }

            case EtcdPut put:
            {
                var response = await client.PutAsync(
                    new EtcdPutRequest { Key = EtcdClient.Utf8(put.Key), Value = EtcdClient.Utf8(put.Value), Lease = put.Lease ?? 0, IgnoreLease = put.IgnoreLease },
                    cancellationToken);
                return ([], 1, [Revision("OK", response.Header)]);
            }

            case EtcdDelete delete:
            {
                var (key, end) = Range(delete.Key, delete.RangeEnd, delete.Prefix, delete.FromKey);
                var response = await client.DeleteAsync(new EtcdDeleteRangeRequest { Key = key, RangeEnd = end }, cancellationToken);
                return ([], (int)Math.Min(response.Deleted, int.MaxValue), [Revision(response.Deleted.ToString(CultureInfo.InvariantCulture), response.Header)]);
            }

            case EtcdWatch watch:
            {
                var (key, end) = Range(watch.Key, null, watch.Prefix, false);
                var events = await client.WatchAsync(key, end, TimeSpan.FromSeconds(watch.TimeoutSeconds), Math.Min(rowLimit, MaxWatchEvents), cancellationToken);
                var rows = events.Select(e => new object?[]
                {
                    e.Type ?? "PUT",
                    EtcdRows.KeyText(e.Kv?.Key),
                    e.Kv?.Value is { } value ? EtcdRows.KeyText(value) : null,
                    e.Kv?.ModRevision ?? 0,
                }).ToList();
                var message = EtcdStrings.Format("Etcd/Watched", watch.TimeoutSeconds, rows.Count);
                return ([Table(["type", "key", "value", "mod_revision"], [typeof(string), typeof(string), typeof(string), typeof(long)], rows)], -1, [message]);
            }

            case EtcdLeaseGrant grant:
            {
                var response = await client.LeaseAsync("grant", new EtcdLeaseRequest { Ttl = grant.Ttl }, cancellationToken);
                if (!string.IsNullOrEmpty(response.Error))
                {
                    throw new EtcdException(response.Error);
                }

                return ([Table(["lease_id", "lease_id_hex", "ttl"], [typeof(long), typeof(string), typeof(long)], [[response.Id, EtcdCommandParser.LeaseHex(response.Id), response.Ttl]])], 1, []);
            }

            case EtcdLeaseRevoke revoke:
                await client.LeaseAsync("revoke", new EtcdLeaseRequest { Id = revoke.LeaseId }, cancellationToken);
                return ([], 1, [EtcdStrings.Format("Etcd/LeaseRevoked", EtcdCommandParser.LeaseHex(revoke.LeaseId))]);

            case EtcdLeaseTimeToLive live:
            {
                var response = await client.LeaseAsync("timetolive", new EtcdLeaseRequest { Id = live.LeaseId, Keys = live.Keys }, cancellationToken);
                var keys = string.Join(", ", (response.Keys ?? []).Select(EtcdRows.KeyText));
                return ([Table(
                    ["lease_id_hex", "ttl", "granted_ttl", "attached_keys"],
                    [typeof(string), typeof(long), typeof(long), typeof(string)],
                    [[EtcdCommandParser.LeaseHex(live.LeaseId), response.Ttl, response.GrantedTtl, live.Keys ? keys : null]])], -1, response.Ttl < 0 ? [EtcdStrings.Get("Etcd/LeaseExpired")] : []);
            }

            case EtcdLeaseList:
            {
                var response = await client.LeasesAsync(cancellationToken);
                var rows = (response.Leases ?? []).Select(l => new object?[] { l.Id, EtcdCommandParser.LeaseHex(l.Id) }).ToList();
                return ([Table(["lease_id", "lease_id_hex"], [typeof(long), typeof(string)], rows)], -1, []);
            }

            case EtcdLeaseKeepAlive keep:
            {
                var response = await client.KeepAliveOnceAsync(keep.LeaseId, cancellationToken);
                return ([], 1, [EtcdStrings.Format("Etcd/LeaseRefreshed", EtcdCommandParser.LeaseHex(keep.LeaseId), response.Ttl)]);
            }

            case EtcdMemberList:
            {
                var response = await client.MembersAsync(cancellationToken);
                var rows = (response.Members ?? []).Select(m => new object?[]
                {
                    m.Id.ToString("x", CultureInfo.InvariantCulture),
                    m.Name,
                    string.Join(", ", m.PeerUrls ?? []),
                    string.Join(", ", m.ClientUrls ?? []),
                    m.IsLearner,
                }).ToList();
                return ([Table(["id", "name", "peer_urls", "client_urls", "is_learner"], [typeof(string), typeof(string), typeof(string), typeof(string), typeof(bool)], rows)], -1, []);
            }

            case EtcdEndpointStatus:
            {
                var status = await client.StatusAsync(cancellationToken);
                object?[] row =
                [
                    client.BaseUri.ToString().TrimEnd('/'),
                    status.Header?.MemberId.ToString("x", CultureInfo.InvariantCulture),
                    status.Version,
                    status.DbSize,
                    status.Leader.ToString("x", CultureInfo.InvariantCulture),
                    status.Header is { } header && header.MemberId == status.Leader,
                    status.IsLearner,
                    (long)status.RaftTerm,
                    (long)status.RaftIndex,
                    status.Errors is { Count: > 0 } errors ? string.Join("; ", errors) : null,
                ];
                return ([Table(
                    ["endpoint", "id", "version", "db_size", "leader", "is_leader", "is_learner", "raft_term", "raft_index", "errors"],
                    [typeof(string), typeof(string), typeof(string), typeof(long), typeof(string), typeof(bool), typeof(bool), typeof(long), typeof(long), typeof(string)],
                    [row])], -1, []);
            }

            case EtcdEndpointHealth:
            {
                // etcdctl calls an endpoint healthy when a linearizable read answers; this is the same read.
                var stopwatch = Stopwatch.StartNew();
                string? error = null;
                try
                {
                    await client.RangeAsync(new EtcdRangeRequest { Key = EtcdClient.Utf8("health"), Limit = 1, KeysOnly = true }, cancellationToken);
                }
                catch (EtcdException ex) when (!ex.Message.Contains("permission denied", StringComparison.OrdinalIgnoreCase))
                {
                    error = ex.Message;
                }

                return ([Table(
                    ["endpoint", "health", "took_ms", "error"],
                    [typeof(string), typeof(bool), typeof(double), typeof(string)],
                    [[client.BaseUri.ToString().TrimEnd('/'), error is null, Math.Round(stopwatch.Elapsed.TotalMilliseconds, 1), error]])], -1, []);
            }

            case EtcdCompaction compaction:
                await client.CompactAsync(new EtcdCompactionRequest { Revision = compaction.Revision, Physical = compaction.Physical }, cancellationToken);
                return ([], 0, [EtcdStrings.Format("Etcd/Compacted", compaction.Revision)]);

            case EtcdAuthToggle toggle:
                await client.AuthAsync(toggle.Enable ? "enable" : "disable", new EtcdAuthRequest(), cancellationToken);
                return ([], 0, [EtcdStrings.Get(toggle.Enable ? "Etcd/AuthEnabled" : "Etcd/AuthDisabled")]);

            case EtcdUserAdd add:
                await client.AuthAsync("user/add", new EtcdAuthRequest { Name = add.Name, Password = add.Password ?? string.Empty }, cancellationToken);
                return ([], 0, [EtcdStrings.Format("Etcd/UserCreated", add.Name)]);

            case EtcdUserDelete delete:
                await client.AuthAsync("user/delete", new EtcdAuthRequest { Name = delete.Name }, cancellationToken);
                return ([], 0, [EtcdStrings.Format("Etcd/UserDeleted", delete.Name)]);

            case EtcdUserList:
            {
                var response = await client.AuthAsync("user/list", new EtcdAuthRequest(), cancellationToken);
                return ([Table(["user"], [typeof(string)], (response.Users ?? []).Select(u => new object?[] { u }).ToList())], -1, []);
            }

            case EtcdUserGrantRole grant:
                await client.AuthAsync("user/grant", new EtcdAuthRequest { User = grant.User, Role = grant.Role }, cancellationToken);
                return ([], 0, [EtcdStrings.Format("Etcd/RoleGranted", grant.Role, grant.User)]);

            case EtcdUserRevokeRole revoke:
                await client.AuthAsync("user/revoke", new EtcdAuthRequest { Name = revoke.User, Role = revoke.Role }, cancellationToken);
                return ([], 0, [EtcdStrings.Format("Etcd/RoleRevoked", revoke.Role, revoke.User)]);

            case EtcdRoleAdd add:
                await client.AuthAsync("role/add", new EtcdAuthRequest { Name = add.Name }, cancellationToken);
                return ([], 0, [EtcdStrings.Format("Etcd/RoleCreated", add.Name)]);

            case EtcdRoleDelete delete:
                await client.AuthAsync("role/delete", new EtcdAuthRequest { Role = delete.Name }, cancellationToken);
                return ([], 0, [EtcdStrings.Format("Etcd/RoleDeleted", delete.Name)]);

            case EtcdRoleList:
            {
                var response = await client.AuthAsync("role/list", new EtcdAuthRequest(), cancellationToken);
                return ([Table(["role"], [typeof(string)], (response.Roles ?? []).Select(r => new object?[] { r }).ToList())], -1, []);
            }

            default:
                throw new EtcdCommandException(CoreStrings.Get("Driver/CommandNotSupported"));
        }
    }

    /// <summary>The range request a get sends. A get with no --limit stops at the tab's row limit.</summary>
    internal static EtcdRangeRequest BuildRange(EtcdGet get, int rowLimit)
    {
        var (key, end) = Range(get.Key, get.RangeEnd, get.Prefix, get.FromKey);
        return new EtcdRangeRequest
        {
            Key = key,
            RangeEnd = end,
            Limit = get.Limit > 0 ? Math.Min(get.Limit, rowLimit) : rowLimit,
            Revision = get.Revision,
            KeysOnly = get.KeysOnly,
            CountOnly = get.CountOnly,
            SortOrder = get.SortOrder,
            SortTarget = get.SortTarget ?? (get.SortOrder is null ? null : "KEY"),
        };
    }

    /// <summary>etcdctl's key arguments as a gateway range: one key, a prefix, everything from a key on, or [key, end).</summary>
    internal static (byte[] Key, byte[]? RangeEnd) Range(string key, string? rangeEnd, bool prefix, bool fromKey)
    {
        if (prefix)
        {
            return EtcdRows.Prefix(key);
        }

        var start = key.Length == 0 ? [0] : EtcdClient.Utf8(key);
        if (fromKey)
        {
            return (start, [0]);
        }

        return (start, rangeEnd is null ? null : EtcdClient.Utf8(rangeEnd));
    }

    private static string Revision(string text, EtcdHeader? header) =>
        header is null ? text : EtcdStrings.Format("Etcd/WithRevision", text, header.Revision);

    private static ResultSet Table(string[] names, Type[] types, List<object?[]> rows)
    {
        var columns = new ResultColumn[names.Length];
        for (var i = 0; i < names.Length; i++)
        {
            columns[i] = new ResultColumn(names[i], types[i] == typeof(long) ? "BIGINT" : types[i] == typeof(bool) ? "BOOLEAN" : types[i] == typeof(double) ? "DOUBLE" : "TEXT", types[i]);
        }

        return new ResultSet(columns, rows);
    }
}
