using System.Globalization;

namespace TablePro.App.Model;

// The name a duplicated connection takes: "Shop (Copy)", then "Shop (Copy 2)", and a copy of a copy counts on from the
// original rather than stacking a second suffix. The patterns come in the user's language, "{0} (Copy)" and
// "{0} (Copy {1})".
public static class CopyName
{
    private const string Name = "\u0000";
    private const string Number = "\u0001";

    public static string For(string name, IEnumerable<string> taken, string pattern, string numberedPattern)
    {
        ArgumentNullException.ThrowIfNull(name);
        ArgumentNullException.ThrowIfNull(taken);
        ArgumentNullException.ThrowIfNull(pattern);
        ArgumentNullException.ThrowIfNull(numberedPattern);
        var names = taken.ToHashSet(StringComparer.Ordinal);
        var original = Original(name, pattern, numberedPattern);
        var first = Format(pattern, original);
        if (!names.Contains(first))
        {
            return first;
        }

        // A person's own connections, so the count ends within as many steps as they have copies.
        for (var n = 2; n < int.MaxValue; n++)
        {
            var candidate = Format(numberedPattern, original, n.ToString(CultureInfo.CurrentCulture));
            if (!names.Contains(candidate))
            {
                return candidate;
            }
        }

        return first;
    }

    private static string Original(string name, string pattern, string numberedPattern)
    {
        if (Strip(name, Format(pattern, Name)) is { Length: > 0 } plain)
        {
            return plain;
        }

        var numbered = Format(numberedPattern, Name, Number);
        var at = numbered.IndexOf(Name, StringComparison.Ordinal);
        var between = numbered.IndexOf(Number, StringComparison.Ordinal);
        // A translation that puts the number before the name is left as it is: the copy then reads "(Copy) (Copy)".
        if (at < 0 || between < at)
        {
            return name;
        }

        var before = numbered[..at];
        var middle = numbered[(at + Name.Length)..between];
        var after = numbered[(between + Number.Length)..];
        if (!name.StartsWith(before, StringComparison.Ordinal) || !name.EndsWith(after, StringComparison.Ordinal)
            || name.Length < before.Length + after.Length)
        {
            return name;
        }

        var inner = name[before.Length..(name.Length - after.Length)];
        var split = inner.LastIndexOf(middle, StringComparison.Ordinal);
        if (split <= 0)
        {
            return name;
        }

        var count = inner[(split + middle.Length)..];
        return int.TryParse(count, NumberStyles.None, CultureInfo.CurrentCulture, out var n) && n >= 2
            ? inner[..split]
            : name;
    }

    private static string? Strip(string name, string template)
    {
        var at = template.IndexOf(Name, StringComparison.Ordinal);
        if (at < 0)
        {
            return null;
        }

        var before = template[..at];
        var after = template[(at + Name.Length)..];
        return name.Length > before.Length + after.Length
            && name.StartsWith(before, StringComparison.Ordinal)
            && name.EndsWith(after, StringComparison.Ordinal)
                ? name[before.Length..(name.Length - after.Length)]
                : null;
    }

    private static string Format(string pattern, params object?[] values) =>
        string.Format(CultureInfo.CurrentCulture, pattern, values);
}
