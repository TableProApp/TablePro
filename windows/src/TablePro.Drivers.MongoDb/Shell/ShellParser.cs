using System.Globalization;
using MongoDB.Bson;
using TablePro.Drivers.MongoDb.Localization;

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
                throw new ShellSyntaxException(MongoStrings.Get("Mongo/UseNeedsDatabase"), text, text.Length);
            }

            return new UseStatement(text, database);
        }

        if (TryReadWordCommand(trimmed, "show", out var subject))
        {
            if (subject.Length == 0)
            {
                throw new ShellSyntaxException(MongoStrings.Get("Mongo/ShowNeedsWhat"), text, text.Length);
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
            throw new ShellSyntaxException(MongoStrings.Get("Mongo/ExpectedValue"), text, 0);
        }

        var value = parser.ReadValue();
        parser.Expect(ShellTokenKind.End, MongoStrings.Get("Mongo/UnexpectedAfterValue"));
        return value;
    }

    public static BsonDocument ParseDocument(string text)
    {
        var value = ParseValue(text);
        return value as BsonDocument ?? throw new ShellSyntaxException(MongoStrings.Get("Mongo/ExpectedDocument"), text, 0);
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
            throw Error(MongoStrings.Get(root.Kind == ShellTokenKind.End ? "Mongo/StatementEmpty" : "Mongo/StatementStart"), root);
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
                    throw Error(MongoStrings.Get("Mongo/ExpectedNameAfterDot"), name);
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
                    throw Error(MongoStrings.Get("Mongo/BracketNameQuoted"), nameToken);
                }

                Expect(']', MongoStrings.Format("Mongo/ExpectedChar", ']'));
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
            throw Error(MongoStrings.Get(Current.Is('=') ? "Mongo/AssignmentsUnsupported" : "Mongo/UnexpectedAfterStatement"), Current);
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
                throw Error(MongoStrings.Format("Mongo/ExpectedChar", close), Current);
            }

            items.Add(ReadValue());
            if (Current.Is(','))
            {
                _index++;
            }
            else if (!Current.Is(close))
            {
                throw Error(MongoStrings.Format("Mongo/ExpectedCommaOr", close), Current);
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
                throw Error(MongoStrings.Get("Mongo/ExpectedValue"), token);
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

            throw Error(MongoStrings.Get("Mongo/ExpectedNumberAfterSign"), number);
        }

        throw Error(MongoStrings.Format("Mongo/UnexpectedToken", token.Text), token);
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
                    throw Error(MongoStrings.Format("Mongo/ExpectedChar", '}'), key);
                default:
                    if (key.Is('.'))
                    {
                        throw Error(MongoStrings.Get("Mongo/SpreadUnsupported"), key);
                    }

                    throw Error(MongoStrings.Get("Mongo/ExpectedFieldName"), key);
            }

            _index++;
            if (!Current.Is(':'))
            {
                throw Error(Current.Is(',') || Current.Is('}') ? MongoStrings.Format("Mongo/ShorthandUnsupported", name) : MongoStrings.Get("Mongo/ExpectedColon"), Current);
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
                throw Error(MongoStrings.Format("Mongo/ExpectedCommaOr", '}'), Current);
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
                throw Error(MongoStrings.Get("Mongo/FunctionsUnsupported"), token);
            case "new":
                var constructor = Current;
                if (constructor.Kind != ShellTokenKind.Identifier)
                {
                    throw Error(MongoStrings.Get("Mongo/ExpectedConstructor"), constructor);
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
            throw Error(MongoStrings.Get("Mongo/FunctionsUnsupported"), token);
        }

        throw Error(MongoStrings.Format("Mongo/NotAValue", token.Text), token);
    }

    private BsonValue ReadConstructor(ShellToken name)
    {
        Expect('(', MongoStrings.Format("Mongo/ExpectedParenAfter", name.Text));
        var args = ReadList(')');
        try
        {
            return ShellConstructors.Build(name.Text, args) ?? throw Error(MongoStrings.Format("Mongo/ConstructorUnsupported", name.Text), name);
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
                throw Error(MongoStrings.Format("Mongo/NotANumber", "'" + token.Text + "'"), token);
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

        throw Error(MongoStrings.Format("Mongo/NotANumber", "'" + token.Text + "'"), token);
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
