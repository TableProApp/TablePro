using TablePro.Core.Principals;

namespace TablePro.Drivers.MySql;

/// <summary>One privilege of a GRANT line, with the columns it is limited to, if any.</summary>
internal sealed record MySqlParsedPrivilege(string Name, IReadOnlyList<string> Columns);

internal sealed record MySqlParsedGrant(IReadOnlyList<MySqlParsedPrivilege> Privileges, PrivilegeScope Scope, bool IsGrantable);

/// <summary>
/// Reads SHOW GRANTS output, the only complete source for a MySQL account's privileges: the mysql.user flag columns
/// miss MySQL 8's dynamic privileges entirely.
/// </summary>
internal static class MySqlGrantParser
{
    public const string AllPrivileges = "ALL PRIVILEGES";

    public static MySqlParsedGrant? Parse(string line)
    {
        var text = line.Trim();
        if (KeywordAt(text, "GRANT") != 0)
        {
            return null;
        }

        var afterGrant = text["GRANT".Length..];
        var on = KeywordAt(afterGrant, "ON");
        if (on < 0)
        {
            return null;
        }

        var remainder = afterGrant[(on + 2)..];
        var to = KeywordAt(remainder, "TO");
        if (to < 0 || ParseScope(remainder[..to].Trim()) is not { } scope)
        {
            return null;
        }

        var privileges = SplitTopLevel(afterGrant[..on], ',').Select(p => Privilege(p.Trim())).OfType<MySqlParsedPrivilege>().ToArray();
        if (privileges.Length == 0)
        {
            return null;
        }

        return new MySqlParsedGrant(privileges, scope, remainder[(to + 2)..].Contains("WITH GRANT OPTION", StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>Strips one level of backtick, single or double quotes, undoubling the quote inside.</summary>
    public static string Unquote(string value)
    {
        if (value.Length < 2 || value[0] != value[^1] || value[0] is not ('`' or '\'' or '"'))
        {
            return value;
        }

        var quote = value[0].ToString();
        return value[1..^1].Replace(quote + quote, quote, StringComparison.Ordinal);
    }

    /// <summary>The inverse of the escaping a database-level grant target needs, where _ and % are LIKE wildcards.</summary>
    public static string UnescapeDatabasePattern(string value)
    {
        var result = new System.Text.StringBuilder(value.Length);
        var escaped = false;
        foreach (var c in value)
        {
            if (escaped)
            {
                result.Append(c);
                escaped = false;
            }
            else if (c == '\\')
            {
                escaped = true;
            }
            else
            {
                result.Append(c);
            }
        }

        return result.ToString();
    }

    private static MySqlParsedPrivilege? Privilege(string raw)
    {
        var open = raw.IndexOf('(', StringComparison.Ordinal);
        var head = string.Join(' ', (open < 0 ? raw : raw[..open]).Split(' ', StringSplitOptions.RemoveEmptyEntries));
        if (PrivilegeName.Sanitize(head) is not { } name)
        {
            return null;
        }

        var close = raw.LastIndexOf(')');
        IReadOnlyList<string> columns = open >= 0 && close > open
            ? SplitTopLevel(raw[(open + 1)..close], ',').Select(c => Unquote(c.Trim())).Where(c => c.Length > 0).ToArray()
            : [];
        return new MySqlParsedPrivilege(name, columns);
    }

    private static PrivilegeScope? ParseScope(string target)
    {
        var parts = SplitTopLevel(target, '.');
        if (parts.Count != 2)
        {
            return null;
        }

        var databasePart = parts[0].Trim();
        var objectPart = parts[1].Trim();
        if (databasePart == "*")
        {
            return objectPart == "*" ? PrivilegeScope.Server : null;
        }

        var database = Unquote(databasePart);
        if (database.Length == 0)
        {
            return null;
        }

        // Only a database-level target is a LIKE pattern. A table-level target names its database literally, so
        // unescaping it would rewrite a name that holds a backslash.
        if (objectPart == "*")
        {
            return PrivilegeScope.ForDatabase(UnescapeDatabasePattern(database));
        }

        var table = Unquote(objectPart);
        return table.Length == 0 ? null : PrivilegeScope.ForTable(database, null, table);
    }

    /// <summary>Where a keyword stands alone outside quotes and parentheses, or -1.</summary>
    private static int KeywordAt(string text, string keyword)
    {
        char? quote = null;
        var depth = 0;
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (quote is { } active)
            {
                if (c == active)
                {
                    quote = null;
                }

                continue;
            }

            switch (c)
            {
                case '`' or '\'' or '"':
                    quote = c;
                    continue;
                case '(':
                    depth++;
                    continue;
                case ')':
                    depth = Math.Max(0, depth - 1);
                    continue;
            }

            if (depth == 0
                && IsBoundary(text, i - 1)
                && i + keyword.Length <= text.Length
                && string.Compare(text, i, keyword, 0, keyword.Length, StringComparison.OrdinalIgnoreCase) == 0
                && IsBoundary(text, i + keyword.Length))
            {
                return i;
            }
        }

        return -1;
    }

    private static bool IsBoundary(string text, int index) => index < 0 || index >= text.Length || text[index] is ' ' or '\t';

    private static List<string> SplitTopLevel(string text, char separator)
    {
        var parts = new List<string>();
        var current = new System.Text.StringBuilder();
        char? quote = null;
        var depth = 0;
        foreach (var c in text)
        {
            if (quote is { } active)
            {
                current.Append(c);
                if (c == active)
                {
                    quote = null;
                }

                continue;
            }

            if (c is '`' or '\'' or '"')
            {
                quote = c;
            }
            else if (c == '(')
            {
                depth++;
            }
            else if (c == ')')
            {
                depth = Math.Max(0, depth - 1);
            }
            else if (c == separator && depth == 0)
            {
                parts.Add(current.ToString());
                current.Clear();
                continue;
            }

            current.Append(c);
        }

        parts.Add(current.ToString());
        return parts.Where(p => !string.IsNullOrWhiteSpace(p)).ToList();
    }
}
