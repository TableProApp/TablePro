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
/// connection, so its <c>SELECT</c> and transaction stay with it.
/// </summary>
internal sealed class RedisQueryChannel : IQueryChannel
{
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
                    var replies = await ExecAsync(commands);
                    return Done(RedisReplyShaper.Shape(words, RedisReply.Array(replies), options.RowLimit), commands.Count);
            }

            if (_queued is not null)
            {
                _queued.Add(words);
                return Message("QUEUED");
            }

            var db = _session.Database(DatabaseIndex);
            var pending = db.ExecuteAsync(words[0], words.Skip(1).Cast<object>().ToArray());
            var result = await Wait(pending, options, cancellationToken);
            var reply = RedisReply.From(result);
            var affected = RedisCommandPolicy.IsWrite(statement) ? (reply.Kind == RedisReplyKind.Integer && int.TryParse(reply.Text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var n) ? n : 0) : -1;
            return Done(RedisReplyShaper.Shape(words, reply, options.RowLimit), affected);
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

        var size = await Wait(_session.Database(index).ExecuteAsync("DBSIZE"), options, cancellationToken);
        DatabaseIndex = index;
        return (null, (long)size);
    }

    private async Task<RedisReply[]> ExecAsync(List<IReadOnlyList<string>> commands)
    {
        var transaction = _session.Database(DatabaseIndex).CreateTransaction();
        var tasks = commands.Select(c => transaction.ExecuteAsync(c[0], c.Skip(1).Cast<object>().ToArray())).ToArray();

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

    private static Task<RedisResult> Wait(Task<RedisResult> pending, ExecuteOptions options, CancellationToken cancellationToken) =>
        options.CommandTimeoutSeconds > 0
            ? pending.WaitAsync(TimeSpan.FromSeconds(options.CommandTimeoutSeconds), cancellationToken)
            : pending.WaitAsync(cancellationToken);

    public ValueTask DisposeAsync()
    {
        _queued = null;
        return ValueTask.CompletedTask;
    }
}
