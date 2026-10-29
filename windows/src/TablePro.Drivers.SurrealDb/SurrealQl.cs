using System.Globalization;
using System.Text;
using System.Text.Json;
using TablePro.Core.Browse;
using TablePro.Drivers.Http;

namespace TablePro.Drivers.SurrealDb;

/// <summary>The declared type of a field, read from <c>DEFINE FIELD ... TYPE option&lt;record&lt;user&gt;&gt;</c>.</summary>
internal sealed record SurrealKind(string Base, bool IsOptional, string? RecordTable, string Raw)
{
    public static readonly SurrealKind Any = new("any", true, null, string.Empty);

    public Type ClrType => Base switch
    {
        "int" => typeof(long),
        "float" or "number" => typeof(double),
        "decimal" => typeof(decimal),
        "datetime" => typeof(DateTimeOffset),
        "bool" => typeof(bool),
        _ => typeof(string),
    };

    public static SurrealKind Parse(string raw)
    {
        var body = raw.Trim();
        if (body.Length == 0)
        {
            return Any;
        }

        var optional = false;
        if (Unwrap(body, "option") is { } inner)
        {
            body = inner;
            optional = true;
        }

        var alternatives = SplitUnion(body);
        var concrete = alternatives.Where(a => !a.Equals("none", StringComparison.OrdinalIgnoreCase) && !a.Equals("null", StringComparison.OrdinalIgnoreCase)).ToArray();
        optional |= concrete.Length != alternatives.Count;
        body = concrete.FirstOrDefault() ?? "any";
        var angle = body.IndexOf('<', StringComparison.Ordinal);
        var head = (angle < 0 ? body : body[..angle]).Trim().ToLowerInvariant();
        var table = Unwrap(body, "record")?.Split('|')[0].Trim();
        var known = head is "any" or "bool" or "bytes" or "datetime" or "decimal" or "duration" or "float" or "int" or "number" or "object" or "record" or "string" or "uuid" or "array" or "set";
        return new SurrealKind(known ? head : head.StartsWith("geometry", StringComparison.Ordinal) ? "geometry" : "any", optional, string.IsNullOrEmpty(table) ? null : table, raw);
    }

    private static string? Unwrap(string body, string prefix) =>
        body.StartsWith(prefix + "<", StringComparison.OrdinalIgnoreCase) && body.EndsWith('>') ? body[(prefix.Length + 1)..^1].Trim() : null;

    private static List<string> SplitUnion(string body)
    {
        var parts = new List<string>();
        var depth = 0;
        var start = 0;
        for (var i = 0; i < body.Length; i++)
        {
            switch (body[i])
            {
                case '<': depth++; break;
                case '>': depth--; break;
                case '|' when depth == 0:
                    parts.Add(body[start..i].Trim());
                    start = i + 1;
                    break;
            }
        }

        parts.Add(body[start..].Trim());
        return [.. parts.Where(p => p.Length > 0)];
    }
}

