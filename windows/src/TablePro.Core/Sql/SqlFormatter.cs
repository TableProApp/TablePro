using System.Collections.Frozen;
using System.Text;

namespace TablePro.Core.Sql;

public sealed record SqlFormatOptions(bool UppercaseKeywords = true, int IndentSize = 4);

/// <summary>
/// Re-lays a script out clause by clause: each major clause on its own line, select lists and conditions indented,
/// keywords in one case. Strings, comments and quoted names pass through byte for byte.
/// </summary>
public static class SqlFormatter
{
    private static readonly FrozenSet<string> ClauseStarts = FrozenSet.Create(
        StringComparer.OrdinalIgnoreCase,
        ["SELECT", "FROM", "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET", "UNION", "EXCEPT", "INTERSECT", "VALUES",
         "SET", "RETURNING", "WINDOW", "INSERT", "UPDATE", "DELETE", "WITH", "FETCH"]);

    private static readonly FrozenSet<string> JoinWords = FrozenSet.Create(
        StringComparer.OrdinalIgnoreCase, ["JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL", "OUTER"]);

    private static readonly FrozenSet<string> ListClauses = FrozenSet.Create(
        StringComparer.OrdinalIgnoreCase, ["SELECT", "SET", "GROUP", "ORDER", "VALUES", "RETURNING"]);

    public static string Format(string sql, SqlDialect dialect, SqlFormatOptions? options = null)
    {
        options ??= new SqlFormatOptions();
        var statements = SqlScript.Split(sql, dialect);
        if (statements.IsEmpty)
        {
            return sql;
        }

        var sb = new StringBuilder(sql.Length + (sql.Length / 4));
        foreach (var statement in statements)
        {
            if (sb.Length > 0)
            {
                sb.Append("\n\n");
            }

            FormatStatement(statement.Text, dialect, options, sb);
            if (dialect.BatchSeparator is { } separator)
            {
                sb.Append('\n').Append(separator);
            }
            else
            {
                sb.Append(';');
            }
        }

        return sb.ToString();
    }

    private static void FormatStatement(string text, SqlDialect dialect, SqlFormatOptions options, StringBuilder sb)
    {
        var indent = new string(' ', options.IndentSize);
        var span = text.AsSpan();
        var lexer = new SqlLexer(span, dialect.LexerFeatures);
        var depth = 0;
        var lineStart = true;
        var inList = false;
        var previousWasOpen = false;
        SqlToken? previous = null;
        var start = sb.Length;

        void NewLine(int extraIndent)
        {
            TrimTrailingSpace(sb);
            if (sb.Length > start)
            {
                sb.Append('\n');
            }

            for (var i = 0; i < depth + extraIndent; i++)
            {
                sb.Append(indent);
            }

            lineStart = true;
        }

        while (lexer.TryRead(out var token))
        {
            if (token.Kind == SqlTokenKind.Whitespace)
            {
                continue;
            }

            var raw = token.Slice(span);
            if (token.Kind == SqlTokenKind.Word && depth == 0 && ClauseStarts.Contains(raw.ToString()))
            {
                NewLine(0);
                inList = ListClauses.Contains(raw.ToString());
            }
            else if (token.Kind == SqlTokenKind.Word && depth == 0 && JoinWords.Contains(raw.ToString())
                     && previous is { Kind: SqlTokenKind.Word } p && !JoinWords.Contains(span.Slice(p.Start, p.Length).ToString()))
            {
                NewLine(0);
                inList = false;
            }
            else if (token.Kind == SqlTokenKind.Word && depth == 0 && (raw.Equals("AND", StringComparison.OrdinalIgnoreCase) || raw.Equals("OR", StringComparison.OrdinalIgnoreCase))
                     && !inList)
            {
                NewLine(1);
            }
            else if (token.Kind == SqlTokenKind.LineComment)
            {
                if (!lineStart)
                {
                    sb.Append(' ');
                }
            }
            else if (!lineStart && NeedsSpace(span, previous, token, previousWasOpen))
            {
                sb.Append(' ');
            }

            switch (token.Kind)
            {
                case SqlTokenKind.Word when options.UppercaseKeywords && SqlKeywords.IsKeyword(raw):
                    sb.Append(raw.ToString().ToUpperInvariant());
                    break;
                case SqlTokenKind.OpenParen:
                    depth++;
                    sb.Append('(');
                    break;
                case SqlTokenKind.CloseParen:
                    depth = Math.Max(0, depth - 1);
                    sb.Append(')');
                    break;
                default:
                    sb.Append(raw);
                    break;
            }

            lineStart = false;
            previousWasOpen = token.Kind == SqlTokenKind.OpenParen;
            if (token.Kind == SqlTokenKind.Word && depth == 0 && ListClauses.Contains(raw.ToString()) && !raw.Equals("GROUP", StringComparison.OrdinalIgnoreCase) && !raw.Equals("ORDER", StringComparison.OrdinalIgnoreCase))
            {
                NewLine(1);
            }
            else if (token.Kind == SqlTokenKind.Word && depth == 0 && raw.Equals("BY", StringComparison.OrdinalIgnoreCase) && inList)
            {
                NewLine(1);
            }
            else if (token.Kind == SqlTokenKind.Comma && depth == 0 && inList)
            {
                NewLine(1);
            }
            else if (token.Kind == SqlTokenKind.LineComment)
            {
                NewLine(inList ? 1 : 0);
            }

            previous = token;
        }

        TrimTrailingSpace(sb);
    }

    private static bool NeedsSpace(ReadOnlySpan<char> text, SqlToken? previous, SqlToken token, bool previousWasOpen)
    {
        if (previous is not { } before || previousWasOpen)
        {
            return false;
        }

        return token.Kind switch
        {
            SqlTokenKind.Comma or SqlTokenKind.CloseParen or SqlTokenKind.Dot or SqlTokenKind.Semicolon => false,

            // A function call keeps its parenthesis attached; a keyword such as IN or VALUES is followed by a space.
            SqlTokenKind.OpenParen => before.Kind is not (SqlTokenKind.Word or SqlTokenKind.QuotedIdentifier)
                || (before.Kind == SqlTokenKind.Word && SqlKeywords.IsKeyword(before.Slice(text)) && !SqlKeywords.IsFunction(before.Slice(text))),
            _ => before.Kind is not SqlTokenKind.Dot,
        };
    }

    private static void TrimTrailingSpace(StringBuilder sb)
    {
        while (sb.Length > 0 && sb[^1] == ' ')
        {
            sb.Length--;
        }
    }
}
