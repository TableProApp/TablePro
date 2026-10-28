using System.Globalization;
using Amazon.DynamoDBv2.Model;
using TablePro.Core.Browse;
using TablePro.Core.Results;

namespace TablePro.Drivers.DynamoDb;

/// <summary>A Scan's FilterExpression with its placeholders, plus what is checked on the items that come back.</summary>
public sealed record DynamoFilterPlan(
    string? Expression,
    IReadOnlyDictionary<string, string> Names,
    IReadOnlyDictionary<string, AttributeValue> Values,
    DynamoItemFilter? ClientFilter,
    bool MatchesNothing,
    IReadOnlyList<string> Notices)
{
    /// <summary>Identifies the scan, which a saved ExclusiveStartKey is only valid for.</summary>
    public string ResumeKey =>
        (Expression ?? string.Empty) + "\u001f" + string.Join("\u001f", Values.OrderBy(v => v.Key, StringComparer.Ordinal).Select(v => v.Key + "=" + DynamoAttributeMapper.ToJson(v.Value)))
        + "\u001f" + string.Join("\u001f", ClientFilter?.Rules.Select(r => r.ToString()) ?? []);
}

/// <summary>
/// Turns filter strip rules into a DynamoDB FilterExpression. Names and values always go through placeholders. A key
/// attribute is compared with its declared type; any other attribute may hold a String in one item and a Number in the
/// next, so text that reads as a number is compared as both. What DynamoDB cannot evaluate (a suffix match, a search
/// across attributes, a case-insensitive match) is checked on the items read.
/// </summary>
public static partial class DynamoFilterTranslator
{
    private const int MaxInOperands = 100;

    public static DynamoFilterPlan Translate(BrowseFilter filter, IReadOnlyDictionary<string, string> keyTypes)
    {
        var context = new Context(keyTypes);
        var rules = filter.Rules.Where(r => r.Enabled).ToList();
        var notices = new List<string>();
        var server = new List<string>();
        var client = new List<FilterRule>();
        var never = false;

        foreach (var rule in rules)
        {
            var term = context.Translate(rule);
            if (term is null)
            {
                client.Add(rule);
            }
            else if (term == Context.Never)
            {
                never = true;
            }
            else
            {
                server.Add(term);
            }
        }

        var matchAll = filter.MatchAll || rules.Count <= 1;
        if (!matchAll && client.Count > 0)
        {
            // An OR cannot be split between DynamoDB and the client, so every rule is checked on the items read.
            context = new Context(keyTypes);
            server.Clear();
            client = rules;
            never = false;
        }

        var raw = filter.RawWhere?.Trim();
        string? expression = null;
        if (server.Count > 0)
        {
            expression = server.Count == 1 ? server[0] : "(" + string.Join(matchAll ? " AND " : " OR ", server) + ")";
        }

        if (!string.IsNullOrEmpty(raw))
        {
            expression = expression is null ? $"({raw})" : $"{expression} AND ({raw})";
            if (!matchAll && rules.Count > 0)
            {
                notices.Add("The raw condition must match as well as the rules.");
            }
        }

        var matchesNothing = matchAll ? never : never && server.Count == 0 && client.Count == 0 && string.IsNullOrEmpty(raw);
        DynamoItemFilter? clientFilter = null;
        if (client.Count > 0)
        {
            clientFilter = new DynamoItemFilter(client, matchAll, filter.SearchColumns);
            notices.Add(string.Create(CultureInfo.InvariantCulture, $"{client.Count} filter rule(s) DynamoDB cannot evaluate were applied to the items read, page by page."));
        }

        // DynamoDB refuses a placeholder the expression does not use, and a rule that matched nothing or moved to the
        // client may have named one.
        var used = expression is null ? [] : Placeholder().Matches(expression).Select(m => m.Value).ToHashSet(StringComparer.Ordinal);
        var names = context.Names.Where(n => used.Contains(n.Key)).ToDictionary(StringComparer.Ordinal);
        var values = context.Values.Where(v => used.Contains(v.Key)).ToDictionary(StringComparer.Ordinal);
        return new DynamoFilterPlan(expression, names, values, clientFilter, matchesNothing, notices);
    }