/// <summary>A record id split into its table and id, as <c>person:tobie</c>, <c>person:⟨a b⟩</c> or <c>person:42</c>.</summary>
internal readonly record struct SurrealRecordId(string Table, string IdText, bool IsInteger, bool IsComplex)
{
    /// <summary>
    /// Reads the text SurrealDB's JSON output gives a record id. Without a colon the text is an id in
    /// <paramref name="fallbackTable"/>, which is how a new row's id is typed.
    /// </summary>
    public static SurrealRecordId? Parse(string text, string? fallbackTable = null)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0)
        {
            return null;
        }

        var separator = Separator(trimmed);
        string table, raw;
        if (separator < 0)
        {
            if (fallbackTable is null)
            {
                return null;
            }

            (table, raw) = (fallbackTable, trimmed);
        }
        else
        {
            (table, raw) = (Unquote(trimmed[..separator]), trimmed[(separator + 1)..]);
        }

        if (table.Length == 0 || raw.Length == 0)
        {
            return null;
        }

        if (IsQuoted(raw))
        {
            return new SurrealRecordId(table, Unquote(raw), false, false);
        }

        if (long.TryParse(raw, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var number) && number.ToString(CultureInfo.InvariantCulture) == raw)
        {
            return new SurrealRecordId(table, raw, true, false);
        }

        // An array, object or uuid id has its own syntax, which only the server can read back.
        var complex = raw[0] is '[' or '{' || raw.StartsWith("u'", StringComparison.Ordinal) || raw.StartsWith("u\"", StringComparison.Ordinal);
        return new SurrealRecordId(table, raw, false, complex);
    }

    /// <summary>
    /// The SurrealQL expression for this record. The parts travel as JSON string literals inside
    /// <c>type::thing</c>, so nothing typed into the grid becomes query syntax.
    /// </summary>
    public string Expression(string original) => IsComplex
        ? "<record> " + SurrealQl.String(original.Contains(':', StringComparison.Ordinal) ? original.Trim() : $"{SurrealQl.Ident(Table)}:{IdText}")
        : $"type::thing({SurrealQl.String(Table)}, {(IsInteger ? IdText : SurrealQl.String(IdText))})";

    private static int Separator(string text)
    {
        var inBackticks = false;
        var inAngles = false;
        for (var i = 0; i < text.Length; i++)
        {
            switch (text[i])
            {
                case '`': inBackticks = !inBackticks; break;
                case '⟨': inAngles = true; break;
                case '⟩': inAngles = false; break;
                case ':' when !inBackticks && !inAngles: return i;
            }
        }

        return -1;
    }

    private static bool IsQuoted(string text) =>
        text.Length >= 2 && ((text[0] == '`' && text[^1] == '`') || (text[0] == '⟨' && text[^1] == '⟩'));

    private static string Unquote(string text)
    {
        if (text.Length >= 2 && text[0] == '`' && text[^1] == '`')
        {
            return text[1..^1].Replace("\\`", "`", StringComparison.Ordinal).Replace("\\\\", "\\", StringComparison.Ordinal);
        }

        if (text.Length >= 2 && text[0] == '⟨' && text[^1] == '⟩')
        {
            return text[1..^1].Replace("\\⟩", "⟩", StringComparison.Ordinal).Replace("\\\\", "\\", StringComparison.Ordinal);
        }

        return text;
    }
}

/// <summary>SurrealQL spelling: identifiers, string literals and the expressions grid values become.</summary>
internal static class SurrealQl
{
    /// <summary>
    /// A table or field name in backticks. SurrealQL escapes a backtick inside one with a backslash, where the Core
    /// dialect's generic quoting would double it.
    /// </summary>
    public static string Ident(string name) =>
        string.Concat("`", name.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("`", "\\`", StringComparison.Ordinal), "`");

