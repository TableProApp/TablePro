using System.Globalization;
using System.Text;

namespace TablePro.Drivers.MongoDb.Shell;

internal enum ShellTokenKind
{
    Identifier,
    String,
    Number,
    Regex,
    Punctuation,
    End,
}

/// <summary>
/// One token of a mongosh statement. <see cref="Text"/> is a string's unescaped value, a regex's pattern, an identifier
/// or number as written, or the punctuation character. <see cref="Flags"/> holds a regex's options.
/// </summary>
internal readonly record struct ShellToken(ShellTokenKind Kind, string Text, int Position, string Flags = "")
{
    public bool Is(char punctuation) => Kind == ShellTokenKind.Punctuation && Text.Length == 1 && Text[0] == punctuation;

    public bool IsIdentifier(string name) => Kind == ShellTokenKind.Identifier && Text == name;
}

/// <summary>
/// Splits a mongosh statement into tokens. A <c>/</c> starts a regular expression where a value may begin, as
/// JavaScript decides it: after an operator or an opening bracket, never after a name, number or closing bracket.
/// </summary>
internal sealed class ShellLexer
{
    private readonly string _text;
    private int _position;
    private ShellToken? _previous;

    public ShellLexer(string text)
    {
        _text = text;
    }

    public static IReadOnlyList<ShellToken> Tokenize(string text)
    {
        var lexer = new ShellLexer(text);
        var tokens = new List<ShellToken>();
        ShellToken token;
        do
        {
            token = lexer.Next();
            tokens.Add(token);
        }
        while (token.Kind != ShellTokenKind.End);

        return tokens;
    }

    public ShellToken Next()
    {
        SkipTrivia();
        var token = Read();
        _previous = token;
        return token;
    }

    private ShellToken Read()
    {
        if (_position >= _text.Length)
        {
            return new ShellToken(ShellTokenKind.End, string.Empty, _text.Length);
        }

        var start = _position;
        var c = _text[_position];
        if (c is '"' or '\'' or '`')
        {
            return new ShellToken(ShellTokenKind.String, ReadString(c), start);
        }

        if (char.IsAsciiDigit(c) || (c == '.' && _position + 1 < _text.Length && char.IsAsciiDigit(_text[_position + 1])))
        {
            return new ShellToken(ShellTokenKind.Number, ReadNumber(), start);
        }

        if (IsIdentifierStart(c))
        {
            while (_position < _text.Length && IsIdentifierPart(_text[_position]))
            {
                _position++;
            }

            return new ShellToken(ShellTokenKind.Identifier, _text[start.._position], start);
        }

        if (c == '/' && RegexMayStart())
        {
            return ReadRegex();
        }

        _position++;
        return new ShellToken(ShellTokenKind.Punctuation, c.ToString(), start);
    }

    private bool RegexMayStart() => _previous is not { } previous
        || previous.Kind == ShellTokenKind.Punctuation && previous.Text is not (")" or "]" or "}");

    private void SkipTrivia()
    {
        while (_position < _text.Length)
        {
            var c = _text[_position];
            if (char.IsWhiteSpace(c))
            {
                _position++;
            }
            else if (c == '/' && Peek(1) == '/')
            {
                while (_position < _text.Length && _text[_position] != '\n')
                {
                    _position++;
                }
            }
            else if (c == '/' && Peek(1) == '*')
            {
                var close = _text.IndexOf("*/", _position + 2, StringComparison.Ordinal);
                if (close < 0)
                {
                    throw new ShellSyntaxException("The comment is not closed", _text, _position);
                }

                _position = close + 2;
            }
            else
            {
                return;
            }
        }
    }

    private char Peek(int offset) => _position + offset < _text.Length ? _text[_position + offset] : '\0';

