using System.Collections.Immutable;

namespace TablePro.Core.Sql;

/// <summary>
/// Splits an Oracle script the way SQL*Plus and SQLcl do. A SQL statement ends at <c>;</c>, which is not sent, since
/// Oracle refuses it in SQL (ORA-00933). A PL/SQL unit, an anonymous <c>DECLARE</c> or <c>BEGIN</c> block or a
/// <c>CREATE</c> of a procedure, function, package, trigger, type, library or Java source, holds <c>;</c> of its own and
/// ends only at a line holding nothing but <c>/</c>, or at the end of the text; its final <c>END;</c> keeps the
/// <c>;</c>, which PL/SQL requires. A <c>/</c> line also ends a SQL statement that has no <c>;</c>.
/// </summary>
/// <remarks>The lexer has no Oracle alternative quoting, so <c>q'[...]'</c> literals are skipped here.</remarks>
public static class OracleScript
{
    private static readonly string[] CreateModifiers = ["OR", "REPLACE", "EDITIONABLE", "NONEDITIONABLE", "EDITIONING", "AND", "COMPILE", "RESOLVE", "NOFORCE"];

    private static readonly string[] PlSqlUnits = ["PROCEDURE", "FUNCTION", "PACKAGE", "TRIGGER", "TYPE", "LIBRARY", "JAVA"];

    private enum Kind
    {
        Undecided,
        Sql,
        PlSql,
    }

    public static ImmutableArray<SqlStatement> Split(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var output = ImmutableArray.CreateBuilder<SqlStatement>();
        var span = text.AsSpan();
        var features = OracleDialect.Instance.LexerFeatures;
        var lexer = new SqlLexer(span, features);
        var start = -1;
        var lastEnd = -1;
        var kind = Kind.Undecided;
        var create = false;

        while (lexer.TryRead(out var token))
        {
            if (token.Kind == SqlTokenKind.Operator && token.Slice(span) is "/" && IsSlashLine(span, token))
            {
                Emit(text, start, lastEnd, output);
                start = -1;
                lastEnd = -1;
                kind = Kind.Undecided;
                continue;
            }

            if (token.IsTrivia)
            {
                continue;
            }

            if (token.Kind == SqlTokenKind.Semicolon && kind != Kind.PlSql)
            {
                Emit(text, start, lastEnd, output);
                start = -1;
                lastEnd = -1;
                kind = Kind.Undecided;
                continue;
            }

            if (start < 0)
            {
                start = token.Start;
                kind = Kind.Undecided;
                create = false;
            }

            var end = token.End;
            if (token.Kind == SqlTokenKind.Word)
            {
                if (QuotedLiteralEnd(span, token) is var quoteEnd and > 0)
                {
                    end = quoteEnd;
                    lexer = new SqlLexer(span, features, quoteEnd);
                    kind = kind == Kind.Undecided ? Kind.Sql : kind;
                }
                else if (kind == Kind.Undecided)
                {
                    kind = Classify(token.Slice(span), ref create);
                }
            }
            else if (kind == Kind.Undecided)
            {
                kind = Kind.Sql;
            }

            lastEnd = end;
        }

        Emit(text, start, lastEnd, output);
        return output.ToImmutable();
    }

    /// <summary>Decides a statement's kind from its opening words, or stays undecided through CREATE's modifiers.</summary>
    private static Kind Classify(ReadOnlySpan<char> word, ref bool create)
    {
        if (!create)
        {
            if (word.Equals("DECLARE", StringComparison.OrdinalIgnoreCase) || word.Equals("BEGIN", StringComparison.OrdinalIgnoreCase))
            {
                return Kind.PlSql;
            }

            if (word.Equals("CREATE", StringComparison.OrdinalIgnoreCase))
            {
                create = true;
                return Kind.Undecided;
            }

            return Kind.Sql;
        }

        foreach (var modifier in CreateModifiers)
        {
            if (word.Equals(modifier, StringComparison.OrdinalIgnoreCase))
            {
                return Kind.Undecided;
            }
        }

        foreach (var unit in PlSqlUnits)
        {
            if (word.Equals(unit, StringComparison.OrdinalIgnoreCase))
            {
                return Kind.PlSql;
            }
        }

        return Kind.Sql;
    }

    /// <summary>
    /// Where a <c>q'Xtext X'</c> (or <c>nq'...'</c>) literal ends, or -1. The closing delimiter pairs with the opening
    /// one for brackets and repeats it otherwise.
    /// </summary>
    private static int QuotedLiteralEnd(ReadOnlySpan<char> text, SqlToken token)
    {
        var word = token.Slice(text);
        if (!(word.Equals("q", StringComparison.OrdinalIgnoreCase) || word.Equals("nq", StringComparison.OrdinalIgnoreCase)))
        {
            return -1;
        }

        var quote = token.End;
        if (quote + 1 >= text.Length || text[quote] != '\'')
        {
            return -1;
        }

        var open = text[quote + 1];
        var close = open switch
        {
            '[' => ']',
            '(' => ')',
            '{' => '}',
            '<' => '>',
            _ => open,
        };

        for (var i = quote + 2; i + 1 < text.Length; i++)
        {
            if (text[i] == close && text[i + 1] == '\'')
            {
                return i + 2;
            }
        }

        return text.Length;
    }

    /// <summary>A <c>/</c> alone on its line, whitespace aside.</summary>
    private static bool IsSlashLine(ReadOnlySpan<char> text, SqlToken token)
    {
        for (var i = token.Start - 1; i >= 0 && text[i] is not ('\n' or '\r'); i--)
        {
            if (!char.IsWhiteSpace(text[i]))
            {
                return false;
            }
        }

        for (var i = token.End; i < text.Length && text[i] is not ('\n' or '\r'); i++)
        {
            if (!char.IsWhiteSpace(text[i]))
            {
                return false;
            }
        }

        return true;
    }

    private static void Emit(string text, int start, int end, ImmutableArray<SqlStatement>.Builder output)
    {
        if (start >= 0 && end > start)
        {
            output.Add(new SqlStatement(start, end - start, text[start..end]));
        }
    }
}