    /// <summary>A double-quoted string literal, written by a JSON writer that escapes only quotes, backslashes and controls.</summary>
    public static string String(string value)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, JsonCells.Compact))
        {
            writer.WriteStringValue(value);
        }

        return Encoding.UTF8.GetString(stream.GetBuffer(), 0, (int)stream.Length);
    }

    /// <summary>
    /// The expression a grid value becomes for a field of <paramref name="kind"/>. A typed cell keeps its type; text is
    /// read as the declared type, or inferred when the field is schemaless.
    /// </summary>
    public static string Value(object? value, SurrealKind? kind, string? table = null)
    {
        switch (value)
        {
            case null or DBNull:
                // NONE removes a field, which is what an emptied optional or undeclared field means.
                return kind is { IsOptional: false } ? "NULL" : "NONE";
            case bool b:
                return b ? "true" : "false";
            case long or int or short or byte:
                return Convert.ToString(value, CultureInfo.InvariantCulture)!;
            case decimal m:
                return m.ToString(CultureInfo.InvariantCulture) + "dec";
            case double d:
                return Float(d);
            case float f:
                return Float(f);
            case DateTime dt:
                return "<datetime> " + String(dt.ToString("O", CultureInfo.InvariantCulture));
            case DateTimeOffset dto:
                return "<datetime> " + String(dto.ToString("O", CultureInfo.InvariantCulture));
            case Guid g:
                return "<uuid> " + String(g.ToString());
            case string text:
                return Text(text, kind, table);
            default:
                return String(Convert.ToString(value, CultureInfo.InvariantCulture) ?? string.Empty);
        }
    }

    private static string Text(string text, SurrealKind? kind, string? table)
    {
        var trimmed = text.Trim();
        if (kind is null || kind.Base == "any")
        {
            return Inferred(text);
        }

        if (trimmed.Length == 0 && kind.Base != "string")
        {
            return kind.IsOptional ? "NONE" : "NULL";
        }

        return kind.Base switch
        {
            "int" when long.TryParse(trimmed, NumberStyles.Integer, CultureInfo.InvariantCulture, out var i) => i.ToString(CultureInfo.InvariantCulture),
            "float" or "number" when double.TryParse(trimmed, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) => Float(d),
            "decimal" when decimal.TryParse(trimmed, NumberStyles.Float, CultureInfo.InvariantCulture, out var m) => m.ToString(CultureInfo.InvariantCulture) + "dec",
            "bool" when trimmed.ToLowerInvariant() is "true" or "1" or "yes" => "true",
            "bool" when trimmed.ToLowerInvariant() is "false" or "0" or "no" => "false",
            "datetime" => "<datetime> " + String(trimmed),
            "duration" => "<duration> " + String(trimmed),
            "uuid" => "<uuid> " + String(trimmed),
            "record" when SurrealRecordId.Parse(trimmed, kind.RecordTable ?? table) is { } record => record.Expression(trimmed),
            "object" or "array" or "set" or "geometry" when JsonCells.TryParseStructure(trimmed) is { } structure => JsonCells.ToJson(structure),
            _ => String(text),
        };
    }

    /// <summary>A schemaless field takes what the text looks like: JSON, an integer, a boolean, or else a string.</summary>
    private static string Inferred(string text)
    {
        var trimmed = text.Trim();
        if (JsonCells.TryParseStructure(trimmed) is { } structure)
        {
            return JsonCells.ToJson(structure);
        }

        if (long.TryParse(trimmed, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var integer) && integer.ToString(CultureInfo.InvariantCulture) == trimmed)
        {
            return trimmed;
        }

        return trimmed.ToLowerInvariant() switch
        {
            "true" => "true",
            "false" => "false",
            _ => String(text),
        };
    }

    /// <summary>A float literal that reads back as a float, so 2.0 does not become the integer 2.</summary>
    private static string Float(double value)
    {
        var text = value.ToString("R", CultureInfo.InvariantCulture);
        return text.Contains('.', StringComparison.Ordinal) || text.Contains('E', StringComparison.Ordinal) || text.Contains("Infinity", StringComparison.Ordinal) || text == "NaN"
            ? text
            : text + "f";
    }
}

/// <summary>
/// Values bound as SurrealQL variables. Each value is set by a <c>LET $pN = ...;</c> sent ahead of the statement in the
/// same request, and the statement names only the variable.
/// </summary>
internal sealed class SurrealParams
{
    private readonly StringBuilder _lets = new();

    public int Count { get; private set; }

    public string Prefix => _lets.ToString();

    public string Add(string expression)
    {
        var name = string.Create(CultureInfo.InvariantCulture, $"$p{Count++}");
        _lets.Append("LET ").Append(name).Append(" = ").Append(expression).Append(";\n");
        return name;
    }
}

/// <summary>Turns the filter strip into a WHERE clause over bound variables.</summary>
internal static class SurrealFilter
{
    public static string? Where(BrowseFilter filter, string table, IReadOnlyDictionary<string, SurrealKind> kinds, SurrealParams parameters)
    {
        var clauses = new List<string>();
        foreach (var rule in filter.Rules)
        {
            if (rule.Enabled && Condition(rule, table, kinds, filter.SearchColumns, parameters) is { } condition)
            {
                clauses.Add(condition);
            }
        }

        // The raw filter is the user's own SurrealQL condition, like a raw WHERE on a SQL engine.
        if (!string.IsNullOrWhiteSpace(filter.RawWhere))
        {
            clauses.Add($"({filter.RawWhere.Trim()})");
        }

        return clauses.Count == 0 ? null : string.Join(filter.MatchAll ? " AND " : " OR ", clauses);
    }

