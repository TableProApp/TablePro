using System.Collections.Immutable;

namespace TablePro.Core.Sql;

/// <summary>One statement (or one <c>GO</c> batch) of a script, as a range of the source text.</summary>
public readonly record struct SqlStatement(int Start, int Length, string Text)
{
    /// <summary>How many times the statement runs: a SQL Server batch ended by <c>GO 5</c> runs five times.</summary>
    public int Repeat { get; init; } = 1;

    public int End => Start + Length;

    public bool Contains(int offset) => offset >= Start && offset <= End;
}

/// <summary>
/// Splits a script the way the engine's own client does: at <c>;</c> outside strings, comments and quoted names, at a
/// <c>GO</c> line for SQL Server, at the delimiter a MySQL <c>DELIMITER</c> line sets, and around SQLite trigger bodies.
/// </summary>
public static class SqlScript
{
    /// <summary>Splits through the dialect, so a command language splits by its own rules.</summary>
    public static ImmutableArray<SqlStatement> Split(string text, SqlDialect dialect)
    {
        ArgumentNullException.ThrowIfNull(text);
        ArgumentNullException.ThrowIfNull(dialect);
        return dialect.Split(text);
    }

    /// <summary>The SQL rules every SQL dialect shares; a dialect's <see cref="SqlDialect.Split"/> calls it by default.</summary>
    public static ImmutableArray<SqlStatement> SplitSql(string text, SqlDialect dialect)
    {

        var builder = ImmutableArray.CreateBuilder<SqlStatement>();
        if (dialect.BatchSeparator is { } separator)
        {
            SplitBatches(text, dialect, separator, builder);
        }
        else
        {
            SplitStatements(text, dialect, builder);
        }

        return builder.ToImmutable();
    }

    /// <summary>
    /// Each statement's text as many times as it runs. A SQL Server batch ended by <c>GO 5</c> runs five times, each
    /// run with a result of its own, as on macOS and in sqlcmd.
    /// </summary>
    public static IEnumerable<string> Runs(IEnumerable<SqlStatement> statements)
    {
        ArgumentNullException.ThrowIfNull(statements);
        foreach (var statement in statements)
        {
            for (var run = 0; run < Math.Max(statement.Repeat, 1); run++)
            {
                yield return statement.Text;
            }
        }
    }

    /// <summary>The statement under the caret, or the one just before it when the caret sits in trailing space.</summary>
    public static SqlStatement? StatementAt(ImmutableArray<SqlStatement> statements, int caret)
    {
        SqlStatement? previous = null;
        foreach (var statement in statements)
        {
            if (statement.Contains(caret))
            {
                return statement;
            }

            if (statement.Start > caret)
            {
                break;
            }

            previous = statement;
        }

        return previous ?? (statements.Length > 0 ? statements[0] : null);
    }

    private static void SplitStatements(string text, SqlDialect dialect, ImmutableArray<SqlStatement>.Builder output)
    {
        var span = text.AsSpan();
        var lexer = new SqlLexer(span, dialect.LexerFeatures);
        var statementStart = -1;
        var lastSignificantEnd = -1;
        var delimiter = ";";
        var firstWords = new FirstWords();
        var blockDepth = 0;

        while (lexer.TryRead(out var token))
        {
            if (token.IsTrivia)
            {
                continue;
            }

            if (statementStart < 0 && dialect.SupportsDelimiterDirective && token.Kind == SqlTokenKind.Word
                && token.Slice(span).Equals("DELIMITER", StringComparison.OrdinalIgnoreCase) && IsLineStart(span, token.Start))
            {
                var lineEnd = LineEnd(span, token.End);
                var value = span[token.End..lineEnd].Trim();
                if (!value.IsEmpty)
                {
                    delimiter = value.ToString();
                }

                lexer = new SqlLexer(span, dialect.LexerFeatures, lineEnd);
                continue;
            }

            if (delimiter != ";" && token.Kind is not (SqlTokenKind.String or SqlTokenKind.QuotedIdentifier)
                && DelimiterOffset(span, token, delimiter) is var at and >= 0)
            {
                // The lexer glues a delimiter such as $$ or // onto the word or operator before it (END$$, *//).
                if (at > 0)
                {
                    statementStart = statementStart < 0 ? token.Start : statementStart;
                    lastSignificantEnd = token.Start + at;
                }

                Emit(text, statementStart, lastSignificantEnd, output);
                statementStart = -1;
                lastSignificantEnd = -1;
                lexer = new SqlLexer(span, dialect.LexerFeatures, token.Start + at + delimiter.Length);
                continue;
            }

            if (token.Kind == SqlTokenKind.Semicolon && delimiter == ";" && blockDepth == 0)
            {
                Emit(text, statementStart, lastSignificantEnd, output);
                statementStart = -1;
                lastSignificantEnd = -1;
                firstWords = default;
                continue;
            }

            if (statementStart < 0)
            {
                statementStart = token.Start;
                firstWords = default;
                blockDepth = 0;
            }

            if (token.Kind == SqlTokenKind.Word)
            {
                var word = token.Slice(span);
                firstWords.Add(word);
                if (dialect.KeepsTriggerBodies && firstWords.IsCreateTrigger)
                {
                    if (word.Equals("BEGIN", StringComparison.OrdinalIgnoreCase) || word.Equals("CASE", StringComparison.OrdinalIgnoreCase))
                    {
                        blockDepth++;
                    }
                    else if (word.Equals("END", StringComparison.OrdinalIgnoreCase) && blockDepth > 0)
                    {
                        blockDepth--;
                    }
                }
            }

            lastSignificantEnd = token.End;
        }

        Emit(text, statementStart, lastSignificantEnd, output);
    }

