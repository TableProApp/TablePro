using System.Diagnostics;
using System.Globalization;
using System.Runtime.CompilerServices;
using StackExchange.Redis;
using TablePro.Core.Drivers;
using TablePro.Core.Results;
using TablePro.Core.Sql;

namespace TablePro.Drivers.Redis;

/// <summary>
/// One editor tab's commands. The tab keeps its own database number and its own MULTI queue over the session's shared
/// connection, so its <c>SELECT</c> and transaction stay with it. On a cluster a command reaches the nodes its
/// keys or its kind need: a key's owner, every primary for DBSIZE or KEYS, each slot's owner for a split DEL.
/// </summary>
internal sealed class RedisQueryChannel : IQueryChannel
{
    private const string CrossSlotTransaction =
        "CROSSSLOT The queued commands touch keys in more than one hash slot, which a cluster cannot run in one transaction. Give the keys a shared {hash tag} so they land in one slot.";

    private readonly RedisSession _session;
    private readonly bool _readOnly;
    private List<IReadOnlyList<string>>? _queued;

    public RedisQueryChannel(RedisSession session, int database, bool readOnly)
    {
        _session = session;
        DatabaseIndex = database;
        _readOnly = readOnly;
    }

    public int DatabaseIndex { get; private set; }

    public bool InTransaction => _queued is not null;

