using System.Text;
using TablePro.Core.Sql;

namespace TablePro.Core.Copy;

/// <summary>
/// Rewrites a view's or routine's definition so names qualified with the source schema point at the target schema.
/// The lexer reads the text, so a schema name inside a string or a comment is never touched, and only a name followed
/// by a dot (a qualifier) changes.
/// </summary>
public static class DefinitionRetargeter
{
    public static string Retarget(string definition, SqlDialect dialect, string? sourceSchema, string? targetSchema)
    {
        ArgumentNullException.ThrowIfNull(definition);
        ArgumentNullException.ThrowIfNull(dialect);
        if (string.IsNullOrEmpty(sourceSchema) || string.Equals(sourceSchema, targetSchema, StringComparison.Ordinal))
        {
            return definition;
        }

        var tokens = new List<SqlToken>();
        var lexer = new SqlLexer(definition.AsSpan(), dialect.LexerFeatures);
        while (lexer.TryRead(out var token))
        {
            tokens.Add(token);
        }

        var output = new StringBuilder(definition.Length + 16);
        var copied = 0;
        for (var i = 0; i < tokens.Count; i++)
        {
            var token = tokens[i];
            if (token.Kind is not (SqlTokenKind.Word or SqlTokenKind.QuotedIdentifier) || !Names(definition, token, sourceSchema))
            {
                continue;
            }

            var next = i + 1;
            while (next < tokens.Count && tokens[next].IsTrivia)
            {
                next++;
            }

            // A qualifier is followed by a dot and is not itself the second half of one, such as alias.public.
            if (next >= tokens.Count || tokens[next].Kind != SqlTokenKind.Dot || (i > 0 && tokens[i - 1].Kind == SqlTokenKind.Dot))
            {
                continue;
            }

            output.Append(definition, copied, token.Start - copied);
            if (string.IsNullOrEmpty(targetSchema))
            {
                copied = tokens[next].End;
            }
            else
            {
                output.Append(dialect.QuoteIdentifier(targetSchema));
                copied = token.End;
            }
        }

        output.Append(definition, copied, definition.Length - copied);
        return output.ToString();
    }

    private static bool Names(string text, SqlToken token, string schema)
    {
        var span = token.Slice(text.AsSpan());
        if (token.Kind == SqlTokenKind.Word)
        {
            return span.Equals(schema, StringComparison.OrdinalIgnoreCase);
        }

        if (span.Length < 2)
        {
            return false;
        }

        var close = span[^1];
        var inner = span[1..^1].ToString().Replace(new string(close, 2), close.ToString(), StringComparison.Ordinal);
        return string.Equals(inner, schema, StringComparison.Ordinal);
    }
}
