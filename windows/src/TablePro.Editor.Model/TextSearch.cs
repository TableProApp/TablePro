using System.Text;
using System.Text.RegularExpressions;

namespace TablePro.Editor.Model;

public readonly record struct SearchQuery(
    string Text, bool MatchCase = false, bool WholeWord = false, bool UseRegex = false)
{
    public StringComparison Comparison => MatchCase ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase;
}

public static class TextSearch
{
    // The editor's own word characters (TextUnits.IsWordChar), so whole word means the same with a pattern.
    private const string WordChar = @"[\p{L}\p{Nd}\p{M}_]";
    private const string PatternSyntax = @"\*+?|{}[]()^$.";

    private static readonly TimeSpan MatchTimeout = TimeSpan.FromSeconds(1);

    private static Cached? s_cached;

    // An empty query, or a literal one, is always valid.
    public static bool IsValid(SearchQuery query) =>
        !query.UseRegex || string.IsNullOrEmpty(query.Text) || Compile(query) is not null;

    // For text taken from a selection into a pattern; spaces stay as they are.
    public static string EscapePattern(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var builder = new StringBuilder(text.Length);
        foreach (var c in text)
        {
            if (PatternSyntax.Contains(c, StringComparison.Ordinal))
            {
                builder.Append('\\');
            }
            builder.Append(c);
        }
        return builder.ToString();
    }

    public static (int Start, int Length)? Next(TextDocument document, SearchQuery query, int from, bool backward)
    {
        if (string.IsNullOrEmpty(query.Text))
        {
            return null;
        }
        var text = document.Snapshot();
        from = Math.Clamp(from, 0, text.Length);
        if (query.UseRegex)
        {
            return Compile(query) is { } pattern && !pattern.TimedOutOn(document)
                ? NextMatch(pattern, document, text, from, backward)
                : null;
        }
        var found = backward ? Backward(text, query, from) ?? Backward(text, query, text.Length)
            : Forward(text, query, from) ?? Forward(text, query, 0);
        return found is int start ? (start, query.Text.Length) : null;
    }

    public static List<(int Start, int Length)> InRange(TextDocument document, SearchQuery query, int start, int end,
        int limit = int.MaxValue)
    {
        var matches = new List<(int, int)>();
        if (string.IsNullOrEmpty(query.Text))
        {
            return matches;
        }
        var text = document.Snapshot();
        var index = Math.Clamp(start, 0, text.Length);
        if (query.UseRegex)
        {
            if (Compile(query) is { } pattern && !pattern.TimedOutOn(document))
            {
                MatchesInRange(pattern, document, text, index, end, limit, matches);
            }
            return matches;
        }
        while (index < end)
        {
            var found = Forward(text, query, index);
            if (found is not int at || at >= end)
            {
                break;
            }
            matches.Add((at, query.Text.Length));
            if (matches.Count >= limit)
            {
                break;
            }
            index = at + Math.Max(1, query.Text.Length);
        }
        return matches;
    }

    // What takes the place of the text at start, or null when that text is not a match.
    public static string? ReplacementAt(TextDocument document, SearchQuery query, int start, int length,
        string replacement)
    {
        ArgumentNullException.ThrowIfNull(document);
        ArgumentNullException.ThrowIfNull(replacement);
        var text = document.Snapshot();
        if (string.IsNullOrEmpty(query.Text) || length <= 0 || start < 0 || start + length > text.Length)
        {
            return null;
        }
        if (!query.UseRegex)
        {
            var same = length == query.Text.Length
                && string.Compare(text, start, query.Text, 0, length, query.Comparison) == 0
                && (!query.WholeWord || IsWholeWord(text, start, length));
            return same ? replacement : null;
        }
        if (Compile(query) is not { } pattern || pattern.TimedOutOn(document))
        {
            return null;
        }
        try
        {
            var match = pattern.Regex.Match(text, start);
            while (match.Success && match.Index == start && match.Length == 0)
            {
                match = match.NextMatch();
            }
            return match.Success && match.Index == start && match.Length == length ? match.Result(replacement) : null;
        }
        catch (RegexMatchTimeoutException)
        {
            pattern.MarkTimedOut(document);
            return null;
        }
    }

