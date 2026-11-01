using System.Globalization;
using System.Text;
using MongoDB.Bson;
using TablePro.Core.Browse;
using TablePro.Drivers.MongoDb.Shell;

namespace TablePro.Drivers.MongoDb.Documents;

/// <summary>
/// Turns the filter strip's rules into a query document. MongoDB compares within a BSON type, so a value is typed by
/// its column (a date column gets a date, an ObjectId column an ObjectId) rather than sent as the text typed.
/// Pattern operators are case-insensitive regular expressions with the text escaped.
/// </summary>
internal static class MongoFilter
{
    public static BsonDocument Build(BrowseFilter filter, CollectionSchema schema)
    {
        var clauses = new List<BsonDocument>(filter.Rules.Count + 1);
        foreach (var rule in filter.Rules)
        {
            if (rule.Enabled && Clause(rule, filter, schema) is { } clause)
            {
                clauses.Add(clause);
            }
        }

        var combined = clauses.Count switch
        {
            0 => new BsonDocument(),
            1 => clauses[0],
            _ => new BsonDocument(filter.MatchAll ? "$and" : "$or", new BsonArray(clauses)),
        };

        if (string.IsNullOrWhiteSpace(filter.RawWhere))
        {
            return combined;
        }

        var raw = ShellParser.ParseDocument(filter.RawWhere);
        return combined.ElementCount == 0 ? raw : new BsonDocument("$and", new BsonArray { raw, combined });
    }

    public static BsonDocument? Clause(FilterRule rule, BrowseFilter filter, CollectionSchema schema)
    {
        if (rule.Column is null)
        {
            return Search(rule.Value, filter.SearchColumns.Count > 0 ? filter.SearchColumns : schema.Columns.Select(c => c.Name).ToArray());
        }

        // A name starting with $ reads as an operator, so no query can name such a field.
        if (rule.Column.StartsWith('$'))
        {
            return null;
        }

        var field = rule.Column;
        var column = schema.Find(field);
        var value = rule.Value ?? string.Empty;
        return rule.Operator switch
        {
            FilterOperator.Equals => Equality(field, value, column),
            FilterOperator.NotEquals => new BsonDocument(field, new BsonDocument("$ne", Typed(value, column))),
            FilterOperator.GreaterThan => Compare(field, "$gt", value, column),
            FilterOperator.GreaterOrEqual => Compare(field, "$gte", value, column),
            FilterOperator.LessThan => Compare(field, "$lt", value, column),
            FilterOperator.LessOrEqual => Compare(field, "$lte", value, column),
            FilterOperator.Contains => Pattern(field, EscapeRegex(value)),
            FilterOperator.NotContains => new BsonDocument(field, new BsonDocument("$not", new BsonRegularExpression(EscapeRegex(value), "i"))),
            FilterOperator.StartsWith => Pattern(field, "^" + EscapeRegex(value)),
            FilterOperator.EndsWith => Pattern(field, EscapeRegex(value) + "$"),

            // A null matches a missing field too, as SQL's NULL stands for both.
            FilterOperator.IsNull => new BsonDocument(field, BsonNull.Value),
            FilterOperator.IsNotNull => new BsonDocument(field, new BsonDocument("$ne", BsonNull.Value)),
            FilterOperator.IsEmpty => new BsonDocument(field, new BsonDocument("$in", new BsonArray { BsonNull.Value, string.Empty })),
            FilterOperator.IsNotEmpty => new BsonDocument(field, new BsonDocument("$nin", new BsonArray { BsonNull.Value, string.Empty })),
            FilterOperator.In => new BsonDocument(field, new BsonDocument("$in", List(value, column))),
            FilterOperator.NotIn => new BsonDocument(field, new BsonDocument("$nin", List(value, column))),
            FilterOperator.Between => new BsonDocument(field, new BsonDocument
            {
                { "$gte", Typed(value, column) },
                { "$lte", Typed(rule.SecondValue ?? string.Empty, column) },
            }),
            _ => null,
        };
    }

