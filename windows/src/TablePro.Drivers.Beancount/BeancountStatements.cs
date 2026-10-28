using TablePro.Core.Sql;

namespace TablePro.Drivers.Beancount;

/// <summary>How an editor statement is answered: by rledger as BQL, or by the SQLite projection if it only reads.</summary>
internal static class BeancountStatements
{
    /// <summary>The BQL after a <c>BQL:</c> or <c>BQL </c> prefix, in any case, or null for SQL.</summary>
    public static string? ExtractBql(string statement)
    {
        var trimmed = statement.Trim();
        if (trimmed.Length < 4
            || !trimmed.StartsWith("bql", StringComparison.OrdinalIgnoreCase)
            || trimmed[3] is not (':' or ' '))
        {
            return null;
        }

        return trimmed[4..].Trim();
    }

    /// <summary>
    /// Whether every statement in the text only reads, by the same leading keywords the macOS app allows. The
    /// connection is <c>query_only</c> as well; this refuses ATTACH and PRAGMA writes, which would otherwise reach
    /// files outside the projection or turn that protection off.
    /// </summary>
    public static bool IsReadOnly(string sql)
    {
        foreach (var statement in SqlScript.Split(sql, SqliteDialect.Instance))
        {
            var text = SkipLeadingTrivia(statement.Text);
            if (text.IsEmpty)
            {
                continue;
            }

            if (!(StartsWith(text, "select")
                || StartsWith(text, "with")
                || StartsWith(text, "pragma table_info")
                || StartsWith(text, "pragma database_list")
                || StartsWith(text, "explain")))
            {
                return false;
            }
        }

        return true;
    }

    private static bool StartsWith(ReadOnlySpan<char> text, string prefix) => text.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);

    /// <summary>Whitespace and comments before the first keyword, so a commented SELECT still counts as one.</summary>
    private static ReadOnlySpan<char> SkipLeadingTrivia(ReadOnlySpan<char> text)
    {
        while (true)
        {
            text = text.TrimStart();
            if (text.StartsWith("--"))
            {
                var end = text.IndexOfAny('\n', '\r');
                text = end < 0 ? [] : text[(end + 1)..];
            }
            else if (text.StartsWith("/*"))
            {
                var end = text.IndexOf("*/");
                text = end < 0 ? [] : text[(end + 2)..];
            }
            else
            {
                return text;
            }
        }
    }
}
