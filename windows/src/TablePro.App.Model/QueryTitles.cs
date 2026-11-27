using System.Globalization;
using System.Text;

namespace TablePro.App.Model;

// A query tab's titles: the name a user types, and the automatic Query N the app numbers.
public static class QueryTitles
{
    // In grapheme clusters, so an emoji is never cut through.
    public const int MaxLength = 100;

    // Null for a name that shows nothing, which takes the tab back to its automatic title.
    public static string? Normalize(string? typed)
    {
        if (string.IsNullOrEmpty(typed))
        {
            return null;
        }

        var builder = new StringBuilder(typed.Length);
        var breaking = false;
        foreach (var character in typed)
        {
            if (char.IsControl(character)
                || char.GetUnicodeCategory(character)
                    is UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator)
            {
                if (!breaking)
                {
                    builder.Append(' ');
                }

                breaking = true;
                continue;
            }

            breaking = false;
            builder.Append(character);
        }

        var name = builder.ToString().Trim();
        var elements = new StringInfo(name);
        if (elements.LengthInTextElements > MaxLength)
        {
            name = elements.SubstringByTextElements(0, MaxLength).TrimEnd();
        }

        // A joiner inside a name holds an emoji together; a name of only such marks draws a blank tab.
        return name.EnumerateRunes().All(rune =>
            Rune.IsWhiteSpace(rune) || Rune.GetUnicodeCategory(rune) == UnicodeCategory.Format)
            ? null
            : name;
    }

    // numbered is the automatic title's format, "Query {0}".
    public static string Next(IReadOnlySet<string> taken, string numbered)
    {
        ArgumentNullException.ThrowIfNull(taken);
        ArgumentNullException.ThrowIfNull(numbered);
        for (var number = 1; ; number++)
        {
            var title = Numbered(numbered, number);
            if (!taken.Contains(title))
            {
                return title;
            }
        }
    }

    // Only a title the format writes for a number from 1, so "Query 07" or a shared link's "Query +7" is not one.
    public static bool IsNumbered(string title, string numbered)
    {
        ArgumentNullException.ThrowIfNull(title);
        ArgumentNullException.ThrowIfNull(numbered);
        var slot = numbered.IndexOf("{0}", StringComparison.Ordinal);
        if (slot < 0)
        {
            return false;
        }

        var prefix = numbered[..slot];
        var suffix = numbered[(slot + 3)..];
        if (title.Length <= prefix.Length + suffix.Length
            || !title.StartsWith(prefix, StringComparison.Ordinal)
            || !title.EndsWith(suffix, StringComparison.Ordinal))
        {
            return false;
        }

        var digits = title[prefix.Length..^suffix.Length];
        return int.TryParse(digits, NumberStyles.None, CultureInfo.InvariantCulture, out var number)
            && number > 0
            && Numbered(numbered, number) == title;
    }

    // Only a Query N another tab took meanwhile moves; a typed name stays shown and a file keeps its name.
    public static SessionTab Reopened(SessionTab tab, IReadOnlySet<string> taken, string numbered)
    {
        ArgumentNullException.ThrowIfNull(tab);
        ArgumentNullException.ThrowIfNull(taken);
        ArgumentNullException.ThrowIfNull(numbered);
        return tab is { Kind: TabKind.Query } && string.IsNullOrEmpty(tab.FilePath)
            && taken.Contains(tab.Title) && IsNumbered(tab.Title, numbered)
                ? tab with { Title = Next(taken, numbered) }
                : tab;
    }

    private static string Numbered(string numbered, int number) =>
        string.Format(CultureInfo.CurrentCulture, numbered, number);
}
