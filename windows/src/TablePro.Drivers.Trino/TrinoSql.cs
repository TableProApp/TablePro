using System.Globalization;
using System.Text;
using TablePro.Core.Browse;
using TablePro.Core.Editing;
using TablePro.Core.Localization;
using TablePro.Drivers.Trino.Localization;

namespace TablePro.Drivers.Trino;

/// <summary>A catalog and schema, which the sidebar shows as one <c>catalog.schema</c> name when no catalog is chosen.</summary>
internal readonly record struct TrinoSchema(string? Catalog, string Schema)
{
    /// <summary>Splits at the first dot: catalog names are plain identifiers, while a schema name may hold dots.</summary>
    public static TrinoSchema Parse(string? schema, string? defaultCatalog, string? defaultSchema)
    {
        if (string.IsNullOrEmpty(schema))
        {
            return new TrinoSchema(defaultCatalog, defaultSchema ?? string.Empty);
        }

        if (defaultCatalog is null)
        {
            var dot = schema.IndexOf('.', StringComparison.Ordinal);
            if (dot > 0)
            {
                return new TrinoSchema(schema[..dot], schema[(dot + 1)..]);
            }
        }

        return new TrinoSchema(defaultCatalog, schema);
    }
}

/// <summary>The statements the Trino session runs. Values are written as typed literals; see <see cref="TrinoTypes.Literal"/>.</summary>
internal static class TrinoSql
{
    public const string Version = "SELECT version()";

    public const string ShowCatalogs = "SHOW CATALOGS";

    public const string Activity =
        "SELECT query_id, state, \"user\", source, created, query FROM system.runtime.queries "
        + "WHERE state NOT IN ('FINISHED', 'FAILED') ORDER BY created DESC";

    public static string ShowSchemas(string catalog) => "SHOW SCHEMAS FROM " + TrinoTypes.QuoteIdentifier(catalog);

    public static string Qualify(TrinoSchema schema, string name)
    {
        var sb = new StringBuilder();
        if (!string.IsNullOrEmpty(schema.Catalog))
        {
            sb.Append(TrinoTypes.QuoteIdentifier(schema.Catalog)).Append('.');
        }

        if (!string.IsNullOrEmpty(schema.Schema))
        {
            sb.Append(TrinoTypes.QuoteIdentifier(schema.Schema)).Append('.');
        }

        return sb.Append(TrinoTypes.QuoteIdentifier(name)).ToString();
    }

    public static string Tables(TrinoSchema schema) =>
        $"SELECT table_name, table_type FROM {InformationSchema(schema)}.tables WHERE table_schema = {TrinoTypes.QuoteLiteral(schema.Schema)} ORDER BY table_name";

    public static string MaterializedViews(TrinoSchema schema) =>
        "SELECT name FROM system.metadata.materialized_views WHERE catalog_name = "
        + TrinoTypes.QuoteLiteral(schema.Catalog ?? string.Empty) + " AND schema_name = " + TrinoTypes.QuoteLiteral(schema.Schema);

    public static string Columns(TrinoSchema schema, string table) =>
        $"SELECT column_name, data_type, is_nullable, column_default, comment FROM {InformationSchema(schema)}.columns "
        + $"WHERE table_schema = {TrinoTypes.QuoteLiteral(schema.Schema)} AND table_name = {TrinoTypes.QuoteLiteral(table)} ORDER BY ordinal_position";

    public static string ShowCreate(string kind, TrinoSchema schema, string name) => $"SHOW CREATE {kind} {Qualify(schema, name)}";

    public static string KillQuery(string queryId) =>
        $"CALL system.runtime.kill_query(query_id => {TrinoTypes.QuoteLiteral(queryId)}, message => 'Killed from TablePro')";

    private static string InformationSchema(TrinoSchema schema) =>
        string.IsNullOrEmpty(schema.Catalog) ? "information_schema" : TrinoTypes.QuoteIdentifier(schema.Catalog) + ".information_schema";

