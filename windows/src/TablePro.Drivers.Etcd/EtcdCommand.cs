using System.Globalization;
using System.Text;
using TablePro.Core.Localization;
using TablePro.Drivers.Etcd.Localization;

namespace TablePro.Drivers.Etcd;

/// <summary>A command the etcdctl-style parser could not read.</summary>
public sealed class EtcdCommandException : Exception
{
    public EtcdCommandException()
    {
    }

    public EtcdCommandException(string message)
        : base(message)
    {
    }

    public EtcdCommandException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

/// <summary>One etcdctl command, read into what the gateway call needs.</summary>
internal abstract record EtcdOperation;

/// <summary>
/// <c>get key [range_end] [--prefix] [--from-key] [--limit n] [--keys-only] [--count-only] [--order ASCEND|DESCEND]
/// [--sort-by KEY|VERSION|CREATE|MOD|VALUE] [--rev n]</c>.
/// </summary>
internal sealed record EtcdGet(
    string Key,
    string? RangeEnd = null,
    bool Prefix = false,
    bool FromKey = false,
    long Limit = 0,
    bool KeysOnly = false,
    bool CountOnly = false,
    string? SortOrder = null,
    string? SortTarget = null,
    long Revision = 0) : EtcdOperation;

internal sealed record EtcdPut(string Key, string Value, long? Lease = null, bool IgnoreLease = false) : EtcdOperation;

internal sealed record EtcdDelete(string Key, string? RangeEnd = null, bool Prefix = false, bool FromKey = false) : EtcdOperation;

internal sealed record EtcdWatch(string Key, bool Prefix, double TimeoutSeconds) : EtcdOperation;

internal sealed record EtcdLeaseGrant(long Ttl) : EtcdOperation;

internal sealed record EtcdLeaseRevoke(long LeaseId) : EtcdOperation;

internal sealed record EtcdLeaseTimeToLive(long LeaseId, bool Keys) : EtcdOperation;

internal sealed record EtcdLeaseList : EtcdOperation;

internal sealed record EtcdLeaseKeepAlive(long LeaseId) : EtcdOperation;

internal sealed record EtcdMemberList : EtcdOperation;

internal sealed record EtcdEndpointStatus : EtcdOperation;

internal sealed record EtcdEndpointHealth : EtcdOperation;

internal sealed record EtcdCompaction(long Revision, bool Physical) : EtcdOperation;

internal sealed record EtcdAuthToggle(bool Enable) : EtcdOperation;

internal sealed record EtcdUserAdd(string Name, string? Password) : EtcdOperation;

internal sealed record EtcdUserDelete(string Name) : EtcdOperation;

internal sealed record EtcdUserList : EtcdOperation;

internal sealed record EtcdUserGrantRole(string User, string Role) : EtcdOperation;

internal sealed record EtcdUserRevokeRole(string User, string Role) : EtcdOperation;

internal sealed record EtcdRoleAdd(string Name) : EtcdOperation;

internal sealed record EtcdRoleDelete(string Name) : EtcdOperation;

internal sealed record EtcdRoleList : EtcdOperation;

/// <summary>Reads etcdctl command lines, as the macOS driver's EtcdCommandParser does. Pure: no I/O.</summary>
internal static class EtcdCommandParser
{
    public const double DefaultWatchSeconds = 10;

    public const double MaximumWatchSeconds = 300;

    private static readonly System.Buffers.SearchValues<char> HexLetters = System.Buffers.SearchValues.Create("abcdefABCDEF");

    private static readonly HashSet<string> FlagsTakingValue = new(StringComparer.Ordinal)
    {
        "limit", "order", "sort-by", "rev", "lease", "timeout", "write-out", "consistency", "endpoints", "user", "password",
    };