    private static void SplitBatches(string text, SqlDialect dialect, string separator, ImmutableArray<SqlStatement>.Builder output)
    {
        var span = text.AsSpan();
        var lexer = new SqlLexer(span, dialect.LexerFeatures);
        var batchStart = -1;
        var lastSignificantEnd = -1;

        while (lexer.TryRead(out var token))
        {
            if (token.IsTrivia)
            {
                continue;
            }

            if (token.Kind == SqlTokenKind.Word && token.Slice(span).Equals(separator, StringComparison.OrdinalIgnoreCase)
                && IsLineStart(span, token.Start) && SeparatorCount(span, token.End) is { } repeat)
            {
                Emit(text, batchStart, lastSignificantEnd, output, repeat);
                batchStart = -1;
                lastSignificantEnd = -1;
                lexer = new SqlLexer(span, dialect.LexerFeatures, LineEnd(span, token.End));
                continue;
            }

            if (batchStart < 0)
            {
                batchStart = token.Start;
            }

            lastSignificantEnd = token.End;
        }

        Emit(text, batchStart, lastSignificantEnd, output);
    }

    /// <summary>Where a custom delimiter starts within a token, or -1. A delimiter longer than the token may run past it.</summary>
    private static int DelimiterOffset(ReadOnlySpan<char> text, SqlToken token, string delimiter) =>
        text[token.Start..].StartsWith(delimiter, StringComparison.Ordinal)
            ? 0
            : token.Slice(text).IndexOf(delimiter, StringComparison.Ordinal);

    private static void Emit(string text, int start, int end, ImmutableArray<SqlStatement>.Builder output, int repeat = 1)
    {
        if (start < 0 || end <= start)
        {
            return;
        }

        output.Add(new SqlStatement(start, end - start, text[start..end]) { Repeat = repeat });
    }

    private static bool IsLineStart(ReadOnlySpan<char> text, int index)
    {
        for (var i = index - 1; i >= 0; i--)
        {
            var c = text[i];
            if (c is '\n' or '\r')
            {
                return true;
            }

            if (!char.IsWhiteSpace(c))
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>
    /// How many times the batch before a GO line runs, or null when the line is not a separator. The line may carry a
    /// repeat count and a comment, nothing else; as on macOS and in sqlcmd, a count must be positive and fit in 32 bits.
    /// </summary>
    private static int? SeparatorCount(ReadOnlySpan<char> text, int afterWord)
    {
        var rest = text[afterWord..LineEnd(text, afterWord)].Trim();
        var comment = rest.IndexOf("--", StringComparison.Ordinal);
        if (comment >= 0)
        {
            rest = rest[..comment].Trim();
        }

        if (rest.IsEmpty)
        {
            return 1;
        }

        foreach (var c in rest)
        {
            if (!char.IsAsciiDigit(c))
            {
                return null;
            }
        }

        return int.TryParse(rest, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var count) && count > 0 ? count : null;
    }

    private static int LineEnd(ReadOnlySpan<char> text, int from)
    {
        var newline = text[from..].IndexOfAny('\n', '\r');
        return newline < 0 ? text.Length : from + newline;
    }

    /// <summary>Remembers just enough of a statement's opening words to spot <c>CREATE [TEMP] TRIGGER</c>.</summary>
    private struct FirstWords
    {
        private int _count;
        private bool _create;

        public bool IsCreateTrigger { get; private set; }

        public void Add(ReadOnlySpan<char> word)
        {
            if (_count++ > 3)
            {
                return;
            }

            if (_count == 1)
            {
                _create = word.Equals("CREATE", StringComparison.OrdinalIgnoreCase);
            }
            else if (_create && word.Equals("TRIGGER", StringComparison.OrdinalIgnoreCase))
            {
                IsCreateTrigger = true;
            }
        }
    }
}