    [System.Text.RegularExpressions.GeneratedRegex(@"[#:][nv]\d+", System.Text.RegularExpressions.RegexOptions.CultureInvariant)]
    private static partial System.Text.RegularExpressions.Regex Placeholder();

    private sealed class Context(IReadOnlyDictionary<string, string> keyTypes)
    {
        public const string Never = "\0never";

        private readonly Dictionary<string, string> _names = new(StringComparer.Ordinal);
        private readonly Dictionary<string, string> _namesByAttribute = new(StringComparer.Ordinal);
        private readonly Dictionary<string, AttributeValue> _values = new(StringComparer.Ordinal);

        public IReadOnlyDictionary<string, string> Names => _names;

        public IReadOnlyDictionary<string, AttributeValue> Values => _values;

        public string? Translate(FilterRule rule)
        {
            if (rule.Column is null)
            {
                return null;
            }

            var attribute = rule.Column;
            var keyType = keyTypes.GetValueOrDefault(attribute);
            var value = rule.Value ?? string.Empty;
            var name = Name(attribute);

            switch (rule.Operator)
            {
                case FilterOperator.IsNull:
                    return $"(attribute_not_exists({name}) OR attribute_type({name}, {NullType()}))";
                case FilterOperator.IsNotNull:
                    return $"(attribute_exists({name}) AND NOT attribute_type({name}, {NullType()}))";
                case FilterOperator.IsEmpty:
                    return $"(attribute_not_exists({name}) OR attribute_type({name}, {NullType()}) OR {name} = {Value(new AttributeValue { S = string.Empty })})";
                case FilterOperator.IsNotEmpty:
                    return $"(attribute_exists({name}) AND NOT attribute_type({name}, {NullType()}) AND {name} <> {Value(new AttributeValue { S = string.Empty })})";
                case FilterOperator.Equals:
                    return Any(Candidates(keyType, value, withBoolean: true).Select(c => $"{name} = {Value(c)}"));
                case FilterOperator.NotEquals:
                    return All([$"attribute_exists({name})", .. Candidates(keyType, value, withBoolean: true).Select(c => $"{name} <> {Value(c)}")]);
                case FilterOperator.GreaterThan or FilterOperator.GreaterOrEqual or FilterOperator.LessThan or FilterOperator.LessOrEqual:
                    var op = rule.Operator switch
                    {
                        FilterOperator.GreaterThan => ">",
                        FilterOperator.GreaterOrEqual => ">=",
                        FilterOperator.LessThan => "<",
                        _ => "<=",
                    };
                    return Any(Candidates(keyType, value, withBoolean: false).Select(c => $"{name} {op} {Value(c)}"));
                case FilterOperator.Contains or FilterOperator.NotContains or FilterOperator.StartsWith when HasCase(value):
                    // DynamoDB compares case-sensitively; the filter strip does not, as on every other engine.
                    return null;
                case FilterOperator.Contains or FilterOperator.NotContains:
                    var contained = Any(Candidates(keyType, value, withBoolean: false).Select(c => $"contains({name}, {Value(c)})"));
                    if (contained == Never)
                    {
                        return rule.Operator == FilterOperator.Contains ? Never : $"attribute_exists({name})";
                    }

                    return rule.Operator == FilterOperator.Contains ? contained : $"(attribute_exists({name}) AND NOT {contained})";
                case FilterOperator.StartsWith:
                    return keyType == DynamoAttributeMapper.Number ? Never : $"begins_with({name}, {Value(new AttributeValue { S = value })})";
                case FilterOperator.In or FilterOperator.NotIn:
                    var placeholders = Items(value).SelectMany(item => Candidates(keyType, item, withBoolean: true)).Select(Value).ToList();
                    if (placeholders.Count == 0)
                    {
                        return rule.Operator == FilterOperator.In ? Never : $"attribute_exists({name})";
                    }

                    var membership = Any(placeholders.Chunk(MaxInOperands).Select(chunk => $"{name} IN ({string.Join(", ", chunk)})"));
                    return rule.Operator == FilterOperator.In ? membership : $"(attribute_exists({name}) AND NOT {membership})";
                case FilterOperator.Between:
                    return Between(name, keyType, value, rule.SecondValue);
                default:
                    return null;
            }
        }

