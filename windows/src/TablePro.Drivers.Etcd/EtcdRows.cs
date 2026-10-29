using System.Text;
using System.Text.Unicode;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Drivers.Etcd.Localization;

namespace TablePro.Drivers.Etcd;

/// <summary>How etcd keys and values become grid rows, and which key range a sidebar entry stands for. Pure.</summary>
internal static class EtcdRows
{
    public const string KeyColumn = "key";
    public const string ValueColumn = "value";
    public const string VersionColumn = "version";
    public const string CreateRevisionColumn = "create_revision";
    public const string ModRevisionColumn = "mod_revision";
    public const string LeaseColumn = "lease";

    // Built on each read, so the comments are worded in the language of the moment: a list cached on first use could
    // keep the English an MCP request reads.
    public static IReadOnlyList<ColumnInfo> Columns =>
    [
        new(KeyColumn, "TEXT", false, null, true, false, 0),
        new(ValueColumn, "TEXT", true, null, false, false, 1),
        new(VersionColumn, "BIGINT", false, null, false, false, 2, EtcdStrings.Get("Etcd/VersionComment")),
        new(CreateRevisionColumn, "BIGINT", false, null, false, false, 3),
        new(ModRevisionColumn, "BIGINT", false, null, false, false, 4),
        new(LeaseColumn, "TEXT", true, null, false, false, 5, EtcdStrings.Get("Etcd/LeaseComment")),
    ];

    /// <summary>
    /// Maps key-values to rows. Keys and values are bytes with no declared type, so each column is text when every
    /// value on the page is valid UTF-8 and bytes otherwise; deciding per page keeps the column type and its cells agreeing.
    /// </summary>
    public static ResultSet ToResultSet(IReadOnlyList<EtcdKeyValue> kvs, bool isTruncated = false)
    {
        var keysAreText = kvs.All(kv => IsText(kv.Key));
        var valuesAreText = kvs.All(kv => IsText(kv.Value));
        var columns = new ResultColumn[]
        {
            new(KeyColumn, keysAreText ? "TEXT" : "BLOB", keysAreText ? typeof(string) : typeof(byte[])),
            new(ValueColumn, valuesAreText ? "TEXT" : "BLOB", valuesAreText ? typeof(string) : typeof(byte[])),
            new(VersionColumn, "BIGINT", typeof(long)),
            new(CreateRevisionColumn, "BIGINT", typeof(long)),
            new(ModRevisionColumn, "BIGINT", typeof(long)),
            new(LeaseColumn, "TEXT", typeof(string)),
        };

        var rows = new List<object?[]>(kvs.Count);
        foreach (var kv in kvs)
        {
            rows.Add(
            [
                Payload(kv.Key, keysAreText) ?? string.Empty,
                Payload(kv.Value, valuesAreText) ?? (valuesAreText ? string.Empty : Array.Empty<byte>()),
                kv.Version,
                kv.CreateRevision,
                kv.ModRevision,
                LeaseText(kv.Lease),
            ]);
        }

        return new ResultSet(columns, rows, isTruncated);
    }

    public static string? LeaseText(long lease) => lease == 0 ? null : EtcdCommandParser.LeaseHex(lease);

    public static string KeyText(byte[]? key) => key is null ? string.Empty : Encoding.UTF8.GetString(key);

    /// <summary>What the sidebar shows beside a key.</summary>
    public static string Describe(EtcdKeyValue kv)
    {
        return kv.Lease == 0
            ? EtcdStrings.Format("Etcd/DescribeKey", kv.Version, kv.ModRevision)
            : EtcdStrings.Format("Etcd/DescribeKeyWithLease", kv.Version, kv.ModRevision, EtcdCommandParser.LeaseHex(kv.Lease));
    }

    /// <summary>
    /// The range a sidebar entry reads. A name ending in <c>/</c> or <c>*</c>, or an empty name, is a prefix under the
    /// connection's key prefix; any other name is that one key.
    /// </summary>
    public static (byte[] Key, byte[]? RangeEnd) Target(string name, string root)
    {
        if (name.Length == 0 || name == "*")
        {
            return Prefix(root);
        }

        if (name.EndsWith('*'))
        {
            return Prefix(name[..^1]);
        }

        return name.EndsWith('/') ? Prefix(name) : (EtcdClient.Utf8(name), null);
    }

    public static (byte[] Key, byte[]? RangeEnd) Prefix(string prefix)
    {
        if (prefix.Length == 0)
        {
            // A key of \0 with a range end of \0 is etcd's spelling of every key.
            return ([0], [0]);
        }

        var key = EtcdClient.Utf8(prefix);
        return (key, EtcdClient.PrefixEnd(key));
    }

    /// <summary>The literal start of a glob, which is what etcd can range over; the rest is matched here.</summary>
    public static string GlobPrefix(string pattern)
    {
        var stop = pattern.AsSpan().IndexOfAny(GlobStops);
        return stop < 0 ? pattern : pattern[..stop];
    }

    public static bool IsGlob(string pattern) => pattern.AsSpan().IndexOfAny(GlobWildcards) >= 0;

    private static readonly System.Buffers.SearchValues<char> GlobStops = System.Buffers.SearchValues.Create("*?[\\");

    private static readonly System.Buffers.SearchValues<char> GlobWildcards = System.Buffers.SearchValues.Create("*?[");

    /// <summary>Redis-style glob: <c>*</c>, <c>?</c>, <c>[abc]</c>, <c>[a-z]</c>, <c>[^a]</c> and backslash escapes.</summary>
    public static bool GlobMatch(ReadOnlySpan<char> pattern, ReadOnlySpan<char> text)
    {
        var p = 0;
        var t = 0;
        var starP = -1;
        var starT = 0;
        while (t < text.Length)
        {
            if (p < pattern.Length && pattern[p] == '*')
            {
                starP = p++;
                starT = t;
                continue;
            }

            if (p < pattern.Length && MatchOne(pattern, ref p, text[t], out var next))
            {
                p = next;
                t++;
                continue;
            }

            if (starP < 0)
            {
                return false;
            }

            p = starP + 1;
            t = ++starT;
        }

        while (p < pattern.Length && pattern[p] == '*')
        {
            p++;
        }

        return p == pattern.Length;
    }

    private static bool MatchOne(ReadOnlySpan<char> pattern, ref int p, char c, out int next)
    {
        var current = pattern[p];
        if (current == '?')
        {
            next = p + 1;
            return true;
        }

        if (current == '\\' && p + 1 < pattern.Length)
        {
            next = p + 2;
            return pattern[p + 1] == c;
        }

        if (current == '[')
        {
            var i = p + 1;
            var negate = i < pattern.Length && pattern[i] == '^';
            if (negate)
            {
                i++;
            }

            var matched = false;
            while (i < pattern.Length && pattern[i] != ']')
            {
                if (i + 2 < pattern.Length && pattern[i + 1] == '-' && pattern[i + 2] != ']')
                {
                    matched |= c >= pattern[i] && c <= pattern[i + 2];
                    i += 3;
                }
                else
                {
                    matched |= pattern[i] == c;
                    i++;
                }
            }

            next = Math.Min(i + 1, pattern.Length);
            return matched != negate;
        }

        next = p + 1;
        return current == c;
    }

    private static bool IsText(byte[]? bytes) => bytes is null || Utf8.IsValid(bytes);

    private static object? Payload(byte[]? bytes, bool asText) => bytes is null ? null : asText ? Encoding.UTF8.GetString(bytes) : bytes;
}
