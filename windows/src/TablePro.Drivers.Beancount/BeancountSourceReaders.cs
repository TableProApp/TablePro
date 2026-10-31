using System.Globalization;

namespace TablePro.Drivers.Beancount;

/// <summary>Note and balance fields read from the source, merged into the backend's rows.</summary>
internal sealed class BeancountDirectiveDetails
{
    public List<LedgerRow> Notes { get; } = [];

    public List<LedgerRow> Balances { get; } = [];
}

/// <summary><c>query</c> and <c>custom</c> directives, which neither backend reports.</summary>
internal sealed class BeancountSourceDirectives
{
    public List<LedgerRow> Queries { get; } = [];

    public List<LedgerRow> Custom { get; } = [];
}

/// <summary>
/// Reads what the backends leave out. <c>rledger</c> fills tags and links on transactions only, so a note's own tags
/// and links come back empty, and neither backend exposes a balance assertion's explicit <c>~</c> tolerance.
/// <c>rledger</c> has no table for <c>query</c> or <c>custom</c> directives either, and the Python projection does
/// not print them, so both come from the source for every backend.
/// </summary>
internal static class BeancountSourceReaders
{
    public static BeancountDirectiveDetails ReadDetails(BeancountSourceGraph graph)
    {
        var details = new BeancountDirectiveDetails();
        ForEachDirective(graph, directive => AppendDetail(directive, details));
        return details;
    }

    public static BeancountDirectiveDetails ReadDetails(string contents, string sourcePath)
    {
        var details = new BeancountDirectiveDetails();
        BeancountSourceScanner.ScanDirectives(BeancountSourceScanner.Lines(contents), sourcePath, directive => AppendDetail(directive, details));
        return details;
    }

    public static BeancountSourceDirectives ReadDirectives(BeancountSourceGraph graph)
    {
        var directives = new BeancountSourceDirectives();
        ForEachDirective(graph, directive => AppendDirective(directive, directives));
        return directives;
    }

    public static BeancountSourceDirectives ReadDirectives(string contents, string sourcePath)
    {
        var directives = new BeancountSourceDirectives();
        BeancountSourceScanner.ScanDirectives(BeancountSourceScanner.Lines(contents), sourcePath, directive => AppendDirective(directive, directives));
        return directives;
    }

    private static void ForEachDirective(BeancountSourceGraph graph, Action<BeancountSourceDirective> body)
    {
        foreach (var sourceFile in graph.SourceFiles)
        {
            if (graph.Lines.TryGetValue(sourceFile, out var lines))
            {
                BeancountSourceScanner.ScanDirectives(lines, sourceFile, body);
            }
        }
    }

    private static void AppendDetail(BeancountSourceDirective directive, BeancountDirectiveDetails details)
    {
        var tokens = directive.Tokens;
        if (tokens.Count < 2 || BeancountSourceScanner.CanonicalDate(tokens[0].Value) is not { } date)
        {
            return;
        }

        switch (tokens[1].Value)
        {
            case "note" when tokens.Count >= 4:
                details.Notes.Add(new LedgerRow(StringComparer.Ordinal)
                {
                    ["date"] = date,
                    ["account"] = tokens[2].Value,
                    ["comment"] = tokens[3].Value,
                    ["tags"] = Names(tokens, 4, '#'),
                    ["links"] = Names(tokens, 4, '^'),
                });
                break;
            case "balance" when tokens.Count >= 5:
                var row = new LedgerRow(StringComparer.Ordinal)
                {
                    ["date"] = date,
                    ["account"] = tokens[2].Value,
                    ["currency"] = tokens[^1].Value,
                };
                for (var i = 0; i < tokens.Count; i++)
                {
                    if (tokens[i].Value == "~")
                    {
                        if (i + 1 < tokens.Count)
                        {
                            row["tolerance"] = tokens[i + 1].Value;
                        }

                        break;
                    }
                }

                details.Balances.Add(row);
                break;
        }
    }

    private static void AppendDirective(BeancountSourceDirective directive, BeancountSourceDirectives directives)
    {
        var tokens = directive.Tokens;
        if (tokens.Count < 4 || BeancountSourceScanner.CanonicalDate(tokens[0].Value) is not { } date)
        {
            return;
        }

        switch (tokens[1].Value)
        {
            case "query" when tokens[2].Quoted && tokens[3].Quoted:
                var query = Source(directive);
                query["date"] = date;
                query["name"] = tokens[2].Value;
                query["query"] = tokens[3].Value;
                directives.Queries.Add(query);
                break;
            case "custom" when tokens[2].Quoted:
                var custom = Source(directive);
                custom["id"] = (long)(directives.Custom.Count + 1);
                custom["date"] = date;
                custom["type"] = tokens[2].Value;
                custom["values"] = CustomValues(tokens);
                directives.Custom.Add(custom);
                break;
        }
    }

    private static LedgerRow Source(BeancountSourceDirective directive) => new(StringComparer.Ordinal)
    {
        ["filename"] = directive.SourcePath,
        ["lineno"] = (long)directive.LineNumber,
        ["location"] = string.Create(CultureInfo.InvariantCulture, $"{directive.SourcePath}:{directive.LineNumber}"),
    };

    private static List<object?> CustomValues(IReadOnlyList<BeancountSourceToken> tokens)
    {
        var rows = new List<object?>();
        for (var index = 3; index < tokens.Count; index++)
        {
            var token = tokens[index];
            if (token.Quoted)
            {
                rows.Add(Value("string", token.Value));
            }
            else if (BeancountSourceScanner.CanonicalDate(token.Value) is { } date)
            {
                rows.Add(Value("date", date));
            }
            else if (token.Value is "TRUE" or "FALSE")
            {
                rows.Add(Value("boolean", token.Value));
            }
            else if (IsNumber(token.Value) && index + 1 < tokens.Count && IsCurrency(tokens[index + 1].Value))
            {
                var currency = tokens[index + 1].Value;
                var amount = Value("amount", token.Value + " " + currency);
                amount["number"] = token.Value;
                amount["currency"] = currency;
                rows.Add(amount);
                index++;
            }
            else if (token.Value.Contains(':', StringComparison.Ordinal))
            {
                rows.Add(Value("account", token.Value));
            }
            else if (IsNumber(token.Value))
            {
                var number = Value("number", token.Value);
                number["number"] = token.Value;
                rows.Add(number);
            }
        }

        return rows;
    }

    private static LedgerRow Value(string type, string value) => new(StringComparer.Ordinal) { ["value_type"] = type, ["value"] = value };

    private static List<object?> Names(IReadOnlyList<BeancountSourceToken> tokens, int start, char prefix)
    {
        var names = new List<object?>();
        for (var i = start; i < tokens.Count; i++)
        {
            var token = tokens[i];
            if (!token.Quoted && token.Value.Length > 0 && token.Value[0] == prefix)
            {
                names.Add(token.Value[1..]);
            }
        }

        return names;
    }

    private static bool IsNumber(string value) => LedgerValues.TryParseDecimal(value, out _);

    private static bool IsCurrency(string value) =>
        value.Length > 0 && char.IsUpper(value[0]) && value.All(c => char.IsUpper(c) || char.IsDigit(c) || c is '\'' or '.' or '_' or '-');
}