        private string Between(string name, string? keyType, string lower, string? upper)
        {
            if (string.IsNullOrWhiteSpace(lower) || string.IsNullOrWhiteSpace(upper))
            {
                return Never;
            }

            var uppers = Candidates(keyType, upper, withBoolean: false);
            var terms = new List<string>();
            foreach (var low in Candidates(keyType, lower, withBoolean: false))
            {
                var high = uppers.FirstOrDefault(u => DynamoAttributeMapper.TypeOf(u) == DynamoAttributeMapper.TypeOf(low));

                // DynamoDB refuses a BETWEEN whose bounds are reversed instead of matching nothing.
                if (high is not null && !IsReversed(low, high))
                {
                    terms.Add($"{name} BETWEEN {Value(low)} AND {Value(high)}");
                }
            }

            return Any(terms);
        }

        private static List<AttributeValue> Candidates(string? keyType, string text, bool withBoolean)
        {
            var trimmed = text.Trim();
            if (keyType is not null)
            {
                return keyType switch
                {
                    DynamoAttributeMapper.Number => DynamoAttributeMapper.IsNumber(trimmed) ? [new AttributeValue { N = trimmed }] : [],
                    DynamoAttributeMapper.Binary => TryBinary(text) is { } bytes ? [new AttributeValue { B = new MemoryStream(bytes) }] : [],
                    _ => [new AttributeValue { S = text }],
                };
            }

            var values = new List<AttributeValue> { new() { S = text } };
            if (trimmed.Length > 0 && DynamoAttributeMapper.IsNumber(trimmed))
            {
                values.Add(new AttributeValue { N = trimmed });
            }

            if (withBoolean && bool.TryParse(trimmed, out var b))
            {
                values.Add(new AttributeValue { BOOL = b });
            }

            return values;
        }

        private static bool IsReversed(AttributeValue low, AttributeValue high)
        {
            if (low.N is not null && high.N is not null)
            {
                return decimal.TryParse(low.N, NumberStyles.Float, CultureInfo.InvariantCulture, out var a)
                    && decimal.TryParse(high.N, NumberStyles.Float, CultureInfo.InvariantCulture, out var b)
                    && a > b;
            }

            // DynamoDB orders strings by their UTF-8 bytes, which ordinal UTF-16 order matches outside surrogates.
            return low.S is not null && high.S is not null && string.CompareOrdinal(low.S, high.S) > 0;
        }

        private static byte[]? TryBinary(string text)
        {
            try
            {
                return DynamoAttributeMapper.DecodeBinary(text);
            }
            catch (FormatException)
            {
                return null;
            }
        }

        private string NullType() => Value(new AttributeValue { S = DynamoAttributeMapper.Null });

        private string Name(string attribute)
        {
            if (!_namesByAttribute.TryGetValue(attribute, out var placeholder))
            {
                placeholder = string.Create(CultureInfo.InvariantCulture, $"#n{_names.Count}");
                _names[placeholder] = attribute;
                _namesByAttribute[attribute] = placeholder;
            }

            return placeholder;
        }

        private string Value(AttributeValue value)
        {
            var placeholder = string.Create(CultureInfo.InvariantCulture, $":v{_values.Count}");
            _values[placeholder] = value;
            return placeholder;
        }

