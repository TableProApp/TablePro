namespace TablePro.App.Model.QuickSwitcher;

// A search that says where an object lives as well as what it is called: "shop.orders", "shop." for everything in one
// container, or "db.shop.orders". A port of apple TableProUtilities/UI/QualifiedSearchQuery.swift. It reads text still
// being typed, so it is lenient: spaces around a dot are ignored, an unterminated quote runs to the end, and "x", [x]
// and `x` are accepted, each with its doubled closing character as an escape.
public sealed class QualifiedSearchQuery
{
    private static readonly Dictionary<char, char> ClosingQuotes = new() { ['"'] = '"', ['`'] = '`', ['['] = ']' };

    private QualifiedSearchQuery(IReadOnlyList<string> containers, string name)
    {
        Containers = containers;
        Name = name;
    }

    // Outermost first: ["shop", "attendance"] for "shop.attendance.timesheet".
    public IReadOnlyList<string> Containers { get; }

    // Empty when the text ends in a dot, which asks for everything in the container.
    public string Name { get; }

    // Null when the text is not qualified: no unquoted dot, or an empty container such as ".orders" or "a..b".
    public static QualifiedSearchQuery? Parse(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var segments = Segments(text);
        if (segments.Count <= 1)
        {
            return null;
        }

        var name = segments[^1];
        var containers = segments.GetRange(0, segments.Count - 1);
        return containers.Any(string.IsNullOrEmpty) ? null : new QualifiedSearchQuery(containers, name);
    }

    // Pairs each named container with the part of location it matches, right to left; null when the query names more
    // containers than the location has.
    public IReadOnlyList<(string Query, string Candidate)>? ContainerPairs(IReadOnlyList<string> location)
    {
        ArgumentNullException.ThrowIfNull(location);
        if (Containers.Count > location.Count)
        {
            return null;
        }

        var pairs = new List<(string, string)>(Containers.Count);
        var offset = location.Count - Containers.Count;
        for (var index = 0; index < Containers.Count; index++)
        {
            pairs.Add((Containers[index], location[offset + index]));
        }

        return pairs;
    }

    // Where an object lives, outermost first. Both levels stay even when they share a name, so a database "shop" with a
    // schema "shop" is reached by "shop.shop.orders"; a query lines up from the right.
    public static IReadOnlyList<string> Location(string? database, string? schema)
    {
        var parts = new List<string>(2);
        if (!string.IsNullOrEmpty(database))
        {
            parts.Add(database);
        }

        if (!string.IsNullOrEmpty(schema))
        {
            parts.Add(schema);
        }

        return parts;
    }

    private static List<string> Segments(string text)
    {
        var segments = new List<string>();
        var current = new System.Text.StringBuilder();
        char? closingQuote = null;
        for (var index = 0; index < text.Length; index++)
        {
            var character = text[index];
            if (closingQuote is { } closing)
            {
                if (character != closing)
                {
                    current.Append(character);
                    continue;
                }

                if (index + 1 < text.Length && text[index + 1] == closing)
                {
                    current.Append(closing);
                    index++;
                }
                else
                {
                    closingQuote = null;
                }

                continue;
            }

            if (ClosingQuotes.TryGetValue(character, out var opened))
            {
                closingQuote = opened;
            }
            else if (character == '.')
            {
                segments.Add(current.ToString().Trim());
                current.Clear();
            }
            else
            {
                current.Append(character);
            }
        }

        segments.Add(current.ToString().Trim());
        return segments;
    }
}
