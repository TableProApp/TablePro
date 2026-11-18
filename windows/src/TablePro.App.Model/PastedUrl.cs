namespace TablePro.App.Model;

// The connection URL in pasted text: its first line, when that names a scheme, as macOS's Import from URL takes it.
public static class PastedUrl
{
    public static string? In(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return null;
        }

        var line = text.AsSpan().TrimStart();
        var end = line.IndexOfAny('\r', '\n');
        var first = (end < 0 ? line : line[..end]).Trim().ToString();
        return first.Contains("://", StringComparison.Ordinal) && !first.Contains(' ', StringComparison.Ordinal) ? first : null;
    }
}
