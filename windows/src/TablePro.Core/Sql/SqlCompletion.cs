using System.Collections.Frozen;

namespace TablePro.Core.Sql;

public enum CompletionKind
{
    Keyword,
    Function,
    Schema,
    Table,
    View,
    Column,
    Snippet,
}

public sealed record CompletionItem(string Label, CompletionKind Kind, string? Detail = null, string? InsertText = null)
{
    public string Text => InsertText ?? Label;
}

/// <summary>The names completion can offer, refreshed by the workspace when the sidebar loads.</summary>
public sealed class CompletionCatalog
{
    public static readonly CompletionCatalog Empty = new([], [], new Dictionary<string, IReadOnlyList<(string Name, string Type)>>());

    public CompletionCatalog(
        IReadOnlyList<string> schemas,
        IReadOnlyList<(string Name, bool IsView)> tables,
        IReadOnlyDictionary<string, IReadOnlyList<(string Name, string Type)>> columns)
    {
        Schemas = schemas;
        Tables = tables;
        Columns = columns.ToFrozenDictionary(StringComparer.OrdinalIgnoreCase);
    }

    public IReadOnlyList<string> Schemas { get; }

    public IReadOnlyList<(string Name, bool IsView)> Tables { get; }

    /// <summary>Columns by table name, filled as tables are opened or described.</summary>
    public FrozenDictionary<string, IReadOnlyList<(string Name, string Type)>> Columns { get; }

    public IReadOnlyList<(string Name, IReadOnlyList<CompletionItem> Items)> Snippets { get; init; } = [];
}

/// <summary>
/// Context-aware completion: columns after <c>alias.</c>, tables after FROM and JOIN, and keywords, functions, tables
/// and the columns of the statement's tables elsewhere. It reads the statement under the caret with the dialect's lexer.
/// </summary>
public static class SqlCompletion
{
    public static (int ReplaceStart, IReadOnlyList<CompletionItem> Items) Suggest(string text, int caret, SqlDialect dialect, CompletionCatalog catalog)
    {
        caret = Math.Clamp(caret, 0, text.Length);
        var wordStart = caret;
        while (wordStart > 0 && (SqlLexer.IsWordPart(text[wordStart - 1]) || text[wordStart - 1] is '"' or '`' or '['))
        {
            wordStart--;
        }

        var prefix = text[wordStart..caret].TrimStart('"', '`', '[');
        var statements = SqlScript.Split(text, dialect);
        var statement = SqlScript.StatementAt(statements, caret);
        var statementText = statement?.Text ?? string.Empty;
        var aliases = ReadTableReferences(statementText, dialect);

        // After "x." offer the columns of the table x names or aliases, or the tables of schema x.
        if (wordStart > 0 && text[wordStart - 1] == '.')
        {
            var qualifierEnd = wordStart - 1;
            var qualifierStart = qualifierEnd;
            while (qualifierStart > 0 && (SqlLexer.IsWordPart(text[qualifierStart - 1]) || text[qualifierStart - 1] is '"' or '`' or ']' or '['))
            {
                qualifierStart--;
            }

            var qualifier = text[qualifierStart..qualifierEnd].Trim('"', '`', '[', ']');
            var table = aliases.TryGetValue(qualifier, out var aliased) ? aliased : qualifier;
            var items = new List<CompletionItem>();
            if (catalog.Columns.TryGetValue(table, out var columns))
            {
                items.AddRange(columns.Select(c => new CompletionItem(c.Name, CompletionKind.Column, c.Type)));
            }

            if (catalog.Schemas.Contains(qualifier, StringComparer.OrdinalIgnoreCase))
            {
                items.AddRange(catalog.Tables.Select(t => new CompletionItem(Unqualified(t.Name), t.IsView ? CompletionKind.View : CompletionKind.Table)));
            }

            return (wordStart, Filter(items, prefix));
        }

        var previous = PreviousKeyword(text, wordStart, dialect);
        var all = new List<CompletionItem>(256);
        var wantsTable = previous is "FROM" or "JOIN" or "INTO" or "UPDATE" or "TABLE" or "DESCRIBE";
        if (wantsTable)
        {
            all.AddRange(catalog.Tables.Select(t => new CompletionItem(t.Name, t.IsView ? CompletionKind.View : CompletionKind.Table)));
            all.AddRange(catalog.Schemas.Select(s => new CompletionItem(s, CompletionKind.Schema)));
        }
        else
        {
            foreach (var table in aliases.Values.Distinct(StringComparer.OrdinalIgnoreCase))
            {
                if (catalog.Columns.TryGetValue(table, out var columns))
                {
                    all.AddRange(columns.Select(c => new CompletionItem(c.Name, CompletionKind.Column, $"{Unqualified(table)} · {c.Type}")));
                }
            }

            all.AddRange(catalog.Tables.Select(t => new CompletionItem(t.Name, t.IsView ? CompletionKind.View : CompletionKind.Table)));
            all.AddRange(SqlKeywords.Functions.Select(f => new CompletionItem(f, CompletionKind.Function, InsertText: f + "(")));
            all.AddRange(SqlKeywords.All.Select(k => new CompletionItem(k, CompletionKind.Keyword)));
            foreach (var (_, items) in catalog.Snippets)
            {
                all.AddRange(items);
            }
        }

        return (wordStart, Filter(all, prefix));
    }

