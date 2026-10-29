using System.Globalization;
using System.Text;
using Google.Cloud.BigQuery.V2;
using TablePro.Core.Browse;
using TablePro.Core.Editing;
using TablePro.Core.Localization;
using TablePro.Drivers.BigQuery.Localization;

namespace TablePro.Drivers.BigQuery;

/// <summary>A statement and its named, typed parameters.</summary>
public sealed record BigQueryStatement(string Sql, IReadOnlyList<BigQueryParameter> Parameters);

/// <summary>
/// GoogleSQL for browsing and saving. Values are always named query parameters typed by their column. LIKE has no
/// ESCAPE clause in GoogleSQL; a backslash escapes <c>%</c> and <c>_</c> instead.
/// </summary>
public static class BigQuerySql
{
    /// <summary>The marker a failed row check raises, read back into a <see cref="RowCountMismatchException"/>.</summary>
    internal const string RowCountMarker = "TABLEPRO_ROWCOUNT";

    /// <summary>GoogleSQL escapes a backtick inside a quoted name with a backslash, not by doubling it.</summary>
    public static string Quote(string identifier) =>
        string.Concat("`", identifier.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("`", "\\`", StringComparison.Ordinal), "`");

    public static string Table(string project, string dataset, string table) => string.Concat(Quote(project), ".", Quote(dataset), ".", Quote(table));

    public static string Ddl(string project, string dataset) =>
        $"SELECT ddl FROM {Quote(project)}.{Quote(dataset)}.INFORMATION_SCHEMA.TABLES WHERE table_name = @name";

    public static BigQueryStatement Browse(string qualifiedTable, BrowseRequest request, IReadOnlyDictionary<string, BigQueryField> fields)
    {
        ArgumentNullException.ThrowIfNull(request);
        var parameters = new List<BigQueryParameter>();
        var sql = new StringBuilder("SELECT * FROM ").Append(qualifiedTable);
        AppendWhere(sql, request.Filter, fields, parameters);
        if (request.Sort.Count > 0)
        {
            sql.Append(" ORDER BY ").AppendJoin(", ", request.Sort.Select(s => Quote(s.Column) + (s.Descending ? " DESC" : " ASC")));
        }

        sql.Append(" LIMIT @__limit OFFSET @__offset");
        parameters.Add(new BigQueryParameter("__limit", BigQueryDbType.Int64, (long)request.Limit));
        parameters.Add(new BigQueryParameter("__offset", BigQueryDbType.Int64, (long)request.Offset));
        return new BigQueryStatement(sql.ToString(), parameters);
    }

    public static BigQueryStatement Count(string qualifiedTable, BrowseFilter filter, IReadOnlyDictionary<string, BigQueryField> fields)
    {
        var parameters = new List<BigQueryParameter>();
        var sql = new StringBuilder("SELECT COUNT(*) FROM ").Append(qualifiedTable);
        AppendWhere(sql, filter, fields, parameters);
        return new BigQueryStatement(sql.ToString(), parameters);
    }

    private static void AppendWhere(StringBuilder sql, BrowseFilter filter, IReadOnlyDictionary<string, BigQueryField> fields, List<BigQueryParameter> parameters)
    {
        ArgumentNullException.ThrowIfNull(filter);
        var clauses = new List<string>();
        foreach (var rule in filter.Rules)
        {
            if (rule.Enabled)
            {
                clauses.Add(Render(rule, filter.SearchColumns, fields, parameters));
            }
        }

        if (!string.IsNullOrWhiteSpace(filter.RawWhere))
        {
            clauses.Add($"({filter.RawWhere})");
        }

        if (clauses.Count > 0)
        {
            sql.Append(" WHERE ").AppendJoin(filter.MatchAll ? " AND " : " OR ", clauses);
        }
    }

