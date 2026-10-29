using System.Globalization;
using System.Text;
using StackExchange.Redis;
using TablePro.Core.Browse;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Drivers.Redis.Localization;

namespace TablePro.Drivers.Redis;

/// <summary>A database as one table of its keys; see <see cref="RedisKeyBrowse"/>.</summary>
public sealed partial class RedisSession
{
    private static readonly KeyBrowseInfo KeyListing = new(RedisKeyBrowse.Key, RedisKeyBrowse.Type, RedisKeyBrowse.Types);

    public KeyBrowseInfo? GetKeyBrowse(ObjectName table) => RedisKeyBrowse.IsKeyTable(table, out _) ? KeyListing : null;

    /// <summary>
    /// The save review in redis-cli commands. It is drawn before the save reads the server, so a value edit on the
    /// list of keys shows the <c>SET</c> a string takes, and a renamed hash field shows where its current value goes.
    /// What the grid cannot write is shown as the reason, and the save itself refuses it.
    /// </summary>
    public IReadOnlyList<string> PreviewChanges(ObjectName table, IReadOnlyList<RowChange> changes)
    {
        try
        {
            if (RedisKeyBrowse.IsKeyTable(table, out var database))
            {
                var commands = RedisKeyBrowse.Plan(changes, null).SelectMany(w => w.Plan.Commands).Select(c => c.ToString()).ToList();
                if (database != DatabaseIndex && commands.Count > 0)
                {
                    commands.Insert(0, string.Create(CultureInfo.InvariantCulture, $"SELECT {database}"));
                }

                return commands;
            }

            var index = ResolveDatabase(table.Schema);
            var type = _browsedTypes.GetValueOrDefault((index, table.Name), RedisKeyType.None);
            var current = RedisChangePlanner.RequiredLookups(type, changes).ToDictionary(l => l, _ => (string?)RedisStrings.Get("Redis/CurrentValue"), StringComparer.Ordinal);
            var planned = RedisChangePlanner.Plan(type, table.Name, changes, current).Commands.Select(c => c.ToString()).ToList();
            if (index != DatabaseIndex && planned.Count > 0)
            {
                planned.Insert(0, string.Create(CultureInfo.InvariantCulture, $"SELECT {index}"));
            }

            return planned;
        }
        catch (Exception ex) when (ex is NotSupportedException or InvalidOperationException or FormatException or System.Text.Json.JsonException)
        {
            return ["# " + ex.Message];
        }
    }

    /// <summary>DBSIZE, summed over the primaries of a cluster; null when the server refuses it.</summary>
    private async Task<long?> TryKeyCountAsync(int index, CancellationToken cancellationToken)
    {
        try
        {
            return await KeyCountAsync(index, cancellationToken);
        }
        catch (RedisServerException)
        {
            return null;
        }
    }

    private async Task<long> KeyCountAsync(int index, CancellationToken cancellationToken)
    {
        if (!IsCluster)
        {
            return (long)await Database(index).ExecuteAsync("DBSIZE").WaitAsync(cancellationToken);
        }

        var sizes = await Task.WhenAll(Primaries().Select(p => p.DatabaseSizeAsync(index))).WaitAsync(cancellationToken);
        return sizes.Sum();
    }

    /// <summary>
    /// A database's key count and the types of a sample of its keys, as the macOS app describes a database; there is
    /// no DDL to show.
    /// </summary>
    private async Task<string> DescribeDatabaseAsync(int index, CancellationToken cancellationToken)
    {
        var countTask = TryKeyCountAsync(index, cancellationToken);
        var (sample, _) = await ScanKeysAsync(index, null, 100, cancellationToken);
        var db = Database(index);
        var types = await Task.WhenAll(sample.Select(k => TryExecuteAsync(db, "TYPE", Key(k)))).WaitAsync(cancellationToken);
        return DescribeDatabase(index, await countTask, types.Select(t => t?.Text).ToArray());
    }

    internal static string DescribeDatabase(int index, long? keyCount, IReadOnlyList<string?> sampledTypes)
    {
        var builder = new StringBuilder();
        builder.AppendLine(RedisStrings.Format("Redis/DbHeader", RedisConnectionOptions.SchemaName(index)));
        builder.AppendLine(RedisStrings.Format("Redis/DbKeys", keyCount?.ToString(CultureInfo.InvariantCulture) ?? RedisStrings.Get("Redis/Unknown")));
        builder.AppendLine(RedisStrings.Format("Redis/DbBrowseWith", "SCAN 0 MATCH * COUNT 200"));
        var counts = sampledTypes
            .OfType<string>()
            .Where(t => t != "none")
            .GroupBy(t => t, StringComparer.Ordinal)
            .OrderBy(g => g.Key, StringComparer.Ordinal)
            .ToArray();
        if (counts.Length > 0)
        {
            builder.AppendLine("#");
            builder.AppendLine(RedisStrings.Plural("Redis/DbTypes", sampledTypes.Count));
            foreach (var group in counts)
            {
                builder.Append(CultureInfo.InvariantCulture, $"#   {group.Key}: {group.Count()}").AppendLine();
            }
        }

        return builder.ToString().TrimEnd();
    }

