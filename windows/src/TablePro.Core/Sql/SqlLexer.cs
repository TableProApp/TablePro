using System.Runtime.CompilerServices;

namespace TablePro.Core.Sql;

/// <summary>
/// A single-pass, allocation-free SQL lexer. It never fails: text it cannot classify becomes an operator token, and a
/// string, quoted name or comment left open runs to the end and is marked unterminated.
/// </summary>
public ref struct SqlLexer
{
    private readonly ReadOnlySpan<char> _text;
    private readonly SqlLexerFeatures _features;
    private int _position;

    public SqlLexer(ReadOnlySpan<char> text, SqlLexerFeatures features, int start = 0)
    {
        _text = text;
        _features = features;
        _position = start;
    }

    public readonly int Position => _position;

    public bool TryRead(out SqlToken token)
    {
        if (_position >= _text.Length)
        {
            token = default;
            return false;
        }

        var start = _position;
        var c = _text[start];

        if (char.IsWhiteSpace(c))
        {
            token = ReadWhitespace(start);
        }
        else if (c == '-' && Peek(1) == '-' && DashStartsComment())
        {
            token = ReadLineComment(start);
        }
        else if (c == '#' && Has(SqlLexerFeatures.HashComments))
        {
            token = ReadLineComment(start);
        }
        else if (c == '/' && Peek(1) == '*')
        {
            token = ReadBlockComment(start);
        }
        else if (c == '\'')
        {
            token = ReadQuoted(start, '\'', SqlTokenKind.String, Has(SqlLexerFeatures.BackslashEscapes));
        }
        else if (c == '"')
        {
            var isString = Has(SqlLexerFeatures.DoubleQuotedStrings);
            token = ReadQuoted(
                start,
                '"',
                isString ? SqlTokenKind.String : SqlTokenKind.QuotedIdentifier,
                isString && Has(SqlLexerFeatures.BackslashEscapes));
        }
        else if (c == '`' && Has(SqlLexerFeatures.BacktickIdentifiers))
        {
            token = ReadQuoted(start, '`', SqlTokenKind.QuotedIdentifier, backslashEscapes: false);
        }
        else if (c == '[' && Has(SqlLexerFeatures.BracketIdentifiers))
        {
            token = ReadQuoted(start, ']', SqlTokenKind.QuotedIdentifier, backslashEscapes: false);
        }
        else if (c == '$' && Has(SqlLexerFeatures.DollarQuotes) && TryReadDollarQuote(start, out var dollar))
        {
            token = dollar;
        }
        else if (c is '$' or '?' or ':' or '@' && IsParameterStart(start))
        {
            token = ReadParameter(start);
        }
        else if (c == ';')
        {
            token = Single(start, SqlTokenKind.Semicolon);
        }
        else if (c == '(')
        {
            token = Single(start, SqlTokenKind.OpenParen);
        }
        else if (c == ')')
        {
            token = Single(start, SqlTokenKind.CloseParen);
        }
        else if (c == ',')
        {
            token = Single(start, SqlTokenKind.Comma);
        }
        else if (char.IsAsciiDigit(c) || (c == '.' && char.IsAsciiDigit(Peek(1))))
        {
            token = ReadNumber(start);
        }
        else if (c == '.')
        {
            token = Single(start, SqlTokenKind.Dot);
        }
        else if (IsWordStart(c))
        {
            token = ReadWord(start);
        }
        else
        {
            token = ReadOperator(start);
        }

        return true;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private readonly bool Has(SqlLexerFeatures feature) => (_features & feature) != 0;

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private readonly char Peek(int offset)
    {
        var index = _position + offset;
        return (uint)index < (uint)_text.Length ? _text[index] : '\0';
    }

    public static bool IsWordStart(char c) => char.IsLetter(c) || c == '_';

    public static bool IsWordPart(char c) => char.IsLetterOrDigit(c) || c is '_' or '$';

    private readonly bool DashStartsComment()
    {
        if (!Has(SqlLexerFeatures.DashCommentNeedsSpace))
        {
            return true;
        }

        var next = Peek(2);
        return next == '\0' || char.IsWhiteSpace(next) || char.IsControl(next);
    }

    private SqlToken Single(int start, SqlTokenKind kind)
    {
        _position = start + 1;
        return new SqlToken(kind, start, 1);
    }

    private SqlToken ReadWhitespace(int start)
    {
        var i = start + 1;
        while (i < _text.Length && char.IsWhiteSpace(_text[i]))
        {
            i++;
        }

        _position = i;
        return new SqlToken(SqlTokenKind.Whitespace, start, i - start);
    }

    private SqlToken ReadWord(int start)
    {
        var i = start + 1;
        while (i < _text.Length && IsWordPart(_text[i]))
        {
            i++;
        }

        // A one-letter prefix glued to a quote (N'..', E'..', X'..', B'..') is one string literal.
        if (i == start + 1 && i < _text.Length && _text[i] == '\'' && _text[start] is 'N' or 'n' or 'E' or 'e' or 'X' or 'x' or 'B' or 'b')
        {
            var escapes = Has(SqlLexerFeatures.BackslashEscapes) || _text[start] is 'E' or 'e';
            var quoted = ReadQuoted(i, '\'', SqlTokenKind.String, escapes);
            return new SqlToken(SqlTokenKind.String, start, quoted.End - start, quoted.IsUnterminated);
        }

        _position = i;
        return new SqlToken(SqlTokenKind.Word, start, i - start);
    }

    private SqlToken ReadLineComment(int start)
    {
        var newline = _text[start..].IndexOfAny('\n', '\r');
        _position = newline < 0 ? _text.Length : start + newline;
        return new SqlToken(SqlTokenKind.LineComment, start, _position - start);
    }

    private SqlToken ReadBlockComment(int start)
    {
        var nested = Has(SqlLexerFeatures.NestedBlockComments);
        var depth = 1;
        var i = start + 2;
        while (i < _text.Length)
        {
            if (_text[i] == '*' && i + 1 < _text.Length && _text[i + 1] == '/')
            {
                i += 2;
                if (--depth == 0)
                {
                    _position = i;
                    return new SqlToken(SqlTokenKind.BlockComment, start, i - start);
                }

                continue;
            }

            if (nested && _text[i] == '/' && i + 1 < _text.Length && _text[i + 1] == '*')
            {
                depth++;
                i += 2;
                continue;
            }

            i++;
        }

        _position = _text.Length;
        return new SqlToken(SqlTokenKind.BlockComment, start, _position - start, IsUnterminated: true);
    }

    private SqlToken ReadQuoted(int start, char close, SqlTokenKind kind, bool backslashEscapes)
    {
        var i = start + 1;
        while (i < _text.Length)
        {
            var c = _text[i];
            if (backslashEscapes && c == '\\')
            {
                i += 2;
                continue;
            }

            if (c == close)
            {
                // A doubled closing quote is an escaped quote in every dialect.
                if (i + 1 < _text.Length && _text[i + 1] == close)
                {
                    i += 2;
                    continue;
                }

                _position = i + 1;
                return new SqlToken(kind, start, _position - start);
            }

            i++;
        }

        _position = _text.Length;
        return new SqlToken(kind, start, _position - start, IsUnterminated: true);
    }

    private bool TryReadDollarQuote(int start, out SqlToken token)
    {
        // $tag$ ... $tag$ where the tag is empty or an identifier. $1 is a parameter, not a quote.
        var i = start + 1;
        if (i < _text.Length && char.IsAsciiDigit(_text[i]))
        {
            token = default;
            return false;
        }

        while (i < _text.Length && (char.IsLetterOrDigit(_text[i]) || _text[i] == '_'))
        {
            i++;
        }

        if (i >= _text.Length || _text[i] != '$')
        {
            token = default;
            return false;
        }

        var delimiter = _text.Slice(start, i - start + 1);
        var bodyStart = i + 1;
        var close = _text[bodyStart..].IndexOf(delimiter);
        if (close < 0)
        {
            _position = _text.Length;
            token = new SqlToken(SqlTokenKind.String, start, _position - start, IsUnterminated: true);
            return true;
        }

        _position = bodyStart + close + delimiter.Length;
        token = new SqlToken(SqlTokenKind.String, start, _position - start);
        return true;
    }

    private readonly bool IsParameterStart(int start)
    {
        var next = Peek(1);
        return _text[start] switch
        {
            '?' => true,
            '$' => char.IsAsciiDigit(next) || IsWordStart(next),
            // :: is a PostgreSQL cast, so only a single colon before a name is a parameter.
            ':' => IsWordStart(next) && (start == 0 || _text[start - 1] != ':'),
            '@' => IsWordStart(next) || next == '@',
            _ => false,
        };
    }

    private SqlToken ReadParameter(int start)
    {
        var i = start + 1;
        if (_text[start] == '@' && i < _text.Length && _text[i] == '@')
        {
            i++;
        }

        while (i < _text.Length && (char.IsLetterOrDigit(_text[i]) || _text[i] == '_'))
        {
            i++;
        }

        _position = i;
        return new SqlToken(SqlTokenKind.Parameter, start, i - start);
    }

    private SqlToken ReadNumber(int start)
    {
        var i = start;
        if (_text[i] == '0' && i + 1 < _text.Length && _text[i + 1] is 'x' or 'X')
        {
            i += 2;
            while (i < _text.Length && char.IsAsciiHexDigit(_text[i]))
            {
                i++;
            }
        }
        else
        {
            while (i < _text.Length && (char.IsAsciiDigit(_text[i]) || _text[i] is '.' or '_'))
            {
                i++;
            }

            if (i < _text.Length && _text[i] is 'e' or 'E')
            {
                var j = i + 1;
                if (j < _text.Length && _text[j] is '+' or '-')
                {
                    j++;
                }

                if (j < _text.Length && char.IsAsciiDigit(_text[j]))
                {
                    i = j;
                    while (i < _text.Length && char.IsAsciiDigit(_text[i]))
                    {
                        i++;
                    }
                }
            }
        }

        _position = i;
        return new SqlToken(SqlTokenKind.Number, start, i - start);
    }

    private SqlToken ReadOperator(int start)
    {
        var i = start + 1;
        while (i < _text.Length && IsOperatorChar(_text[i]) && !StartsComment(i))
        {
            i++;
        }

        _position = i;
        return new SqlToken(SqlTokenKind.Operator, start, i - start);
    }

    private static bool IsOperatorChar(char c) =>
        c is '<' or '>' or '=' or '!' or '|' or '&' or ':' or '-' or '+' or '*' or '/' or '%' or '~' or '^';

    private readonly bool StartsComment(int i) =>
        i + 1 < _text.Length && ((_text[i] == '-' && _text[i + 1] == '-') || (_text[i] == '/' && _text[i + 1] == '*'));
}