    public static EtcdOperation Parse(string input)
    {
        var tokens = Tokenize(input.Trim());
        if (tokens.Count == 0)
        {
            throw new EtcdCommandException(EtcdStrings.Get("Etcd/EmptyCommand"));
        }

        var command = tokens[0].ToLowerInvariant();
        var rest = tokens.Skip(1).ToList();
        return command switch
        {
            "get" => ParseGet(rest),
            "put" => ParsePut(rest),
            "del" or "delete" => ParseDelete(rest),
            "watch" => ParseWatch(rest),
            "lease" => ParseLease(rest),
            "member" => Sub(rest, "member", "list", static (sub, _) => sub == "list" ? new EtcdMemberList() : null),
            "endpoint" => Sub(rest, "endpoint", "status, health", static (sub, _) => sub switch
            {
                "status" => new EtcdEndpointStatus(),
                "health" => new EtcdEndpointHealth(),
                _ => null,
            }),
            "compaction" => ParseCompaction(rest),
            "auth" => Sub(rest, "auth", "enable, disable", static (sub, _) => sub switch
            {
                "enable" => new EtcdAuthToggle(true),
                "disable" => new EtcdAuthToggle(false),
                _ => null,
            }),
            "user" => ParseUser(rest),
            "role" => ParseRole(rest),
            _ => throw new EtcdCommandException(EtcdStrings.Format("Etcd/UnknownCommandTry", tokens[0])),
        };
    }

    /// <summary>A lease ID as etcdctl prints it (hex) or as the API returns it (decimal).</summary>
    public static long ParseLeaseId(string text)
    {
        var span = text.AsSpan().Trim();
        var hex = span.StartsWith("0x", StringComparison.OrdinalIgnoreCase);
        if (hex)
        {
            span = span[2..];
        }

        if (!hex && span.IndexOfAny(HexLetters) < 0 && long.TryParse(span, NumberStyles.Integer, CultureInfo.InvariantCulture, out var value))
        {
            return value;
        }

        return long.TryParse(span, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out value)
            ? value
            : throw new EtcdCommandException(EtcdStrings.Format("Etcd/InvalidLeaseId", text));
    }

    public static string LeaseHex(long leaseId) => "0x" + leaseId.ToString("x", CultureInfo.InvariantCulture);

    /// <summary>Splits on whitespace, keeping quoted text whole and reading backslash escapes inside quotes.</summary>
    public static List<string> Tokenize(string input)
    {
        var tokens = new List<string>();
        var current = new StringBuilder();
        char? quote = null;
        var started = false;
        for (var i = 0; i < input.Length; i++)
        {
            var c = input[i];
            if (quote is { } q)
            {
                if (c == '\\' && i + 1 < input.Length)
                {
                    var next = input[++i];
                    current.Append(next switch
                    {
                        'n' => "\n",
                        'r' => "\r",
                        't' => "\t",
                        '\\' or '"' or '\'' => next.ToString(),
                        _ => "\\" + next,
                    });
                }
                else if (c == q)
                {
                    quote = null;
                }
                else
                {
                    current.Append(c);
                }

                continue;
            }

            if (c is '"' or '\'')
            {
                quote = c;
                started = true;
            }
            else if (char.IsWhiteSpace(c))
            {
                if (started)
                {
                    tokens.Add(current.ToString());
                    current.Clear();
                    started = false;
                }
            }
            else
            {
                current.Append(c);
                started = true;
            }
        }

        if (quote is not null)
        {
            throw new EtcdCommandException(CoreStrings.Get("Driver/QuotedValueNotClosed"));
        }

        if (started)
        {
            tokens.Add(current.ToString());
        }

        return tokens;
    }

    private static EtcdGet ParseGet(List<string> tokens)
    {
        var flags = Flags.Read(tokens);
        var key = flags.Positional.Count > 0 ? flags.Positional[0] : throw new EtcdCommandException(EtcdStrings.Format("Etcd/NeedsKey", "get"));
        var rangeEnd = flags.Positional.Count > 1 ? flags.Positional[1] : null;
        var order = flags.Value("order")?.ToUpperInvariant();
        if (order is not (null or "ASCEND" or "DESCEND"))
        {
            throw new EtcdCommandException(EtcdStrings.Get("Etcd/OrderFlag"));
        }

        var sortBy = flags.Value("sort-by")?.ToUpperInvariant();
        if (sortBy is not (null or "KEY" or "VERSION" or "CREATE" or "MOD" or "VALUE"))
        {
            throw new EtcdCommandException(EtcdStrings.Get("Etcd/SortByFlag"));
        }

        var get = new EtcdGet(
            key,
            rangeEnd,
            flags.Has("prefix"),
            flags.Has("from-key"),
            Integer(flags.Value("limit"), "--limit"),
            flags.Has("keys-only"),
            flags.Has("count-only"),
            order,
            sortBy,
            Integer(flags.Value("rev"), "--rev"));
        if (get.Limit < 0 || get.Revision < 0)
        {
            throw new EtcdCommandException(EtcdStrings.Get("Etcd/NegativeLimit"));
        }

        if (get.Prefix && get.FromKey)
        {
            throw new EtcdCommandException(EtcdStrings.Get("Etcd/PrefixAndFromKey"));
        }

        return get;
    }