    // Every match with what takes its place; with a pattern the replacement expands $1, ${name} and $$.
    public static IReadOnlyList<(int Start, int Length, string Text)> Replacements(TextDocument document,
        SearchQuery query, string replacement)
    {
        ArgumentNullException.ThrowIfNull(document);
        ArgumentNullException.ThrowIfNull(replacement);
        var replacements = new List<(int, int, string)>();
        if (string.IsNullOrEmpty(query.Text))
        {
            return replacements;
        }
        if (!query.UseRegex)
        {
            foreach (var (start, length) in InRange(document, query, 0, document.Length))
            {
                replacements.Add((start, length, replacement));
            }
            return replacements;
        }
        if (Compile(query) is not { } pattern || pattern.TimedOutOn(document))
        {
            return replacements;
        }
        try
        {
            for (var match = pattern.Regex.Match(document.Snapshot()); match.Success; match = match.NextMatch())
            {
                if (match.Length > 0)
                {
                    replacements.Add((match.Index, match.Length, match.Result(replacement)));
                }
            }
        }
        catch (RegexMatchTimeoutException)
        {
            // Half a replace all is worse than none.
            pattern.MarkTimedOut(document);
            replacements.Clear();
        }
        return replacements;
    }

    private static (int Start, int Length)? NextMatch(
        CompiledPattern pattern, TextDocument document, string text, int from, bool backward)
    {
        try
        {
            return backward ? LastBefore(pattern.Regex, text, from) ?? LastBefore(pattern.Regex, text, text.Length)
                : FirstFrom(pattern.Regex, text, from) ?? FirstFrom(pattern.Regex, text, 0);
        }
        catch (RegexMatchTimeoutException)
        {
            pattern.MarkTimedOut(document);
            return null;
        }
    }

    // An empty match would leave the caret where it is, so the search steps over it.
    private static (int Start, int Length)? FirstFrom(Regex regex, string text, int from)
    {
        for (var match = regex.Match(text, from); match.Success; match = match.NextMatch())
        {
            if (match.Length > 0)
            {
                return (match.Index, match.Length);
            }
        }
        return null;
    }

    private static (int Start, int Length)? LastBefore(Regex regex, string text, int before)
    {
        (int Start, int Length)? last = null;
        for (var match = regex.Match(text); match.Success && match.Index < before; match = match.NextMatch())
        {
            if (match.Length > 0 && match.Index + match.Length <= before)
            {
                last = (match.Index, match.Length);
            }
        }
        return last;
    }

    private static void MatchesInRange(
        CompiledPattern pattern,
        TextDocument document,
        string text,
        int start,
        int end,
        int limit,
        List<(int, int)> matches)
    {
        try
        {
            for (var match = pattern.Regex.Match(text, start); match.Success && match.Index < end;
                match = match.NextMatch())
            {
                if (match.Length == 0)
                {
                    continue;
                }
                matches.Add((match.Index, match.Length));
                if (matches.Count >= limit)
                {
                    break;
                }
            }
        }
        catch (RegexMatchTimeoutException)
        {
            pattern.MarkTimedOut(document);
            matches.Clear();
        }
    }

    // Drawing asks for the matches every frame, so the last query keeps its compiled pattern.
    private static CompiledPattern? Compile(SearchQuery query)
    {
        var cached = s_cached;
        if (cached is not null && cached.Query == query)
        {
            return cached.Pattern;
        }
        var pattern = Build(query);
        s_cached = new Cached(query, pattern);
        return pattern;
    }

    private static CompiledPattern? Build(SearchQuery query)
    {
        var options = RegexOptions.CultureInvariant | RegexOptions.Multiline
            | (query.MatchCase ? RegexOptions.None : RegexOptions.IgnoreCase);
        try
        {
            // Parsed on its own first, so wrapping cannot make a broken pattern such as "a)|(b" valid.
            var regex = new Regex(query.Text, options, MatchTimeout);
            if (query.WholeWord)
            {
                regex = new Regex($"(?<!{WordChar})(?:{query.Text})(?!{WordChar})", options, MatchTimeout);
            }
            return new CompiledPattern(regex);
        }
        catch (ArgumentException)
        {
            return null;
        }
    }

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

    // A pattern that ran past the timeout finds nothing more in that text, so each frame does not wait it out again;
    // an edit, or another document, searches again.
    private sealed class CompiledPattern(Regex regex)
    {
        private WeakReference<TextDocument>? _timedOutIn;
        private long _timedOutVersion;

        public Regex Regex { get; } = regex;

        public bool TimedOutOn(TextDocument document) =>
            _timedOutIn is not null
            && _timedOutIn.TryGetTarget(out var timedOut)
            && ReferenceEquals(timedOut, document)
            && _timedOutVersion == document.Version;

        public void MarkTimedOut(TextDocument document)
        {
            _timedOutIn = new WeakReference<TextDocument>(document);
            _timedOutVersion = document.Version;
        }
    }

    private sealed record Cached(SearchQuery Query, CompiledPattern? Pattern);
}