    public static string? Condition(FilterRule rule, string table, IReadOnlyDictionary<string, SurrealKind> kinds, IReadOnlyList<string> searchColumns, SurrealParams parameters)
    {
        var value = rule.Value ?? string.Empty;
        if (rule.Column is null)
        {
            if (value.Length == 0)
            {
                return null;
            }

            var columns = searchColumns.Count > 0 ? searchColumns : [.. kinds.Keys];
            if (columns.Count == 0)
            {
                return null;
            }

            var needle = parameters.Add(SurrealQl.String(value.ToLowerInvariant()));
            return "(" + string.Join(" OR ", columns.Select(c => $"string::contains(string::lowercase(<string> {SurrealQl.Ident(c)}), {needle})")) + ")";
        }

        var column = SurrealQl.Ident(rule.Column);
        var kind = rule.Column == "id"
            ? new SurrealKind("record", false, table, "record")
            : kinds.TryGetValue(rule.Column, out var declared) ? declared : null;
        string Bind(string v) => parameters.Add(SurrealQl.Value(v, kind, table));
        string Lower(string v) => parameters.Add(SurrealQl.String(v.ToLowerInvariant()));
        string Text() => $"string::lowercase(<string> {column})";

        return rule.Operator switch
        {
            FilterOperator.Equals => $"{column} = {Bind(value)}",
            FilterOperator.NotEquals => $"{column} != {Bind(value)}",
            FilterOperator.GreaterThan => $"{column} > {Bind(value)}",
            FilterOperator.GreaterOrEqual => $"{column} >= {Bind(value)}",
            FilterOperator.LessThan => $"{column} < {Bind(value)}",
            FilterOperator.LessOrEqual => $"{column} <= {Bind(value)}",
            FilterOperator.Contains => $"string::contains({Text()}, {Lower(value)})",
            FilterOperator.NotContains => $"!string::contains({Text()}, {Lower(value)})",
            FilterOperator.StartsWith => $"string::starts_with({Text()}, {Lower(value)})",
            FilterOperator.EndsWith => $"string::ends_with({Text()}, {Lower(value)})",

            // A missing field is NONE and an explicit one NULL; the grid shows both as NULL.
            FilterOperator.IsNull => $"({column} = NONE OR {column} = NULL)",
            FilterOperator.IsNotNull => $"({column} != NONE AND {column} != NULL)",
            FilterOperator.IsEmpty => $"({column} = NONE OR {column} = NULL OR {column} = '')",
            FilterOperator.IsNotEmpty => $"({column} != NONE AND {column} != NULL AND {column} != '')",
            FilterOperator.In => $"{column} INSIDE {List(value, kind, table, parameters)}",
            FilterOperator.NotIn => $"{column} NOTINSIDE {List(value, kind, table, parameters)}",
            FilterOperator.Between => Between(rule, column, Bind),
            _ => throw new NotSupportedException($"SurrealDB cannot filter rows with {rule.Operator.DisplayName()}."),
        };
    }

    private static string List(string csv, SurrealKind? kind, string table, SurrealParams parameters)
    {
        var items = csv.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        return parameters.Add("[" + string.Join(", ", items.Select(i => SurrealQl.Value(i, kind, table))) + "]");
    }

    private static string Between(FilterRule rule, string column, Func<string, string> bind)
    {
        var value = rule.Value ?? string.Empty;
        string low, high;
        if (rule.SecondValue is { Length: > 0 } second)
        {
            (low, high) = (value, second);
        }
        else
        {
            var comma = value.IndexOf(',', StringComparison.Ordinal);
            if (comma < 0)
            {
                throw new ArgumentException("Enter both bounds to filter with BETWEEN.");
            }

            (low, high) = (value[..comma], value[(comma + 1)..]);
        }

        return $"({column} >= {bind(low.Trim())} AND {column} <= {bind(high.Trim())})";
    }
}