    /// <summary>
    /// A page of keys. SCAN resumes where the previous page stopped, so paging forward through millions of keys costs
    /// one page of scanning each time, and the key pattern and type are matched on the server so a page is full.
    /// </summary>
    private async Task<ResultSet> BrowseKeysAsync(int index, BrowseRequest request, CancellationToken cancellationToken)
    {
        var scope = RedisKeyBrowse.Scope(request.Filter);
        var offset = Math.Max(0, request.Offset);
        var limit = request.Limit > 0 ? request.Limit : 1_000;
        var (items, more) = await _pager.PageAsync(index, string.Empty, PagerId(scope), 1, offset, limit, KeyScanStep(index, scope), cancellationToken);
        var keys = items.Select(i => i.Text).OfType<string>().ToList();
        var page = new ResultSet(RedisKeyBrowse.Columns, await DescribeKeyRowsAsync(index, keys, cancellationToken), more);
        return RedisKeyLayout.ApplySort(RedisKeyLayout.ApplyFilter(page, scope.Remaining), RedisKeyBrowse.PageOrder(request.Sort));
    }

    /// <summary>
    /// How many keys the listing holds. DBSIZE is exact for the whole database; a pattern or type is counted by
    /// scanning to the end with it, as macOS counts exactly. A rule only the page can match has no count.
    /// </summary>
    private async Task<long> CountKeysAsync(int index, BrowseFilter filter, CancellationToken cancellationToken)
    {
        var scope = RedisKeyBrowse.Scope(filter);
        if (!scope.IsServerSide)
        {
            throw new NotSupportedException(RedisStrings.Get("Redis/OnlyKeyTypeCounted"));
        }

        if (scope.Pattern is null && scope.Type is null)
        {
            return await KeyCountAsync(index, cancellationToken);
        }

        var step = KeyScanStep(index, scope);
        var cursor = "0";
        long count = 0;
        do
        {
            var (next, keys) = await step(cursor, cancellationToken);
            count += keys.Count;
            cursor = next;
        }
        while (cursor != "0");
        return count;
    }

    private static string PagerId(RedisKeyScope scope) => "SCAN\x1f" + scope.Pattern + "\x1f" + scope.Type;

    /// <summary>
    /// One SCAN call with the pattern and type. A cluster's cursor names the primary it is on as well, so the walk
    /// goes through each primary in turn. A server older than Redis 6.0 has no TYPE option, so its keys are typed
    /// after the scan and the others dropped.
    /// </summary>
    private RedisScanPager.ScanStep KeyScanStep(int index, RedisKeyScope scope)
    {
        var serverType = scope.Type is not null && RedisKeyBrowse.SupportsScanType(ServerVersion);
        var args = new List<object> { "0" };
        if (scope.Pattern is not null)
        {
            args.Add("MATCH");
            args.Add(scope.Pattern);
        }

        args.Add("COUNT");
        args.Add(ScanCount);
        if (serverType)
        {
            args.Add("TYPE");
            args.Add(scope.Type!);
        }

        var primaries = IsCluster ? Primaries() : null;
        var names = primaries?.Select(p => EndPointCollection.ToString(p.EndPoint)).ToArray();
        return async (cursor, cancellationToken) =>
        {
            var call = args.ToArray();
            RedisReply reply;
            string next;
            if (primaries is null || names is null)
            {
                call[0] = cursor;
                reply = RedisReply.From(await Database(index).ExecuteAsync("SCAN", call).WaitAsync(cancellationToken));
                next = reply.Items.Count < 2 ? "0" : reply.Items[0].Text ?? "0";
            }
            else
            {
                if (RedisClusterCursor.Decode(cursor, names) is not { } position)
                {
                    return ("0", []);
                }

                call[0] = position.Cursor;
                var server = primaries[Array.IndexOf(names, position.Node)];
                reply = RedisReply.From(await server.ExecuteAsync(index, "SCAN", call, CommandFlags.None).WaitAsync(cancellationToken));
                next = RedisClusterCursor.Advance(position.Node, reply.Items.Count < 2 ? "0" : reply.Items[0].Text ?? "0", names);
            }

            IReadOnlyList<RedisReply> keys = reply.Items.Count < 2 ? [] : reply.Items[1].Items;
            if (scope.Type is { } type && !serverType)
            {
                keys = await KeepTypeAsync(index, keys, type, cancellationToken);
            }

            return (next, keys);
        };
    }

    private async Task<IReadOnlyList<RedisReply>> KeepTypeAsync(int index, IReadOnlyList<RedisReply> keys, string type, CancellationToken cancellationToken)
    {
        var db = Database(index);
        var types = await Task.WhenAll(keys.Select(k => TryExecuteAsync(db, "TYPE", Key(k.Text ?? string.Empty)))).WaitAsync(cancellationToken);
        return keys.Where((_, i) => string.Equals(types[i]?.Text, type, StringComparison.OrdinalIgnoreCase)).ToArray();
    }

