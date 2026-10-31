using TablePro.Core.Sql;

namespace TablePro.Drivers.ClickHouse;

/// <summary>
/// Splits the profile's startup commands into settings and statements. Over HTTP a <c>SET</c> lasts only as long as
/// its server session, and every pooled read opens a new one, so a <c>SET</c> becomes a request setting instead, which
/// rides on every request for free. Anything else still runs once per opened connection.
/// </summary>
internal static class ClickHouseStartup
{
    public sealed record Commands(IReadOnlyList<KeyValuePair<string, string>> Settings, IReadOnlyList<string> Statements);

    public static Commands Parse(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return new Commands([], []);
        }

        var settings = new List<KeyValuePair<string, string>>();
        var statements = new List<string>();
        foreach (var statement in SqlScript.Split(text, ClickHouseDialect.Instance))
        {
            if (!TryParseSet(statement.Text, settings))
            {
                statements.Add(statement.Text);
            }
        }

        return new Commands(settings, statements);
    }

    /// <summary>Reads <c>SET a = 1, b = 'x'</c>. Leaves the list as it was when the statement is anything else.</summary>
    public static bool TryParseSet(string statement, List<KeyValuePair<string, string>> settings)
    {
        var span = statement.AsSpan().Trim();
        if (span.Length < 4 || !span[..3].Equals("SET", StringComparison.OrdinalIgnoreCase) || !char.IsWhiteSpace(span[3]))
        {
            return false;
        }

        var parsed = new List<KeyValuePair<string, string>>();
        foreach (var assignment in SplitAssignments(span[4..].ToString()))
        {
            var equals = assignment.IndexOf('=', StringComparison.Ordinal);
            if (equals <= 0)
            {
                return false;
            }

            var name = assignment[..equals].Trim();
            var value = assignment[(equals + 1)..].Trim();
            if (name.Length == 0 || value.Length == 0 || !IsSettingName(name))
            {
                return false;
            }

            parsed.Add(new(name, Unquote(value)));
        }

        if (parsed.Count == 0)
        {
            return false;
        }

        settings.AddRange(parsed);
        return true;
    }

    private static List<string> SplitAssignments(string text)
    {
        var parts = new List<string>();
        var start = 0;
        var quoted = false;
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (c == '\\' && quoted)
            {
                i++;
            }
            else if (c == '\'')
            {
                quoted = !quoted;
            }
            else if (c == ',' && !quoted)
            {
                parts.Add(text[start..i]);
                start = i + 1;
            }
        }

        parts.Add(text[start..]);
        return parts;
    }

    private static bool IsSettingName(string name)
    {
        foreach (var c in name)
        {
            if (!char.IsAsciiLetterOrDigit(c) && c != '_')
            {
                return false;
            }
        }

        return true;
    }

    private static string Unquote(string value)
    {
        if (value.Length < 2 || value[0] != '\'' || value[^1] != '\'')
        {
            return value;
        }

        var inner = value[1..^1];
        return inner.Replace("\\'", "'", StringComparison.Ordinal).Replace("''", "'", StringComparison.Ordinal).Replace("\\\\", "\\", StringComparison.Ordinal);
    }
}