    private static EtcdPut ParsePut(List<string> tokens)
    {
        var flags = Flags.Read(tokens);
        if (flags.Positional.Count < 2)
        {
            throw new EtcdCommandException(EtcdStrings.Get("Etcd/PutNeedsKeyAndValue"));
        }

        if (flags.Positional.Count > 2)
        {
            throw new EtcdCommandException(EtcdStrings.Get("Etcd/PutTakesOne"));
        }

        var lease = flags.Value("lease") is { } text ? ParseLeaseId(text) : (long?)null;
        return new EtcdPut(flags.Positional[0], flags.Positional[1], lease, flags.Has("ignore-lease"));
    }

    private static EtcdDelete ParseDelete(List<string> tokens)
    {
        var flags = Flags.Read(tokens);
        var key = flags.Positional.Count > 0 ? flags.Positional[0] : throw new EtcdCommandException(EtcdStrings.Format("Etcd/NeedsKey", "del"));
        if (flags.Has("prefix") && flags.Has("from-key"))
        {
            throw new EtcdCommandException(EtcdStrings.Get("Etcd/PrefixAndFromKey"));
        }

        return new EtcdDelete(key, flags.Positional.Count > 1 ? flags.Positional[1] : null, flags.Has("prefix"), flags.Has("from-key"));
    }

    private static EtcdWatch ParseWatch(List<string> tokens)
    {
        var flags = Flags.Read(tokens);
        var key = flags.Positional.Count > 0 ? flags.Positional[0] : throw new EtcdCommandException(EtcdStrings.Format("Etcd/NeedsKey", "watch"));
        var timeout = DefaultWatchSeconds;
        if (flags.Value("timeout") is { } text)
        {
            if (!double.TryParse(text.TrimEnd('s'), NumberStyles.Float, CultureInfo.InvariantCulture, out timeout) || !double.IsFinite(timeout))
            {
                throw new EtcdCommandException(EtcdStrings.Get("Etcd/TimeoutNumber"));
            }

            if (timeout < 0 || timeout > MaximumWatchSeconds)
            {
                throw new EtcdCommandException(EtcdStrings.Format("Etcd/TimeoutRange", MaximumWatchSeconds));
            }
        }

        return new EtcdWatch(key, flags.Has("prefix"), timeout);
    }