    internal static string Render(FilterRule rule, IReadOnlyList<string> searchColumns, IReadOnlyDictionary<string, BigQueryField> fields, List<BigQueryParameter> parameters)
    {
        string Bind(string? type, object? value)
        {
            var name = string.Create(CultureInfo.InvariantCulture, $"p{parameters.Count}");
            parameters.Add(BigQuerySchema.Parameter(name, type, value));
            return "@" + name;
        }

        if (rule.Column is null)
        {
            // A nested field is listed in the structure but is not a column of SELECT *.
            var columns = searchColumns.Where(c => !c.Contains('.', StringComparison.Ordinal)).ToArray();
            var text = rule.Value ?? string.Empty;
            if (text.Length == 0 || columns.Length == 0)
            {
                return "TRUE";
            }

            var pattern = Bind("STRING", "%" + EscapeLike(text) + "%");
            return "(" + string.Join(" OR ", columns.Select(c => $"LOWER({Text(c, Field(fields, c))}) LIKE LOWER({pattern})")) + ")";
        }

        var field = Field(fields, rule.Column);
        var type = field?.IsComplex == true ? "STRING" : field?.Type;
        var column = Quote(rule.Column);
        var asText = Text(rule.Column, field);
        var value = rule.Value ?? string.Empty;
        return rule.Operator switch
        {
            FilterOperator.Equals => $"{column} = {Bind(type, value)}",
            FilterOperator.NotEquals => $"{column} <> {Bind(type, value)}",
            FilterOperator.GreaterThan => $"{column} > {Bind(type, value)}",
            FilterOperator.GreaterOrEqual => $"{column} >= {Bind(type, value)}",
            FilterOperator.LessThan => $"{column} < {Bind(type, value)}",
            FilterOperator.LessOrEqual => $"{column} <= {Bind(type, value)}",
            FilterOperator.Contains => $"LOWER({asText}) LIKE LOWER({Bind("STRING", "%" + EscapeLike(value) + "%")})",
            FilterOperator.NotContains => $"LOWER({asText}) NOT LIKE LOWER({Bind("STRING", "%" + EscapeLike(value) + "%")})",
            FilterOperator.StartsWith => $"LOWER({asText}) LIKE LOWER({Bind("STRING", EscapeLike(value) + "%")})",
            FilterOperator.EndsWith => $"LOWER({asText}) LIKE LOWER({Bind("STRING", "%" + EscapeLike(value))})",
            FilterOperator.IsNull => $"{column} IS NULL",
            FilterOperator.IsNotNull => $"{column} IS NOT NULL",
            FilterOperator.IsEmpty => $"({column} IS NULL OR {asText} = '')",
            FilterOperator.IsNotEmpty => $"({column} IS NOT NULL AND {asText} <> '')",
            FilterOperator.In => $"{column} IN ({List(value, v => Bind(type, v))})",
            FilterOperator.NotIn => $"{column} NOT IN ({List(value, v => Bind(type, v))})",
            FilterOperator.Between => $"{column} BETWEEN {Bind(type, value)} AND {Bind(type, rule.SecondValue ?? string.Empty)}",
            _ => "TRUE",
        };
    }

    private static BigQueryField? Field(IReadOnlyDictionary<string, BigQueryField> fields, string column) =>
        fields.TryGetValue(column, out var field) ? field : null;

    // CAST(... AS STRING) refuses records, arrays and JSON; TO_JSON_STRING reads them as the grid shows them.
    private static string Text(string column, BigQueryField? field) => field switch
    {
        { IsComplex: true } or { Type: "JSON" } => $"TO_JSON_STRING({Quote(column)})",
        { Type: "STRING" } => Quote(column),
        _ => $"CAST({Quote(column)} AS STRING)",
    };

    private static string List(string csv, Func<string, string> bind)
    {
        var items = csv.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        return items.Length == 0 ? "NULL" : string.Join(", ", items.Select(bind));
    }

    internal static string EscapeLike(string value)
    {
        var sb = new StringBuilder(value.Length + 4);
        foreach (var c in value)
        {
            if (c is '\\' or '%' or '_')
            {
                sb.Append('\\');
            }

            sb.Append(c);
        }

        return sb.ToString();
    }

