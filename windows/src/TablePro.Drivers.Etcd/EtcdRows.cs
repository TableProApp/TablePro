using System.Globalization;
using System.Text;
using System.Text.Unicode;
using TablePro.Core.Browse;
using TablePro.Core.Results;
using TablePro.Core.Schema;

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

    public static IReadOnlyList<ColumnInfo> Columns { get; } =
    [
        new(KeyColumn, "TEXT", false, null, true, false, 0),
        new(ValueColumn, "TEXT", true, null, false, false, 1),
        new(VersionColumn, "BIGINT", false, null, false, false, 2, "How many times the key changed since it was created."),
        new(CreateRevisionColumn, "BIGINT", false, null, false, false, 3),
        new(ModRevisionColumn, "BIGINT", false, null, false, false, 4),
        new(LeaseColumn, "TEXT", true, null, false, false, 5, "The lease the key is attached to, in hex as etcdctl prints it."),
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
        var text = string.Create(CultureInfo.InvariantCulture, $"version {kv.Version}, revision {kv.ModRevision}");
        return kv.Lease == 0 ? text : $"{text}, lease {EtcdCommandParser.LeaseHex(kv.Lease)}";
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

/// <summary>
/// The filter strip's rules evaluated over rows already read, for engines that cannot filter on the server. Text
/// comparisons ignore case, as the SQL engines' LIKE filters do; ordering compares numbers when both sides are numbers.
/// </summary>
internal static class RowFilter
{
    public static Func<object?[], bool> Compile(BrowseFilter filter, IReadOnlyList<string> columns)
    {
        if (!string.IsNullOrWhiteSpace(filter.RawWhere))
        {
            throw new NotSupportedException("etcd cannot run a raw WHERE clause; use the filter rules instead.");
        }

        var rules = filter.Rules.Where(r => r.Enabled).ToArray();
        if (rules.Length == 0)
        {
            return static _ => true;
        }

        var search = filter.SearchColumns.Count > 0 ? filter.SearchColumns : columns;
        var tests = rules.Select(rule => Compile(rule, columns, search)).ToArray();
        return filter.MatchAll ? row => tests.All(t => t(row)) : row => tests.Any(t => t(row));
    }

    private static Func<object?[], bool> Compile(FilterRule rule, IReadOnlyList<string> columns, IReadOnlyList<string> search)
    {
        var value = rule.Value ?? string.Empty;
        if (rule.Column is null)
        {
            var ordinals = search.Select(c => IndexOf(columns, c)).Where(i => i >= 0).ToArray();
            return row => value.Length == 0 || ordinals.Any(i => Text(row[i])?.Contains(value, StringComparison.OrdinalIgnoreCase) == true);
        }

        var ordinal = IndexOf(columns, rule.Column);
        if (ordinal < 0)
        {
            throw new NotSupportedException($"There is no column named {rule.Column} to filter on.");
        }

        var list = value.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        return rule.Operator switch
        {
            FilterOperator.Equals => row => Compare(row[ordinal], value) == 0,
            FilterOperator.NotEquals => row => Compare(row[ordinal], value) != 0,
            FilterOperator.GreaterThan => row => Compare(row[ordinal], value) > 0,
            FilterOperator.GreaterOrEqual => row => Compare(row[ordinal], value) >= 0,
            FilterOperator.LessThan => row => Compare(row[ordinal], value) < 0,
            FilterOperator.LessOrEqual => row => Compare(row[ordinal], value) <= 0,
            FilterOperator.Contains => row => Text(row[ordinal])?.Contains(value, StringComparison.OrdinalIgnoreCase) == true,
            FilterOperator.NotContains => row => Text(row[ordinal])?.Contains(value, StringComparison.OrdinalIgnoreCase) != true,
            FilterOperator.StartsWith => row => Text(row[ordinal])?.StartsWith(value, StringComparison.OrdinalIgnoreCase) == true,
            FilterOperator.EndsWith => row => Text(row[ordinal])?.EndsWith(value, StringComparison.OrdinalIgnoreCase) == true,
            FilterOperator.IsNull => row => row[ordinal] is null,
            FilterOperator.IsNotNull => row => row[ordinal] is not null,
            FilterOperator.IsEmpty => row => string.IsNullOrEmpty(Text(row[ordinal])),
            FilterOperator.IsNotEmpty => row => !string.IsNullOrEmpty(Text(row[ordinal])),
            FilterOperator.In => row => list.Any(item => Compare(row[ordinal], item) == 0),
            FilterOperator.NotIn => row => !list.Any(item => Compare(row[ordinal], item) == 0),
            FilterOperator.Between => row => Compare(row[ordinal], value) >= 0 && Compare(row[ordinal], rule.SecondValue ?? string.Empty) <= 0,
            _ => static _ => true,
        };
    }

    private static int IndexOf(IReadOnlyList<string> columns, string name)
    {
        for (var i = 0; i < columns.Count; i++)
        {
            if (string.Equals(columns[i], name, StringComparison.OrdinalIgnoreCase))
            {
                return i;
            }
        }

        return -1;
    }

    private static string? Text(object? value) => value switch
    {
        null => null,
        string s => s,
        byte[] bytes => Encoding.UTF8.GetString(bytes),
        IFormattable f => f.ToString(null, CultureInfo.InvariantCulture),
        _ => value.ToString(),
    };

    private static int Compare(object? cell, string value)
    {
        if (cell is null)
        {
            return -1;
        }

        var text = Text(cell) ?? string.Empty;
        if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var left)
            && double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var right))
        {
            return left.CompareTo(right);
        }

        return string.Compare(text, value, StringComparison.OrdinalIgnoreCase);
    }
}
