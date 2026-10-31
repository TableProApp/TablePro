using System.Text;

namespace TablePro.Drivers.Redis;

/// <summary>One command and its arguments, kept apart so values are sent as arguments and never parsed from text.</summary>
internal sealed record RedisCommand(string Verb, IReadOnlyList<string> Args)
{
    public RedisCommand(string verb, params string[] args)
        : this(verb, (IReadOnlyList<string>)args)
    {
    }

    /// <summary>The command as a redis-cli line, for history and error messages.</summary>
    public override string ToString()
    {
        var builder = new StringBuilder(Verb);
        foreach (var arg in Args)
        {
            builder.Append(' ').Append(Quote(arg));
        }

        return builder.ToString();
    }

    public bool Equals(RedisCommand? other) =>
        other is not null && Verb == other.Verb && Args.SequenceEqual(other.Args, StringComparer.Ordinal);

    public override int GetHashCode() => HashCode.Combine(Verb, Args.Count);

    /// <summary>Quotes an argument the way <c>CommandWords.Read</c> reads it back.</summary>
    public static string Quote(string arg)
    {
        if (arg.Length > 0 && !arg.Any(c => char.IsWhiteSpace(c) || c is '"' or '\'' or '\\'))
        {
            return arg;
        }

        var builder = new StringBuilder(arg.Length + 2).Append('"');
        foreach (var c in arg)
        {
            builder.Append(c switch
            {
                '"' => "\\\"",
                '\\' => "\\\\",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                _ => c.ToString(),
            });
        }

        return builder.Append('"').ToString();
    }
}

internal enum RedisGuardKind
{
    KeyExists,
    KeyMissing,
    StringEquals,
    HashFieldExists,
    HashFieldMissing,
    HashFieldEquals,
    ListIndexExists,
    SetContains,
    SortedSetContains,
}

/// <summary>
/// A condition the transaction checks before it runs. A row the grid showed that is gone, or a field a save would
/// overwrite, makes the whole transaction run nothing, as a keyed SQL update that hits no row rolls back.
/// </summary>
internal sealed record RedisGuard(RedisGuardKind Kind, string Key, string? Member = null, string? Value = null, long Index = 0);

internal sealed record RedisWritePlan(IReadOnlyList<RedisGuard> Guards, IReadOnlyList<RedisCommand> Commands);
