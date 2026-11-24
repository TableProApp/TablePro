namespace TablePro.App.Model;

public enum SavedQueryInsertKind
{
    NewTab,
    Replace,
    Append,
}

// Text is what goes in: the whole tab for NewTab and Replace, what follows the editor's end for Append.
public readonly record struct SavedQueryInsertion(SavedQueryInsertKind Kind, string Text);

public static class SavedQueryText
{
    public const int NameLength = 50;

    // As macOS names one: the first comment's text, else the first line, cut to 50 characters.
    public static string AutoName(string sql, string untitled)
    {
        ArgumentNullException.ThrowIfNull(sql);
        ArgumentNullException.ThrowIfNull(untitled);
        var rest = sql.AsSpan();
        while (!rest.IsEmpty)
        {
            var end = rest.IndexOfAny('\r', '\n');
            var line = (end < 0 ? rest : rest[..end]).Trim();
            rest = end < 0 ? ReadOnlySpan<char>.Empty : rest[(end + 1)..];
            if (line.StartsWith("--", StringComparison.Ordinal))
            {
                var comment = line[2..].Trim();
                if (!comment.IsEmpty)
                {
                    return Cut(comment);
                }
            }
            else if (!line.IsEmpty)
            {
                return Cut(line);
            }
        }

        return untitled;
    }

    public static string FirstLine(string sql)
    {
        ArgumentNullException.ThrowIfNull(sql);
        foreach (var line in sql.AsSpan().EnumerateLines())
        {
            var trimmed = line.Trim();
            if (!trimmed.IsEmpty)
            {
                return trimmed.ToString();
            }
        }

        return string.Empty;
    }

    // Null editorText: no query tab is shown. A blank editor takes the query, one with text gets it after a blank line.
    public static SavedQueryInsertion Insertion(string? editorText, string sql)
    {
        ArgumentNullException.ThrowIfNull(sql);
        if (editorText is null)
        {
            return new SavedQueryInsertion(SavedQueryInsertKind.NewTab, sql);
        }

        return string.IsNullOrWhiteSpace(editorText)
            ? new SavedQueryInsertion(SavedQueryInsertKind.Replace, sql)
            : new SavedQueryInsertion(SavedQueryInsertKind.Append, "\n\n" + sql);
    }

    private static string Cut(ReadOnlySpan<char> line)
    {
        var length = Math.Min(NameLength, line.Length);
        // Half a surrogate pair is no character, and the core keeps names as UTF-8.
        if (length < line.Length && char.IsHighSurrogate(line[length - 1]))
        {
            length--;
        }

        return line[..length].ToString();
    }
}