        private static string Any(IEnumerable<string> terms)
        {
            var list = terms.ToList();
            return list.Count switch
            {
                0 => Never,
                1 => list[0],
                _ => "(" + string.Join(" OR ", list) + ")",
            };
        }

        private static string All(IReadOnlyList<string> terms) => terms.Count == 1 ? terms[0] : "(" + string.Join(" AND ", terms) + ")";

        private static bool HasCase(string text) => text.Any(c => char.ToUpperInvariant(c) != char.ToLowerInvariant(c));

        private static string[] Items(string csv) => csv.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
    }
}

/// <summary>Filter rules checked on items as they arrive, with the meaning the SQL engines give them.</summary>
public sealed class DynamoItemFilter(IReadOnlyList<FilterRule> rules, bool matchAll, IReadOnlyList<string> searchColumns)
{
    public IReadOnlyList<FilterRule> Rules => rules;

    public bool Matches(IReadOnlyDictionary<string, AttributeValue> item) =>
        matchAll ? rules.All(rule => Matches(rule, item)) : rules.Any(rule => Matches(rule, item));

    private bool Matches(FilterRule rule, IReadOnlyDictionary<string, AttributeValue> item)
    {
        if (rule.Column is null)
        {
            var needle = rule.Value ?? string.Empty;
            var values = searchColumns.Count > 0
                ? searchColumns.Select(c => item.GetValueOrDefault(c))
                : item.Values;
            return needle.Length == 0 || values.Any(v => Text(v)?.Contains(needle, StringComparison.OrdinalIgnoreCase) == true);
        }

        return MatchesText(rule, Text(item.GetValueOrDefault(rule.Column)));
    }

    public static bool MatchesText(FilterRule rule, string? text)
    {
        var value = rule.Value ?? string.Empty;
        return rule.Operator switch
        {
            FilterOperator.IsNull => text is null,
            FilterOperator.IsNotNull => text is not null,
            FilterOperator.IsEmpty => string.IsNullOrEmpty(text),
            FilterOperator.IsNotEmpty => !string.IsNullOrEmpty(text),
            _ when text is null => false,
            FilterOperator.Equals => Compare(text, value) == 0,
            FilterOperator.NotEquals => Compare(text, value) != 0,
            FilterOperator.GreaterThan => Compare(text, value) > 0,
            FilterOperator.GreaterOrEqual => Compare(text, value) >= 0,
            FilterOperator.LessThan => Compare(text, value) < 0,
            FilterOperator.LessOrEqual => Compare(text, value) <= 0,
            FilterOperator.Contains => text.Contains(value, StringComparison.OrdinalIgnoreCase),
            FilterOperator.NotContains => !text.Contains(value, StringComparison.OrdinalIgnoreCase),
            FilterOperator.StartsWith => text.StartsWith(value, StringComparison.OrdinalIgnoreCase),
            FilterOperator.EndsWith => text.EndsWith(value, StringComparison.OrdinalIgnoreCase),
            FilterOperator.In => Items(value).Any(item => Compare(text, item) == 0),
            FilterOperator.NotIn => !Items(value).Any(item => Compare(text, item) == 0),
            FilterOperator.Between => Compare(text, value) >= 0 && Compare(text, rule.SecondValue ?? string.Empty) <= 0,
            _ => true,
        };
    }

    /// <summary>Numbers compare as numbers, everything else as text without regard to case.</summary>
    public static int Compare(string left, string right) =>
        decimal.TryParse(left, NumberStyles.Float, CultureInfo.InvariantCulture, out var a)
        && decimal.TryParse(right.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var b)
            ? a.CompareTo(b)
            : string.Compare(left, right, StringComparison.OrdinalIgnoreCase);

    private static string? Text(AttributeValue? value) =>
        value is null || value.NULL == true ? null : CellFormatter.Format(DynamoAttributeMapper.ToCell(value));

    private static string[] Items(string csv) => csv.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
}
