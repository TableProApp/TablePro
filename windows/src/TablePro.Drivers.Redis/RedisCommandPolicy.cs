using System.Collections.Frozen;
using TablePro.Core.Sql;
using TablePro.Drivers.Redis.Localization;

namespace TablePro.Drivers.Redis;

/// <summary>Decides, before anything is sent, whether a command may run on the session's shared connection.</summary>
internal static class RedisCommandPolicy
{
    // Every tab shares one multiplexed connection, so a command that turns it into a push stream, blocks it, or
    // changes its login would stall or corrupt every other tab and the sidebar.
    private static readonly FrozenSet<string> Subscriptions = FrozenSet.Create(StringComparer.OrdinalIgnoreCase,
        ["SUBSCRIBE", "PSUBSCRIBE", "SSUBSCRIBE", "UNSUBSCRIBE", "PUNSUBSCRIBE", "SUNSUBSCRIBE", "MONITOR", "SYNC", "PSYNC", "REPLCONF"]);

    private static readonly FrozenSet<string> Blocking = FrozenSet.Create(StringComparer.OrdinalIgnoreCase,
        ["BLPOP", "BRPOP", "BRPOPLPUSH", "BLMOVE", "BLMPOP", "BZPOPMIN", "BZPOPMAX", "BZMPOP", "WAIT", "WAITAOF"]);

    private static readonly FrozenSet<string> ConnectionState = FrozenSet.Create(StringComparer.OrdinalIgnoreCase,
        ["AUTH", "HELLO", "QUIT", "RESET", "WATCH", "UNWATCH"]);

    /// <summary>Why the command cannot run, or <see langword="null"/> when it may.</summary>
    public static string? Refusal(string statement, IReadOnlyList<string> words, bool readOnly)
    {
        if (words.Count == 0)
        {
            return RedisStrings.Get("Redis/EmptyCommand");
        }

        var verb = words[0];
        if (Subscriptions.Contains(verb))
        {
            return RedisStrings.Format("Redis/Subscription", verb.ToUpperInvariant());
        }

        if (Blocking.Contains(verb) || (IsStreamRead(verb) && HasOption(words, "BLOCK")))
        {
            return RedisStrings.Format("Redis/Blocking", verb.ToUpperInvariant());
        }

        if (ConnectionState.Contains(verb))
        {
            return RedisStrings.Format("Redis/ConnectionState", verb.ToUpperInvariant());
        }

        if (words.Count >= 2 && verb.Equals("CLIENT", StringComparison.OrdinalIgnoreCase) && words[1].Equals("REPLY", StringComparison.OrdinalIgnoreCase))
        {
            return RedisStrings.Get("Redis/ClientReply");
        }

        if (readOnly && IsWrite(statement))
        {
            return RedisStrings.Format("Redis/ReadOnlyNotSent", verb.ToUpperInvariant());
        }

        return null;
    }

    /// <summary>A command Safe Mode does not list as a read counts as a write, so a new one is refused until listed.</summary>
    public static bool IsWrite(string statement) => RedisDialect.Instance.Classify(statement).IsWrite();

    private static bool IsStreamRead(string verb) =>
        verb.Equals("XREAD", StringComparison.OrdinalIgnoreCase) || verb.Equals("XREADGROUP", StringComparison.OrdinalIgnoreCase);

    private static bool HasOption(IReadOnlyList<string> words, string option)
    {
        for (var i = 1; i < words.Count; i++)
        {
            if (words[i].Equals("STREAMS", StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }

            if (words[i].Equals(option, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }
}
