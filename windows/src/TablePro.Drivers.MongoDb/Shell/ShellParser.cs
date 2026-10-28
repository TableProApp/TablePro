using System.Globalization;
using MongoDB.Bson;

namespace TablePro.Drivers.MongoDb.Shell;

/// <summary>
/// Reads mongosh statements and values without running JavaScript: relaxed JSON (unquoted keys, single quotes,
/// trailing commas, comments), regular expression literals, the shell's constructors (<c>ObjectId</c>, <c>ISODate</c>,
/// <c>NumberLong</c>, <c>NumberDecimal</c>, <c>UUID</c> and the rest) and Extended JSON wrappers such as <c>$oid</c>.
/// Anything else, a variable, a function or an operator, is refused at its place.
/// </summary>
internal sealed class ShellParser
{
    private readonly string _text;
    private readonly IReadOnlyList<ShellToken> _tokens;
    private int _index;

    private ShellParser(string text)
    {
        _text = text;
        _tokens = ShellLexer.Tokenize(text);
    }

    private ShellToken Current => _tokens[_index];

    /// <summary>Reads one statement as the editor's splitter cut it.</summary>
    public static ShellStatement ParseStatement(string text)
    {
        var trimmed = text.Trim();
        if (TryReadWordCommand(trimmed, "use", out var database))
        {
            if (database.Length == 0)
            {
                throw new ShellSyntaxException("use needs a database name", text, text.Length);
            }

            return new UseStatement(text, database);
        }

        if (TryReadWordCommand(trimmed, "show", out var subject))
        {
            if (subject.Length == 0)
            {
                throw new ShellSyntaxException("show needs what to list, such as dbs or collections", text, text.Length);
            }

            return new ShowStatement(text, subject);
        }

        var parser = new ShellParser(text);
        return parser.ReadChain();
    }

    /// <summary>Reads text that holds exactly one value, such as a JSON cell or a raw filter.</summary>
    public static BsonValue ParseValue(string text)
    {
        var parser = new ShellParser(text);
        if (parser.Current.Kind == ShellTokenKind.End)
        {
            throw new ShellSyntaxException("Expected a value", text, 0);
        }

        var value = parser.ReadValue();
        parser.Expect(ShellTokenKind.End, "Unexpected text after the value");
        return value;
    }

    public static BsonDocument ParseDocument(string text)
    {
        var value = ParseValue(text);
        return value as BsonDocument ?? throw new ShellSyntaxException("Expected a document in braces", text, 0);
    }

    private static bool TryReadWordCommand(string text, string word, out string argument)
    {
        argument = string.Empty;
        if (!text.StartsWith(word, StringComparison.Ordinal) || (text.Length > word.Length && !char.IsWhiteSpace(text[word.Length])))
        {
            return false;
        }

        argument = text[word.Length..].Trim().TrimEnd(';').Trim();
        if (argument.Length >= 2 && argument[0] is '"' or '\'' && argument[^1] == argument[0])
        {
            argument = argument[1..^1];
        }

        return true;
    }

    private ChainStatement ReadChain()
    {
        var root = Current;
        if (root.Kind != ShellTokenKind.Identifier)
        {
            throw Error(root.Kind == ShellTokenKind.End ? "The statement is empty" : "A statement starts with db, use or show", root);
        }

        _index++;
        var segments = new List<ShellSegment>();
        while (true)
        {
            var token = Current;
            if (token.Is('.'))
            {
                _index++;
                var name = Current;
                if (name.Kind != ShellTokenKind.Identifier)
                {
                    throw Error("Expected a name after '.'", name);
                }

                segments.Add(new MemberSegment(name.Text, name.Position));
                _index++;
            }
            else if (token.Is('['))
            {
                _index++;
                var nameToken = Current;
                var value = ReadValue();
                if (!value.IsString)
                {
                    throw Error("A name in brackets must be a quoted string", nameToken);
                }

                Expect(']', "Expected ']'");
                segments.Add(new MemberSegment(value.AsString, nameToken.Position));
            }
            else if (token.Is('('))
            {
                _index++;
                segments.Add(new CallSegment(ReadList(')'), token.Position));
            }
            else
            {
                break;
            }
        }

        while (Current.Is(';'))
        {
            _index++;
        }

        if (Current.Kind != ShellTokenKind.End)
        {
            throw Error(Current.Is('=') ? "Assignments are not supported" : "Unexpected text after the statement", Current);
        }

        return new ChainStatement(_text, root.Text, segments);
    }

    private List<BsonValue> ReadList(char close)
    {
        var items = new List<BsonValue>();
        while (!Current.Is(close))
        {
            if (Current.Kind == ShellTokenKind.End)
            {
                throw Error($"Expected '{close}'", Current);
            }

            items.Add(ReadValue());
            if (Current.Is(','))
            {
                _index++;
            }
            else if (!Current.Is(close))
            {
                throw Error($"Expected ',' or '{close}'", Current);
            }
        }

        _index++;
        return items;
    }

    private BsonValue ReadValue()
    {
        var token = Current;
        switch (token.Kind)
        {
            case ShellTokenKind.String:
                _index++;
                return new BsonString(token.Text);
            case ShellTokenKind.Number:
                _index++;
                return ReadNumber(token, negative: false);
            case ShellTokenKind.Regex:
                _index++;
                return new BsonRegularExpression(token.Text, token.Flags);
            case ShellTokenKind.Identifier:
                return ReadNamedValue();
            case ShellTokenKind.End:
                throw Error("Expected a value", token);
        }

        if (token.Is('{'))
        {
            return ReadObject();
        }

        if (token.Is('['))
        {
            _index++;
            return new BsonArray(ReadList(']'));
        }

        if (token.Is('-') || token.Is('+'))
        {
            _index++;
            var number = Current;
            if (number.Kind == ShellTokenKind.Number)
            {
                _index++;
                return ReadNumber(number, token.Is('-'));
            }

            if (number.IsIdentifier("Infinity"))
            {
                _index++;
                return new BsonDouble(token.Is('-') ? double.NegativeInfinity : double.PositiveInfinity);
            }

            throw Error("Expected a number after the sign", number);
        }

        throw Error($"Unexpected '{token.Text}'", token);
    }

