using System.Collections.Frozen;
using System.Collections.Immutable;

namespace TablePro.Core.Sql;

/// <summary>
/// A language of one command per line, such as Redis CLI, etcdctl or KafkaQL. A line ending in a backslash continues
/// on the next, and a line starting with the comment prefix is skipped. What a command does is read from its verb.
/// </summary>
public abstract class CommandDialect : SqlDialect
{
    public override bool IsSql => false;

    public override SqlLexerFeatures LexerFeatures => SqlLexerFeatures.HashComments | SqlLexerFeatures.DoubleQuotedStrings | SqlLexerFeatures.BackslashEscapes;

    public override string LineComment => "#";

    public override IReadOnlyList<string> Explain(string statement) => [];

    /// <summary>Verbs that only read.</summary>
    protected abstract FrozenSet<string> ReadVerbs { get; }

    /// <summary>Verbs that change keys or values.</summary>
    protected abstract FrozenSet<string> WriteVerbs { get; }

    /// <summary>Verbs that change structure: create or drop a whole database, index, topic or collection.</summary>
    protected virtual FrozenSet<string> StructureVerbs { get; } = FrozenSet<string>.Empty;

    /// <summary>Verbs that only change the session, such as SELECT 3 on Redis.</summary>
    protected virtual FrozenSet<string> SessionVerbs { get; } = FrozenSet<string>.Empty;

    /// <summary>How many leading words name the command, two for <c>CLIENT LIST</c> style commands.</summary>
    protected virtual int VerbWords(string firstWord) => 1;

    public override IEnumerable<string> CompletionKeywords => ReadVerbs.Concat(WriteVerbs).Concat(StructureVerbs).Concat(SessionVerbs).Order(StringComparer.OrdinalIgnoreCase);

    public override bool IsKeyword(ReadOnlySpan<char> word)
    {
        var text = word.ToString();
        return ReadVerbs.Contains(text) || WriteVerbs.Contains(text) || StructureVerbs.Contains(text) || SessionVerbs.Contains(text);
    }

    public override ImmutableArray<SqlStatement> Split(string text)
    {
        var builder = ImmutableArray.CreateBuilder<SqlStatement>();
        var start = -1;
        var end = 0;
        var lineStart = 0;
        while (lineStart <= text.Length)
        {
            var newline = text.IndexOf('\n', lineStart);
            var lineEnd = newline < 0 ? text.Length : newline;
            var line = text.AsSpan(lineStart, lineEnd - lineStart).TrimEnd('\r');
            var trimmed = line.Trim();
            var isComment = trimmed.StartsWith(LineComment, StringComparison.Ordinal) || trimmed.StartsWith("//", StringComparison.Ordinal);
            if (start < 0 && !trimmed.IsEmpty && !isComment)
            {
                start = lineStart + (line.Length - line.TrimStart().Length);
            }

            if (start >= 0 && !trimmed.IsEmpty)
            {
                end = lineStart + line.TrimEnd().Length;
            }

            // A trailing backslash joins the next line into the same command, as a shell does.
            if (start >= 0 && !trimmed.EndsWith('\\'))
            {
                Emit(text, start, end, builder);
                start = -1;
            }

            if (newline < 0)
            {
                break;
            }

            lineStart = newline + 1;
        }

        if (start >= 0)
        {
            Emit(text, start, end, builder);
        }

        return builder.ToImmutable();
    }

    private static void Emit(string text, int start, int end, ImmutableArray<SqlStatement>.Builder builder)
    {
        if (end > start)
        {
            var command = text[start..end].Replace("\\\r\n", " ", StringComparison.Ordinal).Replace("\\\n", " ", StringComparison.Ordinal);
            builder.Add(new SqlStatement(start, end - start, command));
        }
    }
    public override StatementKind Classify(string statement)
    {
        var words = CommandWords.Read(statement, 2);
        if (words.Count == 0)
        {
            return StatementKind.Unknown;
        }

        var verb = VerbWords(words[0]) == 2 && words.Count > 1 ? $"{words[0]} {words[1]}" : words[0];
        if (ReadVerbs.Contains(verb))
        {
            return StatementKind.Read;
        }

        if (WriteVerbs.Contains(verb))
        {
            return StatementKind.Write;
        }

        if (StructureVerbs.Contains(verb))
        {
            return StatementKind.Ddl;
        }

        return SessionVerbs.Contains(verb) ? StatementKind.Session : StatementKind.Unknown;
    }

    protected static FrozenSet<string> Verbs(params string[] verbs) => FrozenSet.Create(StringComparer.OrdinalIgnoreCase, verbs);
}

/// <summary>Reads a command line into words, honouring single and double quotes as redis-cli and etcdctl do.</summary>
public static class CommandWords
{
    public static IReadOnlyList<string> Read(string line, int max = int.MaxValue)
    {
        var words = new List<string>();
        var current = new System.Text.StringBuilder();
        char? quote = null;
        var inWord = false;
        for (var i = 0; i < line.Length && words.Count < max; i++)
        {
            var c = line[i];
            if (quote is { } q)
            {
                if (c == '\\' && q == '"' && i + 1 < line.Length)
                {
                    current.Append(line[++i] switch { 'n' => '\n', 't' => '\t', 'r' => '\r', var other => other });
                }
                else if (c == q)
                {
                    quote = null;
                }
                else
                {
                    current.Append(c);
                }

                continue;
            }

            if (c is '"' or '\'')
            {
                quote = c;
                inWord = true;
            }
            else if (char.IsWhiteSpace(c))
            {
                if (inWord)
                {
                    words.Add(current.ToString());
                    current.Clear();
                    inWord = false;
                }
            }
            else
            {
                current.Append(c);
                inWord = true;
            }
        }

        if (inWord && words.Count < max)
        {
            words.Add(current.ToString());
        }

        return words;
    }
}
