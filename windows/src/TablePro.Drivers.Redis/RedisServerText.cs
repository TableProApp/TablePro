using System.Globalization;
using TablePro.Core.Results;

namespace TablePro.Drivers.Redis;

/// <summary>Parses the text replies of <c>INFO</c> and <c>CLIENT LIST</c>.</summary>
internal static class RedisServerText
{
    public static readonly IReadOnlyList<ResultColumn> InfoColumns =
    [
        new("section", "string", typeof(string)),
        new("key", "string", typeof(string)),
        new("value", "string", typeof(string)),
    ];

    /// <summary>Each <c>key:value</c> line of an INFO reply under the <c># Section</c> heading above it.</summary>
    public static IEnumerable<(string Section, string Key, string Value)> ParseInfo(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            yield break;
        }

        var section = string.Empty;
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.TrimEnd('\r').Trim();
            if (line.Length == 0)
            {
                continue;
            }

            if (line[0] == '#')
            {
                section = line[1..].Trim();
                continue;
            }

            var colon = line.IndexOf(':', StringComparison.Ordinal);
            if (colon > 0)
            {
                yield return (section, line[..colon], line[(colon + 1)..]);
            }
        }
    }

    public static ResultSet InfoResult(string? text)
    {
        var rows = new List<object?[]>();
        foreach (var (section, key, value) in ParseInfo(text))
        {
            rows.Add([section, key, value]);
        }

        return new ResultSet(InfoColumns, rows);
    }

    /// <summary>One INFO field, such as <c>redis_version</c> from the Server section.</summary>
    public static string? InfoValue(string? text, string key)
    {
        foreach (var (_, k, value) in ParseInfo(text))
        {
            if (string.Equals(k, key, StringComparison.OrdinalIgnoreCase))
            {
                return value;
            }
        }

        return null;
    }

    /// <summary>The key count of each database the Keyspace section lists, such as <c>db3:keys=12,expires=0</c>.</summary>
    public static IReadOnlyDictionary<int, long> ParseKeyspace(string? text)
    {
        var counts = new Dictionary<int, long>();
        foreach (var (_, key, value) in ParseInfo(text))
        {
            if (key.Length < 3 || !key.StartsWith("db", StringComparison.OrdinalIgnoreCase)
                || !int.TryParse(key.AsSpan(2), NumberStyles.None, CultureInfo.InvariantCulture, out var index))
            {
                continue;
            }

            foreach (var part in value.Split(','))
            {
                var eq = part.IndexOf('=', StringComparison.Ordinal);
                if (eq > 0 && part.AsSpan(0, eq).Trim().Equals("keys", StringComparison.OrdinalIgnoreCase)
                    && long.TryParse(part.AsSpan(eq + 1).Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var keys))
                {
                    counts[index] = keys;
                }
            }
        }

        return counts;
    }

    /// <summary>
    /// <c>CLIENT LIST</c> as a table: one row per line, one column per <c>name=value</c> field in the order the server
    /// sends them. A column whose every value is a whole number is typed as one, so it sorts as a number.
    /// </summary>
    public static ResultSet ParseClientList(string? text)
    {
        var names = new List<string>();
        var index = new Dictionary<string, int>(StringComparer.Ordinal);
        var parsed = new List<Dictionary<int, string>>();
        foreach (var raw in (text ?? string.Empty).Split('\n'))
        {
            var line = raw.TrimEnd('\r').Trim();
            if (line.Length == 0)
            {
                continue;
            }

            var fields = new Dictionary<int, string>();
            foreach (var token in line.Split(' ', StringSplitOptions.RemoveEmptyEntries))
            {
                var eq = token.IndexOf('=', StringComparison.Ordinal);
                if (eq <= 0)
                {
                    continue;
                }

                var name = token[..eq];
                if (!index.TryGetValue(name, out var column))
                {
                    column = names.Count;
                    names.Add(name);
                    index[name] = column;
                }

                fields[column] = token[(eq + 1)..];
            }

            parsed.Add(fields);
        }

        var numeric = new bool[names.Count];
        for (var c = 0; c < names.Count; c++)
        {
            numeric[c] = parsed.Count > 0 && parsed.All(f => !f.TryGetValue(c, out var v) || long.TryParse(v, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out _));
        }

        var columns = names.Select((n, c) => numeric[c] ? new ResultColumn(n, "integer", typeof(long)) : new ResultColumn(n, "string", typeof(string))).ToArray();
        var rows = new List<object?[]>(parsed.Count);
        foreach (var fields in parsed)
        {
            var row = new object?[names.Count];
            foreach (var (c, value) in fields)
            {
                row[c] = numeric[c] ? long.Parse(value, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture) : value;
            }

            rows.Add(row);
        }

        return new ResultSet(columns, rows);
    }
}