    /// <summary>Table names keyed by themselves and by their alias, from FROM, JOIN, UPDATE and INTO clauses.</summary>
    internal static Dictionary<string, string> ReadTableReferences(string statement, SqlDialect dialect)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var words = new List<string>();
        var lexer = new SqlLexer(statement, dialect.LexerFeatures);
        var span = statement.AsSpan();
        while (lexer.TryRead(out var token))
        {
            if (token.IsTrivia)
            {
                continue;
            }

            words.Add(token.Kind switch
            {
                SqlTokenKind.QuotedIdentifier => token.Slice(span)[1..^1].ToString(),
                SqlTokenKind.Word => token.Slice(span).ToString(),
                SqlTokenKind.Dot => ".",
                SqlTokenKind.Comma => ",",
                _ => "\u0000",
            });
        }

        for (var i = 0; i < words.Count; i++)
        {
            if (!IsTableIntroducer(words[i]))
            {
                continue;
            }

            var j = i + 1;
            while (j < words.Count)
            {
                if (!IsName(words[j]))
                {
                    break;
                }

                var name = words[j];
                j++;
                while (j + 1 < words.Count && words[j] == "." && IsName(words[j + 1]))
                {
                    name = words[j + 1];
                    j += 2;
                }

                result.TryAdd(name, name);
                if (j < words.Count && words[j].Equals("AS", StringComparison.OrdinalIgnoreCase))
                {
                    j++;
                }

                if (j < words.Count && IsName(words[j]) && !SqlKeywords.IsKeyword(words[j]))
                {
                    result[words[j]] = name;
                    j++;
                }

                if (j < words.Count && words[j] == ",")
                {
                    j++;
                    continue;
                }

                break;
            }
        }

        return result;
    }

    private static bool IsTableIntroducer(string word) =>
        word.Equals("FROM", StringComparison.OrdinalIgnoreCase) || word.Equals("JOIN", StringComparison.OrdinalIgnoreCase)
        || word.Equals("UPDATE", StringComparison.OrdinalIgnoreCase) || word.Equals("INTO", StringComparison.OrdinalIgnoreCase);

    private static bool IsName(string word) => word.Length > 0 && word is not ("." or "," or "\u0000");

    private static string Unqualified(string name)
    {
        var dot = name.LastIndexOf('.');
        return dot >= 0 ? name[(dot + 1)..] : name;
    }

    private static string? PreviousKeyword(string text, int before, SqlDialect dialect)
    {
        string? last = null;
        var lexer = new SqlLexer(text.AsSpan(0, before), dialect.LexerFeatures);
        var span = text.AsSpan(0, before);
        while (lexer.TryRead(out var token))
        {
            if (token.Kind == SqlTokenKind.Word && SqlKeywords.IsKeyword(token.Slice(span)))
            {
                last = token.Slice(span).ToString().ToUpperInvariant();
            }
            else if (!token.IsTrivia && token.Kind != SqlTokenKind.Comma)
            {
                if (token.Kind is SqlTokenKind.Semicolon)
                {
                    last = null;
                }
                else if (token.Kind is SqlTokenKind.Word or SqlTokenKind.QuotedIdentifier or SqlTokenKind.Dot)
                {
                    // A name after FROM keeps FROM as the context for the next table in a list.
                    continue;
                }
                else
                {
                    last = null;
                }
            }
        }

        return last;
    }

    private static CompletionItem[] Filter(List<CompletionItem> items, string prefix)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        return items
            .Where(i => prefix.Length == 0 || i.Label.Contains(prefix, StringComparison.OrdinalIgnoreCase))
            .OrderBy(i => i.Label.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) ? 0 : 1)
            .ThenBy(i => i.Kind)
            .ThenBy(i => i.Label.Length)
            .ThenBy(i => i.Label, StringComparer.OrdinalIgnoreCase)
            .Where(i => seen.Add(i.Kind + ":" + i.Label))
            .Take(200)
            .ToArray();
    }
}