    private BsonValue ReadObject()
    {
        _index++;
        var document = new BsonDocument();
        while (!Current.Is('}'))
        {
            var key = Current;
            string name;
            switch (key.Kind)
            {
                case ShellTokenKind.Identifier:
                case ShellTokenKind.String:
                case ShellTokenKind.Number:
                    name = key.Text;
                    break;
                case ShellTokenKind.End:
                    throw Error("Expected '}'", key);
                default:
                    if (key.Is('.'))
                    {
                        throw Error("Spread syntax is not supported", key);
                    }

                    throw Error("Expected a field name", key);
            }

            _index++;
            if (!Current.Is(':'))
            {
                throw Error(Current.Is(',') || Current.Is('}') ? $"Field '{name}' needs a value: shorthand properties are not supported" : "Expected ':' after the field name", Current);
            }

            _index++;

            // A name written twice keeps its last value, as a JavaScript object literal does.
            document.Set(name, ReadValue());
            if (Current.Is(','))
            {
                _index++;
            }
            else if (!Current.Is('}'))
            {
                throw Error("Expected ',' or '}'", Current);
            }
        }

        _index++;
        return ExtendedJsonWrappers.TryUnwrap(document, out var unwrapped) ? unwrapped : document;
    }

    private BsonValue ReadNamedValue()
    {
        var token = Current;
        _index++;
        switch (token.Text)
        {
            case "true":
                return BsonBoolean.True;
            case "false":
                return BsonBoolean.False;
            case "null":
            case "undefined":
                return BsonNull.Value;
            case "Infinity":
                return new BsonDouble(double.PositiveInfinity);
            case "NaN":
                return new BsonDouble(double.NaN);
            case "MinKey" when !Current.Is('('):
                return BsonMinKey.Value;
            case "MaxKey" when !Current.Is('('):
                return BsonMaxKey.Value;
            case "function":
                throw Error("Functions are not supported", token);
            case "new":
                var constructor = Current;
                if (constructor.Kind != ShellTokenKind.Identifier)
                {
                    throw Error("Expected a constructor after new", constructor);
                }

                _index++;
                return ReadConstructor(constructor);
        }

        if (Current.Is('('))
        {
            return ReadConstructor(token);
        }

        if (Current.Is('=') && _index + 1 < _tokens.Count && _tokens[_index + 1].Is('>'))
        {
            throw Error("Functions are not supported", token);
        }

        throw Error($"'{token.Text}' is not a value: variables are not supported", token);
    }

    private BsonValue ReadConstructor(ShellToken name)
    {
        Expect('(', $"Expected '(' after {name.Text}");
        var args = ReadList(')');
        try
        {
            return ShellConstructors.Build(name.Text, args) ?? throw Error($"{name.Text}() is not supported", name);
        }
        catch (FormatException ex) when (ex is not ShellSyntaxException)
        {
            throw Error($"{name.Text}(): {ex.Message}", name);
        }
        catch (ArgumentException ex)
        {
            throw Error($"{name.Text}(): {ex.Message}", name);
        }
        catch (OverflowException ex)
        {
            throw Error($"{name.Text}(): {ex.Message}", name);
        }
    }

    private BsonValue ReadNumber(ShellToken token, bool negative)
    {
        var text = token.Text.Replace("_", string.Empty, StringComparison.Ordinal);
        if (text.Length > 2 && text[0] == '0' && char.ToLowerInvariant(text[1]) is 'x' or 'b' or 'o')
        {
            var radix = char.ToLowerInvariant(text[1]) switch { 'x' => 16, 'b' => 2, _ => 8 };
            long parsed;
            try
            {
                parsed = Convert.ToInt64(text[2..], radix);
            }
            catch (Exception ex) when (ex is FormatException or OverflowException or ArgumentException)
            {
                throw Error($"'{token.Text}' is not a number", token);
            }

            return Integer(negative ? -parsed : parsed);
        }

        var isWhole = text.AsSpan().IndexOfAny('.', 'e', 'E') < 0;
        var signed = negative ? "-" + text : text;
        if (isWhole && long.TryParse(signed, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var whole))
        {
            return Integer(whole);
        }

        if (double.TryParse(signed, NumberStyles.Float, CultureInfo.InvariantCulture, out var real))
        {
            return new BsonDouble(real);
        }

        throw Error($"'{token.Text}' is not a number", token);
    }

    // mongosh stores a whole number in the int32 range as an int; a larger one stays a long here rather than a double,
    // so an id or a counter past 2^53 keeps every digit.
    private static BsonValue Integer(long value) =>
        value is >= int.MinValue and <= int.MaxValue ? new BsonInt32((int)value) : new BsonInt64(value);

    private void Expect(char punctuation, string message)
    {
        if (!Current.Is(punctuation))
        {
            throw Error(message, Current);
        }

        _index++;
    }

    private void Expect(ShellTokenKind kind, string message)
    {
        if (Current.Kind != kind)
        {
            throw Error(message, Current);
        }
    }

    private ShellSyntaxException Error(string reason, ShellToken at) => new(reason, _text, at.Position);
}