    public async IAsyncEnumerable<StatementResult> ExecuteAsync(IReadOnlyList<string> statements, ExecuteOptions options, [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        foreach (var statement in statements)
        {
            var result = await RunAsync(statement, options, cancellationToken);
            yield return result;
            if (!result.Succeeded && (options.StopOnError || cancellationToken.IsCancellationRequested))
            {
                yield break;
            }
        }
    }

    private async Task<StatementResult> RunAsync(string statement, ExecuteOptions options, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var stopwatch = Stopwatch.StartNew();
        var words = CommandWords.Read(statement);
        var verb = words.Count > 0 ? words[0].ToUpperInvariant() : string.Empty;
        StatementResult Fail(string error) => new(statement, [], -1, stopwatch.Elapsed, error);
        StatementResult Done(ShapedReply shaped, int affected) => new(statement, shaped.ResultSets, affected, stopwatch.Elapsed, Messages: shaped.Messages);
        StatementResult Message(string message) => new(statement, [], 0, stopwatch.Elapsed, Messages: [message]);

        if (verb is not ("MULTI" or "EXEC" or "DISCARD" or "SELECT") && RedisCommandPolicy.Refusal(statement, words, _readOnly) is { } refusal)
        {
            return Fail(refusal);
        }

        try
        {
            switch (verb)
            {
                case "SELECT":
                {
                    var (error, keys) = await SelectAsync(words, options, cancellationToken);
                    return error is not null
                        ? Fail(error)
                        : Message(string.Create(CultureInfo.InvariantCulture, $"Database {DatabaseIndex} selected, {keys} keys."));
                }

                case "MULTI":
                    if (_readOnly)
                    {
                        return Fail("This connection is read-only, so MULTI was not sent.");
                    }

                    if (_queued is not null)
                    {
                        return Fail("ERR MULTI calls can not be nested");
                    }

                    _queued = [];
                    return Message("OK");
                case "DISCARD":
                    if (_queued is null)
                    {
                        return Fail("ERR DISCARD without MULTI");
                    }

                    _queued = null;
                    return Message("OK");
                case "EXEC":
                    if (_queued is null)
                    {
                        return Fail("ERR EXEC without MULTI");
                    }

                    var commands = _queued;
                    _queued = null;
                    if (_session.IsCluster && commands.SelectMany(RedisCommandRouting.Slots).Distinct().Count() > 1)
                    {
                        return Fail(CrossSlotTransaction);
                    }

                    var replies = await ExecAsync(commands);
                    return Done(RedisReplyShaper.Shape(words, RedisReply.Array(replies), options.RowLimit), commands.Count);
            }

            if (_queued is not null)
            {
                _queued.Add(words);
                return Message("QUEUED");
            }

            RedisReply reply;
            string? note = null;
            if (_session.IsCluster)
            {
                (reply, note) = await Wait(RunOnClusterAsync(words, cancellationToken), options, cancellationToken);
                if (reply.Kind == RedisReplyKind.Error)
                {
                    return Fail(note is null ? reply.Text ?? "ERR" : $"{reply.Text} ({note})");
                }
            }
            else
            {
                reply = RedisReply.From(await Wait(_session.Database(DatabaseIndex).ExecuteAsync(words[0], Arguments(words)), options, cancellationToken));
            }

            var affected = RedisCommandPolicy.IsWrite(statement) ? (reply.Kind == RedisReplyKind.Integer && int.TryParse(reply.Text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var n) ? n : 0) : -1;
            var shaped = RedisReplyShaper.Shape(words, reply, options.RowLimit);
            return Done(note is null ? shaped : shaped with { Messages = [.. shaped.Messages, note] }, affected);
        }
        catch (OperationCanceledException)
        {
            return Fail("Query cancelled.");
        }
        catch (RedisTimeoutException ex)
        {
            return Fail(ex.Message);
        }
        catch (TimeoutException)
        {
            return Fail(string.Create(CultureInfo.InvariantCulture, $"The command did not finish within {options.CommandTimeoutSeconds} seconds."));
        }
        catch (Exception ex) when (ex is RedisException or RedisCommandException or ArgumentException or InvalidOperationException or NotSupportedException or InvalidCastException)
        {
            return Fail(ex.Message);
        }
    }

    /// <summary>
    /// Sends one command to the nodes it needs and combines their replies, as macOS's cluster channel does from the
    /// command's request and response policies. A node that refuses its part comes back as an error reply.
    /// </summary>
    private async Task<(RedisReply Reply, string? Note)> RunOnClusterAsync(IReadOnlyList<string> words, CancellationToken cancellationToken)
    {
        var spec = RedisCommandRouting.Spec(words);
        if (spec is { Name: "scan" })
        {
            return await ScanClusterAsync(words, cancellationToken);
        }

        var db = _session.Database(0);
        switch (spec?.FanOut ?? RedisClusterFanOut.Single)
        {
            case RedisClusterFanOut.EveryPrimary or RedisClusterFanOut.EveryNode:
            {
                var nodes = spec!.Value.FanOut == RedisClusterFanOut.EveryNode ? _session.Nodes() : _session.Primaries();
                var rest = words.Skip(1).Cast<object>().ToArray();
                var replies = await Task.WhenAll(nodes.Select(node => PartAsync(node.ExecuteAsync(0, words[0], rest, CommandFlags.None))));
                return (RedisClusterAggregator.Combine(replies, spec.Value.Response), null);
            }

            case RedisClusterFanOut.KeyedShards when RedisMultiShardPlanner.Split(words, spec!.Value) is { } parts:
            {
                var replies = await Task.WhenAll(parts.Select(part => PartAsync(db.ExecuteAsync(part.Words[0], Arguments(part.Words)))));
                cancellationToken.ThrowIfCancellationRequested();
                var combined = spec.Value.Response == RedisResponsePolicy.None
                    ? RedisMultiShardPlanner.ScatterInKeyOrder(parts, replies, spec.Value.KeyIndices(words.Count))
                    : RedisClusterAggregator.Combine(replies, spec.Value.Response);

                // Nothing ties the parts together, so a write one slot refused may have run on the others.
                var ran = replies.Count(r => r.Kind != RedisReplyKind.Error);
                var note = spec.Value.IsWrite && ran > 0 && ran < replies.Length
                    ? string.Create(CultureInfo.InvariantCulture, $"{ran} of {replies.Length} hash slots ran their part before another refused; those changes stay applied.")
                    : null;
                return (combined, note);
            }

            default:
                // A node command goes to the home node, so CLIENT LIST and CLIENT KILL talk about the same clients.
                var pending = RedisCommandRouting.IsNodeCommand(words) && RedisCommandRouting.KeyIndices(words).Count == 0
                    ? _session.Home.ExecuteAsync(words[0], words.Skip(1).Cast<object>().ToArray())
                    : db.ExecuteAsync(words[0], Arguments(words));
                return (await PartAsync(pending), null);
        }
    }

    /// <summary>SCAN walks the primaries one after another; the cursor it hands back names the node it got to.</summary>
    private async Task<(RedisReply Reply, string? Note)> ScanClusterAsync(IReadOnlyList<string> words, CancellationToken cancellationToken)
    {
        var primaries = _session.Primaries();
        var names = primaries.Select(p => EndPointCollection.ToString(p.EndPoint)).ToArray();
        if (RedisClusterCursor.Decode(words.Count > 1 ? words[1] : RedisClusterCursor.Start, names) is not { } position)
        {
            return (RedisReply.Array(RedisReply.Bulk(RedisClusterCursor.Start), RedisReply.Array()), null);
        }

        var server = primaries[Array.FindIndex(names, n => string.Equals(n, position.Node, StringComparison.OrdinalIgnoreCase))];
        object[] args = [position.Cursor, .. words.Skip(2)];
        var reply = await PartAsync(server.ExecuteAsync(0, "SCAN", args, CommandFlags.None));
        cancellationToken.ThrowIfCancellationRequested();
        if (reply.Kind == RedisReplyKind.Error || reply.Items.Count < 2)
        {
            return (reply, null);
        }

        var next = RedisClusterCursor.Advance(position.Node, reply.Items[0].Text ?? RedisClusterCursor.Start, names);
        var note = position.Restarted ? "The cursor named a node the cluster no longer has, so the scan started again from the first primary." : null;
        return (RedisReply.Array(RedisReply.Bulk(next), reply.Items[1]), note);
    }

    private static async Task<RedisReply> PartAsync(Task<RedisResult> pending)
    {
        try
        {
            return RedisReply.From(await pending);
        }
        catch (RedisServerException ex)
        {
            return RedisReply.Error(ex.Message);
        }
    }

    /// <summary>Moves the tab to another database after checking it exists, which DBSIZE there proves.</summary>
    private async Task<(string? Error, long Keys)> SelectAsync(IReadOnlyList<string> words, ExecuteOptions options, CancellationToken cancellationToken)
    {
        if (words.Count != 2 || !int.TryParse(words[1], NumberStyles.None, CultureInfo.InvariantCulture, out var index))
        {
            return ("ERR SELECT takes one database number, such as SELECT 1", 0);
        }

        if (_queued is not null)
        {
            return ("SELECT cannot be queued inside MULTI here. Select the database before MULTI.", 0);
        }

        if (_session.IsCluster)
        {
            if (index != 0)
            {
                return ("ERR SELECT is not allowed in cluster mode: Redis Cluster serves database 0 only.", 0);
            }

            var sizes = await Task.WhenAll(_session.Primaries().Select(p => PartAsync(p.ExecuteAsync("DBSIZE"))));
            var total = RedisClusterAggregator.Combine(sizes, RedisResponsePolicy.AggSum);
            return total.Kind == RedisReplyKind.Error ? (total.Text, 0) : (null, long.Parse(total.Text ?? "0", CultureInfo.InvariantCulture));
        }

        var size = await Wait(_session.Database(index).ExecuteAsync("DBSIZE"), options, cancellationToken);
        DatabaseIndex = index;
        return (null, (long)size);
    }

    private async Task<RedisReply[]> ExecAsync(List<IReadOnlyList<string>> commands)
    {
        // Keys go in typed as keys, which on a cluster sends the transaction to the primary that owns their one slot.
        var transaction = _session.Database(DatabaseIndex).CreateTransaction();
        var tasks = commands.Select(c => transaction.ExecuteAsync(c[0], Arguments(c))).ToArray();

        // EXEC is never abandoned half way: the server runs the whole queue, and its replies say what each did.
        await transaction.ExecuteAsync();
        var replies = new RedisReply[tasks.Length];
        for (var i = 0; i < tasks.Length; i++)
        {
            try
            {
                replies[i] = RedisReply.From(await tasks[i]);
            }
            catch (RedisServerException ex)
            {
                replies[i] = RedisReply.Error(ex.Message);
            }
            catch (TaskCanceledException)
            {
                replies[i] = RedisReply.Error("not run");
            }
        }

        return replies;
    }

    /// <summary>A command's arguments with its keys typed as keys, so the library can route by them.</summary>
    internal static object[] Arguments(IReadOnlyList<string> words)
    {
        var args = new object[Math.Max(0, words.Count - 1)];
        for (var i = 1; i < words.Count; i++)
        {
            args[i - 1] = words[i];
        }

        foreach (var index in RedisCommandRouting.KeyIndices(words))
        {
            args[index - 1] = (RedisKey)words[index];
        }

        return args;
    }

    private static Task<T> Wait<T>(Task<T> pending, ExecuteOptions options, CancellationToken cancellationToken) =>
        options.CommandTimeoutSeconds > 0
            ? pending.WaitAsync(TimeSpan.FromSeconds(options.CommandTimeoutSeconds), cancellationToken)
            : pending.WaitAsync(cancellationToken);

    public ValueTask DisposeAsync()
    {
        _queued = null;
        return ValueTask.CompletedTask;
    }
}