    private string ReadString(char quote)
    {
        var start = _position;
        _position++;
        var sb = new StringBuilder();
        while (_position < _text.Length)
        {
            var c = _text[_position++];
            if (c == quote)
            {
                return sb.ToString();
            }

            if (c == '\\')
            {
                if (_position >= _text.Length)
                {
                    break;
                }

                var escaped = _text[_position++];
                switch (escaped)
                {
                    case 'n': sb.Append('\n'); break;
                    case 't': sb.Append('\t'); break;
                    case 'r': sb.Append('\r'); break;
                    case 'b': sb.Append('\b'); break;
                    case 'f': sb.Append('\f'); break;
                    case 'v': sb.Append('\v'); break;
                    case '0' when !char.IsAsciiDigit(Peek(0)): sb.Append('\0'); break;
                    case 'x': sb.Append((char)ReadHex(2, start)); break;
                    case 'u' when Peek(0) == '{':
                        var close = _text.IndexOf('}', _position);
                        if (close < 0 || !int.TryParse(_text.AsSpan(_position + 1, close - _position - 1), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var codePoint) || codePoint > 0x10FFFF)
                        {
                            throw new ShellSyntaxException("Invalid Unicode escape", _text, _position - 2);
                        }

                        sb.Append(char.ConvertFromUtf32(codePoint));
                        _position = close + 1;
                        break;
                    case 'u': sb.Append((char)ReadHex(4, start)); break;
                    case '\r':
                        // A backslash before a line break continues the string on the next line.
                        if (Peek(0) == '\n')
                        {
                            _position++;
                        }

                        break;
                    case '\n': break;
                    default: sb.Append(escaped); break;
                }

                continue;
            }

            if (c == '\n' && quote != '`')
            {
                throw new ShellSyntaxException("The string is not closed before the end of the line", _text, start);
            }

            sb.Append(c);
        }

        throw new ShellSyntaxException("The string is not closed", _text, start);
    }

    private int ReadHex(int digits, int stringStart)
    {
        if (_position + digits > _text.Length
            || !int.TryParse(_text.AsSpan(_position, digits), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var value))
        {
            throw new ShellSyntaxException("Invalid escape sequence in the string", _text, Math.Max(stringStart, _position - 2));
        }

        _position += digits;
        return value;
    }

    private string ReadNumber()
    {
        var start = _position;
        if (_text[_position] == '0' && Peek(1) is 'x' or 'X' or 'b' or 'B' or 'o' or 'O')
        {
            _position += 2;
            while (_position < _text.Length && (char.IsAsciiHexDigit(_text[_position]) || _text[_position] == '_'))
            {
                _position++;
            }

            return _text[start.._position];
        }

        while (_position < _text.Length && (char.IsAsciiDigit(_text[_position]) || _text[_position] == '_'))
        {
            _position++;
        }

        if (Peek(0) == '.')
        {
            _position++;
            while (_position < _text.Length && (char.IsAsciiDigit(_text[_position]) || _text[_position] == '_'))
            {
                _position++;
            }
        }

        if (Peek(0) is 'e' or 'E' && (char.IsAsciiDigit(Peek(1)) || (Peek(1) is '+' or '-' && char.IsAsciiDigit(Peek(2)))))
        {
            _position += 2;
            while (_position < _text.Length && char.IsAsciiDigit(_text[_position]))
            {
                _position++;
            }
        }

        if (_position < _text.Length && IsIdentifierStart(_text[_position]))
        {
            throw new ShellSyntaxException("A name cannot start right after a number", _text, _position);
        }

        return _text[start.._position];
    }

    private ShellToken ReadRegex()
    {
        var start = _position;
        _position++;
        var pattern = new StringBuilder();
        var inClass = false;
        while (true)
        {
            if (_position >= _text.Length || _text[_position] == '\n')
            {
                throw new ShellSyntaxException("The regular expression is not closed", _text, start);
            }

            var c = _text[_position++];
            if (c == '\\' && _position < _text.Length)
            {
                pattern.Append(c).Append(_text[_position++]);
                continue;
            }

            if (c == '[')
            {
                inClass = true;
            }
            else if (c == ']')
            {
                inClass = false;
            }
            else if (c == '/' && !inClass)
            {
                break;
            }

            pattern.Append(c);
        }

        var flagsStart = _position;
        while (_position < _text.Length && char.IsAsciiLetter(_text[_position]))
        {
            _position++;
        }

        var flags = _text[flagsStart.._position];
        foreach (var flag in flags)
        {
            if (flag is not ('i' or 'm' or 's' or 'x' or 'u' or 'g' or 'y'))
            {
                throw new ShellSyntaxException($"'{flag}' is not a regular expression flag", _text, flagsStart);
            }
        }

        // BSON keeps only the flags the server understands, in the alphabetical order it stores them.
        var kept = new string(flags.Where(f => f is 'i' or 'm' or 's' or 'x' or 'u').Distinct().Order().ToArray());
        return new ShellToken(ShellTokenKind.Regex, pattern.ToString(), start, kept);
    }

    private static bool IsIdentifierStart(char c) => char.IsLetter(c) || c is '_' or '$';

    private static bool IsIdentifierPart(char c) => char.IsLetterOrDigit(c) || c is '_' or '$';
}
