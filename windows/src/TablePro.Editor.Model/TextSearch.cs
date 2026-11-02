namespace TablePro.Editor.Model;

public readonly record struct SearchQuery(string Text, bool MatchCase = false, bool WholeWord = false)
{
    public StringComparison Comparison => MatchCase ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase;
}

// Plain-text find over the document, wrapping at either end. Regular expressions are a later slice.
public static class TextSearch
{
    public static (int Start, int Length)? Next(TextDocument document, SearchQuery query, int from, bool backward)
    {
        if (string.IsNullOrEmpty(query.Text))
        {
            return null;
        }
        var text = document.Snapshot();
        from = Math.Clamp(from, 0, text.Length);
        var found = backward ? Backward(text, query, from) ?? Backward(text, query, text.Length)
            : Forward(text, query, from) ?? Forward(text, query, 0);
        return found is int start ? (start, query.Text.Length) : null;
    }

    // Matches that start inside [start, end), for painting the visible lines.
    public static List<(int Start, int Length)> InRange(TextDocument document, SearchQuery query, int start, int end)
    {
        var matches = new List<(int, int)>();
        if (string.IsNullOrEmpty(query.Text))
        {
            return matches;
        }
        var text = document.Snapshot();
        var index = Math.Clamp(start, 0, text.Length);
        while (index < end)
        {
            var found = Forward(text, query, index);
            if (found is not int at || at >= end)
            {
                break;
            }
            matches.Add((at, query.Text.Length));
            index = at + Math.Max(1, query.Text.Length);
        }
        return matches;
    }

    public static int Count(TextDocument document, SearchQuery query) =>
        InRange(document, query, 0, document.Length).Count;

    private static int? Forward(string text, SearchQuery query, int from)
    {
        while (from <= text.Length)
        {
            var at = text.IndexOf(query.Text, from, query.Comparison);
            if (at < 0)
            {
                return null;
            }
            if (!query.WholeWord || IsWholeWord(text, at, query.Text.Length))
            {
                return at;
            }
            from = at + 1;
        }
        return null;
    }

    private static int? Backward(string text, SearchQuery query, int before)
    {
        var end = before;
        while (end > 0)
        {
            var at = text.LastIndexOf(query.Text, end - 1, end, query.Comparison);
            if (at < 0)
            {
                return null;
            }
            if (at + query.Text.Length <= before && (!query.WholeWord || IsWholeWord(text, at, query.Text.Length)))
            {
                return at;
            }
            end = at + query.Text.Length - 1;
        }
        return null;
    }

    private static bool IsWholeWord(string text, int start, int length) =>
        (start == 0 || !TextUnits.IsWordChar(text[start - 1]))
        && (start + length >= text.Length || !TextUnits.IsWordChar(text[start + length]));
}