    /// <summary>
    /// Each key's type, TTL, length and value preview, pipelined: one round trip for the types and TTLs of a batch, one
    /// for the reads the types call for. A key that expired since the scan keeps its row as <c>none</c>, so the page
    /// stays as long as the scan found it.
    /// </summary>
    private async Task<List<object?[]>> DescribeKeyRowsAsync(int index, List<string> keys, CancellationToken cancellationToken)
    {
        var db = Database(index);
        var rows = new List<object?[]>(keys.Count);
        for (var start = 0; start < keys.Count; start += DescribeBatch)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var count = Math.Min(DescribeBatch, keys.Count - start);
            var typeTasks = new Task<RedisReply?>[count];
            var ttlTasks = new Task<RedisReply?>[count];
            for (var i = 0; i < count; i++)
            {
                typeTasks[i] = TryExecuteAsync(db, "TYPE", Key(keys[start + i]));
                ttlTasks[i] = TryExecuteAsync(db, "TTL", Key(keys[start + i]));
            }

            await Task.WhenAll(typeTasks.Concat(ttlTasks)).WaitAsync(cancellationToken);
            var types = new RedisKeyType[count];
            var lengthTasks = new Task<RedisReply?>?[count];
            var previewTasks = new Task<RedisReply?>?[count];
            for (var i = 0; i < count; i++)
            {
                var key = keys[start + i];
                types[i] = RedisKeyTypes.Parse(typeTasks[i].Result?.Text);
                if (RedisKeyBrowse.LengthCommand(types[i], key) is { } length)
                {
                    lengthTasks[i] = TryExecuteAsync(db, length.Verb, KeyFirst(length));
                }

                if (RedisKeyBrowse.PreviewCommand(types[i], key) is { } preview)
                {
                    previewTasks[i] = TryExecuteAsync(db, preview.Verb, KeyFirst(preview));
                }
            }

            await Task.WhenAll(lengthTasks.Concat(previewTasks).OfType<Task<RedisReply?>>()).WaitAsync(cancellationToken);
            for (var i = 0; i < count; i++)
            {
                rows.Add(RedisKeyBrowse.Row(
                    keys[start + i],
                    typeTasks[i].Result?.Text,
                    RedisKeyBrowse.Integer(ttlTasks[i].Result),
                    RedisKeyBrowse.Integer(lengthTasks[i]?.Result),
                    RedisKeyBrowse.Preview(types[i], previewTasks[i]?.Result)));
            }
        }

        return rows;
    }

    /// <summary>
    /// Saves edits to the list of keys in one MULTI/EXEC. A cluster runs one per hash slot, since a transaction cannot
    /// span slots; a slot that fails after others committed says how many did.
    /// </summary>
    private async Task<int> SaveKeysAsync(int index, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken)
    {
        var db = Database(index);
        var valueKeys = RedisKeyBrowse.KeysWritingValue(changes);
        var typeReplies = await Task.WhenAll(valueKeys.Select(k => db.ExecuteAsync("TYPE", Key(k)))).WaitAsync(cancellationToken);
        var types = new Dictionary<string, RedisKeyType>(valueKeys.Count, StringComparer.Ordinal);
        for (var i = 0; i < valueKeys.Count; i++)
        {
            types[valueKeys[i]] = RedisKeyTypes.Parse(typeReplies[i].ToString());
        }

        var writes = RedisKeyBrowse.Plan(changes, types);
        IReadOnlyList<IReadOnlyList<RedisKeyWrite>> groups = IsCluster ? RedisKeySlot.GroupBySlot(writes, w => w.Key) : [writes];
        var committed = 0;
        try
        {
            foreach (var group in groups)
            {
                var plan = new RedisWritePlan(group.SelectMany(w => w.Plan.Guards).ToArray(), group.SelectMany(w => w.Plan.Commands).ToArray());
                await RedisTransactionRunner.RunAsync(db, plan, cancellationToken);
                committed++;
            }
        }
        catch (Exception ex) when (committed > 0 && ex is RowCountMismatchException or RedisException or InvalidOperationException)
        {
            throw new InvalidOperationException(RedisStrings.Format("Redis/SlotsPartiallySaved", committed, groups.Count, ex.Message), ex);
        }
        finally
        {
            _pager.Forget(index, string.Empty);
        }

        return changes.Count;
    }

    // A planned command names its key first; typing it as a key routes the read to that key's primary on a cluster.
    private static object[] KeyFirst(RedisCommand command)
    {
        var args = new object[command.Args.Count];
        for (var i = 0; i < args.Length; i++)
        {
            args[i] = i == 0 ? Key(command.Args[i]) : command.Args[i];
        }

        return args;
    }
}