    /// <summary>One page of a table tab: filters, sort, then OFFSET and FETCH, the order Trino requires.</summary>
    public static string Browse(string qualifiedTable, BrowseRequest request, IReadOnlyDictionary<string, string> columnTypes)
    {
        var sql = new StringBuilder("SELECT * FROM ").Append(qualifiedTable);
        AppendWhere(sql, request.Filter, columnTypes);
        if (request.Sort.Count > 0)
        {
            sql.Append(" ORDER BY ").AppendJoin(", ", request.Sort.Select(s => TrinoTypes.QuoteIdentifier(s.Column) + (s.Descending ? " DESC" : " ASC")));
        }

        sql.Append(CultureInfo.InvariantCulture, $" OFFSET {request.Offset} ROWS FETCH NEXT {request.Limit} ROWS ONLY");
        return sql.ToString();
    }

    public static string Count(string qualifiedTable, BrowseFilter filter, IReadOnlyDictionary<string, string> columnTypes)
    {
        var sql = new StringBuilder("SELECT count(*) FROM ").Append(qualifiedTable);
        AppendWhere(sql, filter, columnTypes);
        return sql.ToString();
    }

    private static void AppendWhere(StringBuilder sql, BrowseFilter filter, IReadOnlyDictionary<string, string> columnTypes)
    {
        var clauses = new List<string>();
        foreach (var rule in filter.Rules)
        {
            if (rule.Enabled)
            {
                clauses.Add(Render(rule, filter.SearchColumns, columnTypes));
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

    internal static string Render(FilterRule rule, IReadOnlyList<string> searchColumns, IReadOnlyDictionary<string, string> columnTypes)
    {
        if (rule.Column is null)
        {
            var text = rule.Value ?? string.Empty;
            if (text.Length == 0 || searchColumns.Count == 0)
            {
                return "1=1";
            }

            var pattern = TrinoTypes.QuoteLiteral("%" + EscapeLike(text.ToLowerInvariant()) + "%");
            return "(" + string.Join(" OR ", searchColumns.Select(c => $"lower({Text(c, TypeOf(columnTypes, c))}) LIKE {pattern} ESCAPE '!'")) + ")";
        }

        var column = TrinoTypes.QuoteIdentifier(rule.Column);
        var type = TypeOf(columnTypes, rule.Column);
        var value = rule.Value ?? string.Empty;
        var asText = Text(rule.Column, type);
        string Lit(string v) => TrinoTypes.TextLiteral(v, type ?? "varchar");
        string Like(string pattern) => TrinoTypes.QuoteLiteral(pattern.ToLowerInvariant());
        return rule.Operator switch
        {
            FilterOperator.Equals => $"{column} = {Lit(value)}",
            FilterOperator.NotEquals => $"{column} <> {Lit(value)}",
            FilterOperator.GreaterThan => $"{column} > {Lit(value)}",
            FilterOperator.GreaterOrEqual => $"{column} >= {Lit(value)}",
            FilterOperator.LessThan => $"{column} < {Lit(value)}",
            FilterOperator.LessOrEqual => $"{column} <= {Lit(value)}",
            FilterOperator.Contains => $"lower({asText}) LIKE {Like("%" + EscapeLike(value) + "%")} ESCAPE '!'",
            FilterOperator.NotContains => $"lower({asText}) NOT LIKE {Like("%" + EscapeLike(value) + "%")} ESCAPE '!'",
            FilterOperator.StartsWith => $"lower({asText}) LIKE {Like(EscapeLike(value) + "%")} ESCAPE '!'",
            FilterOperator.EndsWith => $"lower({asText}) LIKE {Like("%" + EscapeLike(value))} ESCAPE '!'",
            FilterOperator.IsNull => $"{column} IS NULL",
            FilterOperator.IsNotNull => $"{column} IS NOT NULL",
            FilterOperator.IsEmpty => $"({column} IS NULL OR {asText} = '')",
            FilterOperator.IsNotEmpty => $"({column} IS NOT NULL AND {asText} <> '')",
            FilterOperator.In => $"{column} IN ({List(value, type)})",
            FilterOperator.NotIn => $"{column} NOT IN ({List(value, type)})",
            FilterOperator.Between => $"{column} BETWEEN {Lit(value)} AND {Lit(rule.SecondValue ?? string.Empty)}",
            _ => "1=1",
        };
    }

    private static string? TypeOf(IReadOnlyDictionary<string, string> columnTypes, string column) =>
        columnTypes.TryGetValue(column, out var type) ? type : null;

    // CAST to varchar fails on arrays, maps and rows; their JSON text is what the grid shows anyway.
    private static string Text(string column, string? type) =>
        type is not null && TrinoTypes.IsStructured(type)
            ? $"json_format(CAST({TrinoTypes.QuoteIdentifier(column)} AS json))"
            : $"CAST({TrinoTypes.QuoteIdentifier(column)} AS varchar)";

    private static string List(string csv, string? type)
    {
        var items = csv.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        return items.Length == 0 ? "NULL" : string.Join(", ", items.Select(i => TrinoTypes.TextLiteral(i, type ?? "varchar")));
    }

    private static string EscapeLike(string value)
    {
        var sb = new StringBuilder(value.Length + 4);
        foreach (var c in value)
        {
            if (c is '!' or '%' or '_')
            {
                sb.Append('!');
            }

            sb.Append(c);
        }

        return sb.ToString();
    }

    /// <summary>The write for one grid change, with each value a literal of its column's type.</summary>
    public static string Change(string qualifiedTable, RowChange change, IReadOnlyDictionary<string, string> columnTypes) => change switch
    {
        RowInsert insert when insert.Values.Count == 0 => throw new InvalidOperationException(CoreStrings.Format("Driver/InsertNeedsValue", "Trino")),
        RowInsert insert =>
            $"INSERT INTO {qualifiedTable} ({string.Join(", ", insert.Values.Keys.Select(TrinoTypes.QuoteIdentifier))}) "
            + $"VALUES ({string.Join(", ", insert.Values.Select(p => TrinoTypes.Literal(p.Value, TypeOf(columnTypes, p.Key))))})",
        RowUpdate update =>
            $"UPDATE {qualifiedTable} SET {string.Join(", ", update.Values.Select(p => $"{TrinoTypes.QuoteIdentifier(p.Key)} = {TrinoTypes.Literal(p.Value, TypeOf(columnTypes, p.Key))}"))}"
            + " WHERE " + Predicate(update.Key, columnTypes),
        RowDelete delete => $"DELETE FROM {qualifiedTable} WHERE {Predicate(delete.Key, columnTypes)}",
        _ => throw new ArgumentOutOfRangeException(nameof(change)),
    };

    /// <summary>How many rows (up to two) a keyed change would reach, checked before anything is written.</summary>
    public static string KeyedRowCount(string qualifiedTable, IReadOnlyDictionary<string, object?> key, IReadOnlyDictionary<string, string> columnTypes) =>
        $"SELECT count(*) FROM (SELECT 1 FROM {qualifiedTable} WHERE {Predicate(key, columnTypes)} LIMIT 2) AS t";

    // Arrays, maps and rows cannot be compared with =, so they are left out of the key.
    internal static string Predicate(IReadOnlyDictionary<string, object?> key, IReadOnlyDictionary<string, string> columnTypes)
    {
        var terms = new List<string>(key.Count);
        foreach (var (column, value) in key)
        {
            var type = TypeOf(columnTypes, column);
            if (type is not null && TrinoTypes.IsStructured(type))
            {
                continue;
            }

            var quoted = TrinoTypes.QuoteIdentifier(column);
            terms.Add(value is null ? $"{quoted} IS NULL" : $"{quoted} = {TrinoTypes.Literal(value, type)}");
        }

        return terms.Count > 0 ? string.Join(" AND ", terms) : throw new InvalidOperationException(TrinoStrings.Get("Trino/NeedsComparableKey"));
    }
}