    private static EtcdOperation ParseLease(List<string> tokens)
    {
        if (tokens.Count == 0)
        {
            throw new EtcdCommandException(EtcdStrings.Format("Etcd/NeedsSubcommand", "lease", "grant, revoke, timetolive, list, keep-alive"));
        }

        var args = tokens.Skip(1).ToList();
        var flags = Flags.Read(args);
        string Id(string sub) => flags.Positional.Count > 0 ? flags.Positional[0] : throw new EtcdCommandException(EtcdStrings.Format("Etcd/NeedsLeaseId", "lease " + sub));
        return tokens[0].ToLowerInvariant() switch
        {
            "grant" => new EtcdLeaseGrant(flags.Positional.Count > 0 && long.TryParse(flags.Positional[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var ttl) && ttl > 0
                ? ttl
                : throw new EtcdCommandException(EtcdStrings.Get("Etcd/LeaseGrantTtl"))),
            "revoke" => new EtcdLeaseRevoke(ParseLeaseId(Id("revoke"))),
            "timetolive" => new EtcdLeaseTimeToLive(ParseLeaseId(Id("timetolive")), flags.Has("keys")),
            "list" => new EtcdLeaseList(),
            "keep-alive" => new EtcdLeaseKeepAlive(ParseLeaseId(Id("keep-alive"))),
            var other => throw new EtcdCommandException(EtcdStrings.Format("Etcd/UnknownCommand", "lease " + other)),
        };
    }

    private static EtcdCompaction ParseCompaction(List<string> tokens)
    {
        var flags = Flags.Read(tokens);
        return flags.Positional.Count > 0 && long.TryParse(flags.Positional[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var revision) && revision > 0
            ? new EtcdCompaction(revision, flags.Has("physical"))
            : throw new EtcdCommandException(EtcdStrings.Get("Etcd/CompactionNeedsRevision"));
    }

    private static EtcdOperation ParseUser(List<string> tokens)
    {
        if (tokens.Count == 0)
        {
            throw new EtcdCommandException(EtcdStrings.Format("Etcd/NeedsSubcommand", "user", "add, delete, list, grant-role, revoke-role"));
        }

        var args = tokens.Skip(1).ToList();
        return tokens[0].ToLowerInvariant() switch
        {
            "add" => args.Count > 0 ? new EtcdUserAdd(args[0], args.Count > 1 ? args[1] : null) : throw new EtcdCommandException(EtcdStrings.Format("Etcd/NeedsUserName", "user add")),
            "delete" => args.Count > 0 ? new EtcdUserDelete(args[0]) : throw new EtcdCommandException(EtcdStrings.Format("Etcd/NeedsUserName", "user delete")),
            "list" => new EtcdUserList(),
            "grant-role" => args.Count > 1 ? new EtcdUserGrantRole(args[0], args[1]) : throw new EtcdCommandException(EtcdStrings.Format("Etcd/NeedsUserAndRole", "user grant-role")),
            "revoke-role" => args.Count > 1 ? new EtcdUserRevokeRole(args[0], args[1]) : throw new EtcdCommandException(EtcdStrings.Format("Etcd/NeedsUserAndRole", "user revoke-role")),
            var other => throw new EtcdCommandException(EtcdStrings.Format("Etcd/UnknownCommand", "user " + other)),
        };
    }

    private static EtcdOperation ParseRole(List<string> tokens)
    {
        if (tokens.Count == 0)
        {
            throw new EtcdCommandException(EtcdStrings.Format("Etcd/NeedsSubcommand", "role", "add, delete, list"));
        }

        var args = tokens.Skip(1).ToList();
        return tokens[0].ToLowerInvariant() switch
        {
            "add" => args.Count > 0 ? new EtcdRoleAdd(args[0]) : throw new EtcdCommandException(EtcdStrings.Format("Etcd/NeedsRoleName", "role add")),
            "delete" => args.Count > 0 ? new EtcdRoleDelete(args[0]) : throw new EtcdCommandException(EtcdStrings.Format("Etcd/NeedsRoleName", "role delete")),
            "list" => new EtcdRoleList(),
            var other => throw new EtcdCommandException(EtcdStrings.Format("Etcd/UnknownCommand", "role " + other)),
        };
    }

    private static EtcdOperation Sub(List<string> tokens, string command, string choices, Func<string, List<string>, EtcdOperation?> pick)
    {
        if (tokens.Count == 0)
        {
            throw new EtcdCommandException(EtcdStrings.Format("Etcd/NeedsSubcommand", command, choices));
        }

        return pick(tokens[0].ToLowerInvariant(), tokens) ?? throw new EtcdCommandException(EtcdStrings.Format("Etcd/UnknownCommand", command + " " + tokens[0]));
    }

    private static long Integer(string? text, string flag) =>
        text is null ? 0
        : long.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) ? value
        : throw new EtcdCommandException(EtcdStrings.Format("Etcd/WholeNumber", flag));

    /// <summary>etcdctl's flags: <c>--name value</c>, <c>--name=value</c> and bare switches.</summary>
    private sealed class Flags
    {
        private readonly HashSet<string> _switches = new(StringComparer.Ordinal);
        private readonly Dictionary<string, string> _values = new(StringComparer.Ordinal);

        public List<string> Positional { get; } = [];

        public static Flags Read(List<string> tokens)
        {
            var flags = new Flags();
            for (var i = 0; i < tokens.Count; i++)
            {
                var token = tokens[i];
                if (!token.StartsWith("--", StringComparison.Ordinal) || token.Length == 2)
                {
                    flags.Positional.Add(token);
                    continue;
                }

                var body = token[2..];
                var equals = body.IndexOf('=', StringComparison.Ordinal);
                if (equals >= 0)
                {
                    flags._values[body[..equals]] = body[(equals + 1)..];
                }
                else if (FlagsTakingValue.Contains(body))
                {
                    flags._values[body] = i + 1 < tokens.Count && !tokens[i + 1].StartsWith("--", StringComparison.Ordinal)
                        ? tokens[++i]
                        : throw new EtcdCommandException($"--{body} needs a value.");
                }
                else
                {
                    flags._switches.Add(body);
                }
            }

            return flags;
        }

        public bool Has(string name) => _switches.Contains(name) || (_values.TryGetValue(name, out var value) && value is "true" or "1");

        public string? Value(string name) => _values.TryGetValue(name, out var value) ? value : null;
    }
}