    /// <summary>
    /// All of a save as one script in one transaction. After each keyed change the script checks <c>@@row_count</c>
    /// and raises when it is not exactly one, which rolls every change back. BigQuery has no primary keys, so a row is
    /// keyed by the columns the caller passes, less those <c>=</c> cannot compare.
    /// </summary>
    public static BigQueryStatement Save(string qualifiedTable, IReadOnlyList<RowChange> changes, IReadOnlyDictionary<string, BigQueryField> fields)
    {
        ArgumentNullException.ThrowIfNull(changes);
        var parameters = new List<BigQueryParameter>();
        string Bind(string column, object? value)
        {
            var name = string.Create(CultureInfo.InvariantCulture, $"p{parameters.Count}");
            parameters.Add(BigQuerySchema.Parameter(name, Field(fields, column) is { IsComplex: false } f ? f.Type : "STRING", value));
            return "@" + name;
        }

        var sql = new StringBuilder("BEGIN\n  BEGIN TRANSACTION;\n");
        for (var i = 0; i < changes.Count; i++)
        {
            sql.Append("  ");
            switch (changes[i])
            {
                case RowInsert insert when insert.Values.Count == 0:
                    throw new InvalidOperationException(CoreStrings.Format("Driver/InsertNeedsValue", "BigQuery"));
                case RowInsert insert:
                    sql.Append("INSERT INTO ").Append(qualifiedTable).Append(" (")
                        .AppendJoin(", ", insert.Values.Keys.Select(Quote)).Append(") VALUES (")
                        .AppendJoin(", ", insert.Values.Select(p => Bind(p.Key, p.Value))).Append(");\n");
                    continue;
                case RowUpdate update:
                    sql.Append("UPDATE ").Append(qualifiedTable).Append(" SET ")
                        .AppendJoin(", ", update.Values.Select(p => $"{Quote(p.Key)} = {Bind(p.Key, p.Value)}"))
                        .Append(" WHERE ").Append(Predicate(update.Key, fields, Bind)).Append(";\n");
                    break;
                case RowDelete delete:
                    sql.Append("DELETE FROM ").Append(qualifiedTable).Append(" WHERE ").Append(Predicate(delete.Key, fields, Bind)).Append(";\n");
                    break;
                default:
                    throw new ArgumentOutOfRangeException(nameof(changes));
            }

            sql.Append(CultureInfo.InvariantCulture, $"  IF @@row_count <> 1 THEN RAISE USING MESSAGE = FORMAT('{RowCountMarker} %d %d', {i}, @@row_count); END IF;\n");
        }

        sql.Append("  COMMIT TRANSACTION;\nEXCEPTION WHEN ERROR THEN\n  ROLLBACK TRANSACTION;\n  RAISE USING MESSAGE = @@error.message;\nEND;");
        return new BigQueryStatement(sql.ToString(), parameters);
    }

    private static string Predicate(IReadOnlyDictionary<string, object?> key, IReadOnlyDictionary<string, BigQueryField> fields, Func<string, object?, string> bind)
    {
        var terms = new List<string>(key.Count);
        foreach (var (column, value) in key)
        {
            // A column missing from the schema map is kept: the server is the judge of a name it knows better.
            if (Field(fields, column) is { IsComparable: false })
            {
                continue;
            }

            terms.Add(value is null ? $"{Quote(column)} IS NULL" : $"{Quote(column)} = {bind(column, value)}");
        }

        return terms.Count > 0
            ? string.Join(" AND ", terms)
            : throw new InvalidOperationException(BigQueryStrings.Get("BigQuery/NoComparableColumn"));
    }

    /// <summary>Reads the change index and row count from a failed row check, or null for any other error.</summary>
    internal static (int Change, int Rows)? ParseRowCountFailure(string message)
    {
        var at = message.IndexOf(RowCountMarker, StringComparison.Ordinal);
        if (at < 0)
        {
            return null;
        }

        var parts = message[(at + RowCountMarker.Length)..].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return parts.Length >= 2
            && int.TryParse(parts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var change)
            && int.TryParse(new string([.. parts[1].TakeWhile(char.IsAsciiDigit)]), NumberStyles.Integer, CultureInfo.InvariantCulture, out var rows)
            ? (change, rows)
            : null;
    }
}
