using TablePro.Core.Browse;
using TablePro.Core.Schema;

namespace TablePro.Core.Drivers;

/// <summary>
/// A key-value engine that lists a whole database's keys as one table. The table tab searches it with a key pattern
/// and a key type, which the engine sends to the server, as the macOS key pattern bar does; the sidebar groups the
/// keys it lists into namespaces at <see cref="KeySeparator"/>.
/// </summary>
public interface IKeyBrowseProvider
{
    /// <summary>The text that splits a key into namespaces, such as <c>:</c> in <c>user:1:name</c>; empty lists keys flat.</summary>
    string KeySeparator { get; }

    /// <summary>How a table lists keys, or null when it is not a key listing.</summary>
    KeyBrowseInfo? GetKeyBrowse(ObjectName table);
}

/// <summary>The columns a key listing is searched by, and the key types it can be narrowed to.</summary>
/// <param name="KeyColumn">The key's column; <see cref="FilterOperator.Equals"/> on it takes a glob such as <c>user:*</c>.</param>
/// <param name="TypeColumn">The type's column, narrowed with <see cref="FilterOperator.Equals"/>.</param>
/// <param name="Types">The types to choose from, by the engine's own names.</param>
public sealed record KeyBrowseInfo(string KeyColumn, string TypeColumn, IReadOnlyList<string> Types)
{
    /// <summary>The filter rules a pattern and a type stand for; blank ones add nothing.</summary>
    public IReadOnlyList<FilterRule> Rules(string? pattern, string? type)
    {
        var rules = new List<FilterRule>(2);
        if (!string.IsNullOrWhiteSpace(pattern))
        {
            rules.Add(new FilterRule(KeyColumn, FilterOperator.Equals, pattern.Trim()));
        }

        if (!string.IsNullOrWhiteSpace(type))
        {
            rules.Add(new FilterRule(TypeColumn, FilterOperator.Equals, type.Trim()));
        }

        return rules;
    }

    /// <summary>The pattern that lists every key under a namespace prefix, with the glob characters in it escaped.</summary>
    public static string NamespacePattern(string prefix)
    {
        ArgumentNullException.ThrowIfNull(prefix);
        var builder = new System.Text.StringBuilder(prefix.Length + 2);
        foreach (var c in prefix)
        {
            if (c is '*' or '?' or '[' or ']' or '\\')
            {
                builder.Append('\\');
            }

            builder.Append(c);
        }

        return builder.Append('*').ToString();
    }
}
