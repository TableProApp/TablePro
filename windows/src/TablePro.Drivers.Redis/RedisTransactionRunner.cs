using System.Globalization;
using StackExchange.Redis;
using TablePro.Core.Editing;

namespace TablePro.Drivers.Redis;

/// <summary>
/// Runs a write plan as one MULTI/EXEC. The guards go in as WATCH conditions, so a row that changed under the grid
/// makes the server run nothing at all.
/// </summary>
internal static class RedisTransactionRunner
{
    public static async Task RunAsync(IDatabase db, RedisWritePlan plan, CancellationToken cancellationToken)
    {
        var transaction = db.CreateTransaction();
        foreach (var guard in plan.Guards)
        {
            transaction.AddCondition(ToCondition(guard));
        }

        var queued = new Task[plan.Commands.Count];
        for (var i = 0; i < plan.Commands.Count; i++)
        {
            queued[i] = Queue(transaction, plan.Commands[i]);
        }

        // Once EXEC is sent the server finishes the transaction whatever the caller does, so the wait is not cut short.
        var committed = await transaction.ExecuteAsync();
        if (!committed)
        {
            var statement = string.Join("; ", plan.Commands);
            throw new RowCountMismatchException(plan.Guards.Count, 0, statement);
        }

        var failures = new List<string>();
        for (var i = 0; i < queued.Length; i++)
        {
            try
            {
                await queued[i];
            }
            catch (RedisServerException ex)
            {
                failures.Add($"{plan.Commands[i]}: {ex.Message}");
            }
        }

        cancellationToken.ThrowIfCancellationRequested();
        if (failures.Count > 0)
        {
            // Redis has no rollback: EXEC runs every queued command even after one fails.
            throw new InvalidOperationException("Redis ran the save, but some commands failed and the rest stayed applied: " + string.Join(" | ", failures));
        }
    }

    internal static Condition ToCondition(RedisGuard guard) => guard.Kind switch
    {
        RedisGuardKind.KeyExists => Condition.KeyExists(guard.Key),
        RedisGuardKind.StringEquals => Condition.StringEqual(guard.Key, guard.Value),
        RedisGuardKind.HashFieldExists => Condition.HashExists(guard.Key, guard.Member),
        RedisGuardKind.HashFieldMissing => Condition.HashNotExists(guard.Key, guard.Member),
        RedisGuardKind.HashFieldEquals => Condition.HashEqual(guard.Key, guard.Member, guard.Value),
        RedisGuardKind.ListIndexExists => Condition.ListIndexExists(guard.Key, guard.Index),
        RedisGuardKind.SetContains => Condition.SetContains(guard.Key, guard.Member),
        RedisGuardKind.SortedSetContains => Condition.SortedSetContains(guard.Key, guard.Member),
        _ => throw new ArgumentOutOfRangeException(nameof(guard)),
    };

    // Typed calls where the library has them, so the transaction queues commands it knows; module commands such as
    // JSON.SET go through the generic path.
    private static Task Queue(ITransaction t, RedisCommand command)
    {
        var a = command.Args;
        return command.Verb switch
        {
            "SET" => t.StringSetAsync(a[0], a[1], null, keepTtl: true, When.Always, CommandFlags.None),
            "DEL" => t.KeyDeleteAsync(a[0]),
            "HSET" => t.HashSetAsync(a[0], a[1], a[2]),
            "HDEL" => t.HashDeleteAsync(a[0], a[1]),
            "LSET" => t.ListSetByIndexAsync(a[0], long.Parse(a[1], CultureInfo.InvariantCulture), a[2]),
            "LREM" => t.ListRemoveAsync(a[0], a[2], long.Parse(a[1], CultureInfo.InvariantCulture)),
            "RPUSH" => t.ListRightPushAsync(a[0], a[1]),
            "SADD" => t.SetAddAsync(a[0], a[1]),
            "SREM" => t.SetRemoveAsync(a[0], a[1]),
            "ZADD" => t.SortedSetAddAsync(a[0], a[2], RedisReplyShaper.ParseScore(a[1]) ?? 0),
            "ZREM" => t.SortedSetRemoveAsync(a[0], a[1]),
            "XDEL" => t.StreamDeleteAsync(a[0], [a[1]]),
            "XADD" => t.StreamAddAsync(
                a[0],
                StreamFields(a),
                messageId: a[1] == "*" ? null : (RedisValue?)a[1],
                maxLength: (int?)null,
                useApproximateMaxLength: false,
                flags: CommandFlags.None),
            _ => t.ExecuteAsync(command.Verb, KeyFirst(a)),
        };
    }

    // Every planned command names its key first; typing it as a key routes the transaction to that key's primary on a cluster.
    private static object[] KeyFirst(IReadOnlyList<string> args)
    {
        var typed = new object[args.Count];
        for (var i = 0; i < args.Count; i++)
        {
            typed[i] = i == 0 ? (RedisKey)args[i] : args[i];
        }

        return typed;
    }

    private static NameValueEntry[] StreamFields(IReadOnlyList<string> args)
    {
        var fields = new NameValueEntry[(args.Count - 2) / 2];
        for (var i = 0; i < fields.Length; i++)
        {
            fields[i] = new NameValueEntry(args[2 + (i * 2)], args[3 + (i * 2)]);
        }

        return fields;
    }
}