    /// <summary>The value as the type the column holds; for a column of no single type, as its own spelling suggests.</summary>
    public static BsonValue Typed(string text, FieldColumn? column)
    {
        var inv = CultureInfo.InvariantCulture;
        var trimmed = text.Trim();
        switch (column?.Kind)
        {
            case FieldKind.String:
                return new BsonString(text);
            case FieldKind.Int or FieldKind.Long when long.TryParse(trimmed, NumberStyles.AllowLeadingSign, inv, out var whole):
                return whole is >= int.MinValue and <= int.MaxValue ? new BsonInt32((int)whole) : new BsonInt64(whole);
            case FieldKind.Int or FieldKind.Long or FieldKind.Double when double.TryParse(trimmed, NumberStyles.Float, inv, out var real):
                return new BsonDouble(real);
            case FieldKind.Decimal when Decimal128.TryParse(trimmed, out var dec):
                return new BsonDecimal128(dec);
            case FieldKind.Bool when bool.TryParse(trimmed, out var flag):
                return BsonBoolean.Create(flag);
            case FieldKind.Date when ShellConstructors.TryParseDate(trimmed, out var utc):
                return new BsonDateTime(utc);
            case FieldKind.ObjectId when ObjectId.TryParse(trimmed, out var id):
                return new BsonObjectId(id);
            case FieldKind.Json or null:
                return Untyped(text);
            default:
                return new BsonString(text);
        }
    }

    public static string EscapeRegex(string text)
    {
        var sb = new StringBuilder(text.Length + 8);
        foreach (var c in text)
        {
            if (c is '\\' or '^' or '$' or '.' or '|' or '?' or '*' or '+' or '(' or ')' or '[' or ']' or '{' or '}')
            {
                sb.Append('\\');
            }

            sb.Append(c);
        }

        return sb.ToString();
    }

    private static BsonValue Untyped(string text)
    {
        var trimmed = text.Trim();
        if (trimmed is "true" or "false")
        {
            return BsonBoolean.Create(trimmed == "true");
        }

        if (trimmed == "null")
        {
            return BsonNull.Value;
        }

        if (long.TryParse(trimmed, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var whole))
        {
            return whole is >= int.MinValue and <= int.MaxValue ? new BsonInt32((int)whole) : new BsonInt64(whole);
        }

        if (double.TryParse(trimmed, NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint | NumberStyles.AllowExponent, CultureInfo.InvariantCulture, out var real))
        {
            return new BsonDouble(real);
        }

        // A JSON cell's value is filtered by the same text the cell shows: {"$oid": ...}, "text", [1, 2].
        if (trimmed.Length > 0 && trimmed[0] is '{' or '[' or '"')
        {
            try
            {
                return ShellParser.ParseValue(trimmed);
            }
            catch (ShellSyntaxException)
            {
                return new BsonString(text);
            }
        }

        return new BsonString(text);
    }

    private static BsonDocument Equality(string field, string text, FieldColumn? column)
    {
        // Hex text in a column of no single type may name an ObjectId or be a plain string; match either.
        if (column is null or { Kind: FieldKind.Json } && ObjectId.TryParse(text.Trim(), out var id))
        {
            return new BsonDocument("$or", new BsonArray
            {
                new BsonDocument(field, new BsonObjectId(id)),
                new BsonDocument(field, text),
            });
        }

        return new BsonDocument(field, Typed(text, column));
    }

    private static BsonDocument Compare(string field, string op, string text, FieldColumn? column) =>
        new(field, new BsonDocument(op, Typed(text, column)));

    private static BsonDocument Pattern(string field, string pattern) =>
        new(field, new BsonDocument { { "$regex", pattern }, { "$options", "i" } });

    private static BsonArray List(string csv, FieldColumn? column)
    {
        var items = new BsonArray();
        foreach (var item in csv.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
        {
            items.Add(Typed(item, column));
        }

        return items;
    }

    private static BsonDocument? Search(string? text, IReadOnlyList<string> columns)
    {
        if (string.IsNullOrEmpty(text) || columns.Count == 0)
        {
            return null;
        }

        var pattern = EscapeRegex(text);
        var any = new BsonArray();
        foreach (var column in columns)
        {
            if (!column.StartsWith('$'))
            {
                any.Add(Pattern(column, pattern));
            }
        }

        return any.Count == 0 ? null : new BsonDocument("$or", any);
    }
}
