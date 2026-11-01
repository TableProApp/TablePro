using System.Globalization;
using System.Text;
using Google.Cloud.Spanner.Data;
using Google.Cloud.Spanner.V1;
using TablePro.Core.Browse;
using TablePro.Core.Localization;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.Spanner;

/// <summary>How the editor channel runs a statement.</summary>
public enum SpannerStatementKind
{
    Query,
    Dml,

    /// <summary>Schema changes go to the admin API's UpdateDatabaseDdl, a long-running operation, not to ExecuteSql.</summary>
    Ddl,
    Begin,
    Commit,
    Rollback,
}

/// <summary>A statement and its typed parameters.</summary>
public sealed record SpannerStatement(string Sql, IReadOnlyList<SpannerParameter> Parameters);

/// <summary>GoogleSQL for Spanner: catalog reads, browse pages and schema DDL.</summary>
public static class SpannerSql
{
    public const string Dialect =
        "SELECT option_value FROM information_schema.database_options WHERE option_name = 'database_dialect'";

    public const string Schemas = "SELECT schema_name FROM information_schema.schemata ORDER BY schema_name";

    public const string Tables =
        "SELECT table_name, table_type FROM information_schema.tables WHERE table_schema = @schema AND table_type IN ('BASE TABLE', 'VIEW') ORDER BY table_name";

    public const string Columns =
        "SELECT c.column_name, c.spanner_type, c.is_nullable, c.column_default, c.is_generated, c.generation_expression, c.is_identity, k.ordinal_position "
        + "FROM information_schema.columns AS c LEFT JOIN information_schema.index_columns AS k "
        + "ON k.table_schema = c.table_schema AND k.table_name = c.table_name AND k.column_name = c.column_name AND k.index_type = 'PRIMARY_KEY' "
        + "WHERE c.table_schema = @schema AND c.table_name = @table ORDER BY c.ordinal_position";

    public const string Indexes =
        "SELECT i.index_name, i.index_type, i.is_unique, ic.column_name FROM information_schema.indexes AS i "
        + "JOIN information_schema.index_columns AS ic ON ic.table_schema = i.table_schema AND ic.table_name = i.table_name AND ic.index_name = i.index_name "
        + "WHERE i.table_schema = @schema AND i.table_name = @table AND ic.ordinal_position IS NOT NULL ORDER BY i.index_name, ic.ordinal_position";

    public const string ForeignKeys =
        "SELECT c.constraint_name, c.column_name, p.table_schema, p.table_name, p.column_name, r.update_rule, r.delete_rule "
        + "FROM information_schema.key_column_usage AS c "
        + "JOIN information_schema.referential_constraints AS r ON r.constraint_schema = c.constraint_schema AND r.constraint_name = c.constraint_name "
        + "JOIN information_schema.key_column_usage AS p ON p.constraint_schema = r.unique_constraint_schema AND p.constraint_name = r.unique_constraint_name "
        + "AND p.ordinal_position = c.position_in_unique_constraint "
        + "WHERE c.table_schema = @schema AND c.table_name = @table ORDER BY c.constraint_name, c.ordinal_position";

    public const string InterleaveParent =
        "SELECT t.parent_table_name, t.on_delete_action, k.column_name FROM information_schema.tables AS t "
        + "JOIN information_schema.index_columns AS k ON k.table_schema = t.table_schema AND k.table_name = t.parent_table_name AND k.index_type = 'PRIMARY_KEY' "
        + "WHERE t.table_schema = @schema AND t.table_name = @table AND t.parent_table_name IS NOT NULL ORDER BY k.ordinal_position";

    public const string ViewDefinition =
        "SELECT view_definition FROM information_schema.views WHERE table_schema = @schema AND table_name = @table";

    private static readonly SpannerDialect Quoting = SpannerDialect.Instance;

    /// <summary>
    /// Reads the first keyword past comments. Spanner's ADO.NET provider runs DDL only through a DDL command, which
    /// calls UpdateDatabaseDdl and waits for the operation, so the channel must know a schema change when it sees one.
    /// </summary>
    public static SpannerStatementKind Classify(string sql)
    {
        ArgumentNullException.ThrowIfNull(sql);
        var words = CommandWords.Read(StripLeadingComments(sql), 2);
        if (words.Count == 0)
        {
            return SpannerStatementKind.Query;
        }

        return words[0].TrimEnd(';').ToUpperInvariant() switch
        {
            "INSERT" or "UPDATE" or "DELETE" => SpannerStatementKind.Dml,
            "CREATE" or "ALTER" or "DROP" or "RENAME" or "GRANT" or "REVOKE" or "ANALYZE" => SpannerStatementKind.Ddl,
            "BEGIN" => SpannerStatementKind.Begin,
            "START" when words.Count > 1 && words[1].TrimEnd(';').Equals("TRANSACTION", StringComparison.OrdinalIgnoreCase) => SpannerStatementKind.Begin,
            "COMMIT" => SpannerStatementKind.Commit,
            "ROLLBACK" => SpannerStatementKind.Rollback,
            _ => SpannerStatementKind.Query,
        };
    }

    private static string StripLeadingComments(string sql)
    {
        var span = sql.AsSpan();
        while (true)
        {
            span = span.TrimStart();
            if (span.StartsWith("--") || span.StartsWith("#"))
            {
                var end = span.IndexOf('\n');
                span = end < 0 ? [] : span[(end + 1)..];
            }
            else if (span.StartsWith("/*"))
            {
                var end = span.IndexOf("*/");
                span = end < 0 ? [] : span[(end + 2)..];
            }
            else if (span.StartsWith("@{"))
            {
                // A statement hint such as @{USE_ADDITIONAL_PARALLELISM=TRUE} precedes the keyword.
                var end = span.IndexOf('}');
                span = end < 0 ? [] : span[(end + 1)..];
            }
            else
            {
                return span.ToString();
            }
        }
    }

    public static string Quote(string identifier) => Quoting.QuoteIdentifier(identifier);

    public static string Qualify(ObjectName name) => string.IsNullOrEmpty(name.Schema) ? Quote(name.Name) : $"{Quote(name.Schema)}.{Quote(name.Name)}";

    public static SpannerStatement Browse(ObjectName table, BrowseRequest request, IReadOnlyDictionary<string, string> columnTypes)
    {
        ArgumentNullException.ThrowIfNull(request);
        var parameters = new List<SpannerParameter>();
        var sql = new StringBuilder("SELECT * FROM ").Append(Qualify(table));
        AppendWhere(sql, request.Filter, columnTypes, parameters);
        if (request.Sort.Count > 0)
        {
            sql.Append(" ORDER BY ").AppendJoin(", ", request.Sort.Select(s => Quote(s.Column) + (s.Descending ? " DESC" : " ASC")));
        }

        sql.Append(CultureInfo.InvariantCulture, $" LIMIT {request.Limit} OFFSET {request.Offset}");
        return new SpannerStatement(sql.ToString(), parameters);
    }

    public static SpannerStatement Count(ObjectName table, BrowseFilter filter, IReadOnlyDictionary<string, string> columnTypes)
    {
        var parameters = new List<SpannerParameter>();
        var sql = new StringBuilder("SELECT COUNT(*) FROM ").Append(Qualify(table));
        AppendWhere(sql, filter, columnTypes, parameters);
        return new SpannerStatement(sql.ToString(), parameters);
    }

    private static void AppendWhere(StringBuilder sql, BrowseFilter filter, IReadOnlyDictionary<string, string> columnTypes, List<SpannerParameter> parameters)
    {
        ArgumentNullException.ThrowIfNull(filter);
        var clauses = new List<string>();
        foreach (var rule in filter.Rules)
        {
            if (rule.Enabled)
            {
                clauses.Add(Render(rule, filter.SearchColumns, columnTypes, parameters));
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

    internal static string Render(FilterRule rule, IReadOnlyList<string> searchColumns, IReadOnlyDictionary<string, string> columnTypes, List<SpannerParameter> parameters)
    {
        string Bind(string? type, object? value)
        {
            var name = string.Create(CultureInfo.InvariantCulture, $"p{parameters.Count}");
            parameters.Add(Parameter(name, type, value));
            return "@" + name;
        }

        string? TypeOf(string column) => columnTypes.TryGetValue(column, out var t) ? t : null;

        if (rule.Column is null)
        {
            var text = rule.Value ?? string.Empty;
            if (text.Length == 0 || searchColumns.Count == 0)
            {
                return "TRUE";
            }

            var pattern = Bind("STRING", "%" + EscapeLike(text) + "%");
            return "(" + string.Join(" OR ", searchColumns.Select(c => $"LOWER({Text(c, TypeOf(c))}) LIKE LOWER({pattern})")) + ")";
        }

        var type = TypeOf(rule.Column);
        var column = Quote(rule.Column);
        var asText = Text(rule.Column, type);
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

    // CAST(... AS STRING) refuses arrays and JSON; TO_JSON_STRING reads them as the grid shows them.
    private static string Text(string column, string? type)
    {
        var upper = type?.ToUpperInvariant() ?? "STRING";
        return upper.StartsWith("STRING", StringComparison.Ordinal)
            ? Quote(column)
            : upper.StartsWith("ARRAY", StringComparison.Ordinal) || upper == "JSON"
                ? $"TO_JSON_STRING({Quote(column)})"
                : $"CAST({Quote(column)} AS STRING)";
    }

    private static string List(string csv, Func<string, string> bind)
    {
        var items = csv.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        return items.Length == 0 ? "NULL" : string.Join(", ", items.Select(bind));
    }

    /// <summary>GoogleSQL LIKE has no ESCAPE clause; a backslash escapes the wildcards.</summary>
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
    /// A parameter typed by the column's Spanner type. Spanner compares strictly, so the text of a filter or a grid
    /// edit is converted here instead of being sent as STRING.
    /// </summary>
    public static SpannerParameter Parameter(string name, string? spannerType, object? value)
    {
        var upper = spannerType?.TrimStart().ToUpperInvariant() ?? "STRING";

        // Arrays and structs are compared through their JSON text in filters; a grid edit of one is not supported.
        var type = upper.StartsWith("ARRAY", StringComparison.Ordinal) || upper.StartsWith("STRUCT", StringComparison.Ordinal)
            || !SpannerDbType.TryParse(upper, out var parsed) || parsed is null
            ? SpannerDbType.String
            : parsed;

        return new SpannerParameter(name, type, value is null ? DBNull.Value : Convert(value, type, spannerType ?? "STRING"));
    }

    private static object Convert(object value, SpannerDbType type, string spannerType)
    {
        var inv = CultureInfo.InvariantCulture;
        var text = value as string;
        object? converted;
        if (type.Equals(SpannerDbType.Int64))
        {
            converted = text is null ? System.Convert.ToInt64(value, inv) : long.TryParse(text, NumberStyles.Integer, inv, out var l) ? l : null;
        }
        else if (type.Equals(SpannerDbType.Float64))
        {
            converted = text is null ? System.Convert.ToDouble(value, inv) : double.TryParse(text, NumberStyles.Float, inv, out var d) ? d : null;
        }
        else if (type.Equals(SpannerDbType.Float32))
        {
            converted = text is null ? System.Convert.ToSingle(value, inv) : float.TryParse(text, NumberStyles.Float, inv, out var f) ? f : null;
        }
        else if (type.Equals(SpannerDbType.Numeric))
        {
            converted = value is decimal m ? SpannerNumeric.FromDecimal(m, LossOfPrecisionHandling.Throw) : SpannerNumeric.TryParse(text ?? System.Convert.ToString(value, inv), out var n) ? n : null;
        }
        else if (type.Equals(SpannerDbType.Bool))
        {
            converted = value is bool b ? b : (text ?? string.Empty).Trim().ToUpperInvariant() switch
            {
                "TRUE" or "T" or "1" or "YES" or "Y" => true,
                "FALSE" or "F" or "0" or "NO" or "N" => false,
                _ => null,
            };
        }
        else if (type.Equals(SpannerDbType.Date))
        {
            converted = value switch
            {
                DateTime dt => dt.Date,
                DateOnly date => date.ToDateTime(TimeOnly.MinValue),
                _ => DateTime.TryParse(text, inv, DateTimeStyles.AllowWhiteSpaces, out var parsed) ? parsed.Date : null,
            };
        }
        else if (type.Equals(SpannerDbType.Timestamp))
        {
            converted = value switch
            {
                DateTime dt => dt.Kind == DateTimeKind.Unspecified ? DateTime.SpecifyKind(dt, DateTimeKind.Utc) : dt.ToUniversalTime(),
                DateTimeOffset dto => dto.UtcDateTime,
                _ => DateTimeOffset.TryParse(text, inv, DateTimeStyles.AssumeUniversal, out var parsed) ? parsed.UtcDateTime : null,
            };
        }
        else if (type.Equals(SpannerDbType.Bytes))
        {
            converted = value as byte[] ?? FromHex(text ?? string.Empty);
        }
        else
        {
            converted = text ?? System.Convert.ToString(value, inv);
        }

        return converted ?? throw new FormatException(CoreStrings.Format("Driver/InvalidTypedValue", value, spannerType));
    }

    private static byte[]? FromHex(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
        {
            trimmed = trimmed[2..];
        }

        try
        {
            return System.Convert.FromHexString(trimmed);
        }
        catch (FormatException)
        {
            try
            {
                return System.Convert.FromBase64String(text.Trim());
            }
            catch (FormatException)
            {
                return null;
            }
        }
    }

    /// <summary>
    /// The statements of the database's DDL that define one object: its CREATE TABLE or CREATE VIEW, then the
    /// indexes on a table. GetDatabaseDdl is the only source that keeps INTERLEAVE and ROW DELETION POLICY clauses.
    /// </summary>
    public static IReadOnlyList<string> PickDefinition(IEnumerable<string> statements, ObjectName name)
    {
        ArgumentNullException.ThrowIfNull(statements);
        var target = string.IsNullOrEmpty(name.Schema) ? name.Name : $"{name.Schema}.{name.Name}";
        var picked = new List<string>();
        var indexes = new List<string>();
        foreach (var statement in statements)
        {
            var words = Tokens(statement);
            var at = 0;
            if (!Is(words, at++, "CREATE"))
            {
                continue;
            }

            if (Is(words, at, "OR") && Is(words, at + 1, "REPLACE"))
            {
                at += 2;
            }

            if (Is(words, at, "TABLE") || Is(words, at, "VIEW"))
            {
                if (Unquote(Word(words, at + 1)) == target)
                {
                    picked.Add(statement.Trim());
                }
            }
            else
            {
                var on = words.FindIndex(w => w.Equals("ON", StringComparison.OrdinalIgnoreCase));
                if (words.Skip(at).Take(4).Any(w => w.Equals("INDEX", StringComparison.OrdinalIgnoreCase)) && on > 0 && Unquote(Word(words, on + 1)) == target)
                {
                    indexes.Add(statement.Trim());
                }
            }
        }

        picked.AddRange(indexes);
        return picked;
    }

    private static List<string> Tokens(string statement)
    {
        var words = new List<string>();
        var sb = new StringBuilder();
        var quoted = false;
        foreach (var c in statement)
        {
            if (c == '`')
            {
                quoted = !quoted;
                sb.Append(c);
            }
            else if (!quoted && (char.IsWhiteSpace(c) || c == '('))
            {
                if (sb.Length > 0)
                {
                    words.Add(sb.ToString());
                    sb.Clear();
                }

                if (c == '(')
                {
                    words.Add("(");
                }
            }
            else
            {
                sb.Append(c);
            }
        }

        if (sb.Length > 0)
        {
            words.Add(sb.ToString());
        }

        return words;
    }

    private static bool Is(List<string> words, int index, string word) => index < words.Count && words[index].Equals(word, StringComparison.OrdinalIgnoreCase);

    private static string Word(List<string> words, int index) => index < words.Count ? words[index] : string.Empty;

    private static string Unquote(string name) => name.Replace("`", string.Empty, StringComparison.Ordinal);

    public static readonly IReadOnlyList<string> CommonDataTypes =
        ["INT64", "STRING(MAX)", "BOOL", "FLOAT64", "NUMERIC", "TIMESTAMP", "DATE", "JSON", "BYTES(MAX)", "FLOAT32", "ARRAY<STRING(MAX)>", "ARRAY<INT64>"];

    /// <summary>
    /// Spanner DDL for a structure edit. The statements run through UpdateDatabaseDdl (the channel routes them), a
    /// long-running operation that applies them in order and may take minutes on a large table. Spanner cannot
    /// rename a column or keep column comments, so those changes return nothing.
    /// </summary>
    public static IReadOnlyList<string> BuildDdl(ObjectName table, SchemaChange change)
    {
        ArgumentNullException.ThrowIfNull(change);
        var qualified = Qualify(table);
        return change switch
        {
            CreateTable create => [CreateTableSql(create)],
            AddColumn add => [$"ALTER TABLE {qualified} ADD COLUMN {ColumnSql(add.Column)}"],
            DropColumn drop => [$"ALTER TABLE {qualified} DROP COLUMN {Quote(drop.Column)}"],
            RenameColumn => [],
            AlterColumn alter => AlterColumnSql(qualified, alter),
            CreateIndex index => [$"CREATE {(index.Index.IsUnique ? "UNIQUE " : string.Empty)}INDEX {Quote(index.Index.Name)} ON {qualified} ({string.Join(", ", index.Index.Columns.Select(Quote))})"],
            DropIndex index => [$"DROP INDEX {Quote(index.Index)}"],
            AddForeignKey fk =>
            [
                $"ALTER TABLE {qualified} ADD CONSTRAINT {Quote(fk.ForeignKey.Name)} FOREIGN KEY ({string.Join(", ", fk.ForeignKey.Columns.Select(Quote))}) "
                + $"REFERENCES {Qualify(fk.ForeignKey.ReferencedTable)} ({string.Join(", ", fk.ForeignKey.ReferencedColumns.Select(Quote))})"
                + (fk.ForeignKey.OnDelete?.ToUpperInvariant() is "CASCADE" ? " ON DELETE CASCADE" : string.Empty),
            ],
            DropForeignKey fk => [$"ALTER TABLE {qualified} DROP CONSTRAINT {Quote(fk.Name)}"],
            RenameTable rename => [$"ALTER TABLE {qualified} RENAME TO {Quote(rename.NewName)}"],
            DropObject drop => drop.Object.Kind switch
            {
                ObjectKind.View => [$"DROP VIEW {Qualify(drop.Object.Name)}"],
                ObjectKind.Sequence => [$"DROP SEQUENCE {Qualify(drop.Object.Name)}"],
                ObjectKind.Table => [$"DROP TABLE {Qualify(drop.Object.Name)}"],
                _ => [],
            },

            // Spanner has no TRUNCATE; a partitioned-friendly DELETE is the documented way to empty a table.
            TruncateTable => [$"DELETE FROM {qualified} WHERE TRUE"],
            _ => [],
        };
    }

    private static string CreateTableSql(CreateTable create)
    {
        var keys = create.Columns.Where(c => c.IsPrimaryKey).Select(c => Quote(c.Name)).ToArray();
        return $"CREATE TABLE {Qualify(create.Table)} (\n  {string.Join(",\n  ", create.Columns.Select(ColumnSql))}\n) PRIMARY KEY ({string.Join(", ", keys)})";
    }

    private static string ColumnSql(ColumnDefinition column)
    {
        var sb = new StringBuilder(Quote(column.Name)).Append(' ').Append(column.DataType);
        if (column.IsIdentity)
        {
            sb.Append(" GENERATED BY DEFAULT AS IDENTITY (BIT_REVERSED_POSITIVE)");
        }

        if (!column.IsNullable)
        {
            sb.Append(" NOT NULL");
        }

        if (!string.IsNullOrWhiteSpace(column.DefaultExpression) && !column.IsIdentity)
        {
            sb.Append(" DEFAULT (").Append(column.DefaultExpression).Append(')');
        }

        return sb.ToString();
    }

    private static List<string> AlterColumnSql(string qualified, AlterColumn alter)
    {
        var statements = new List<string>();
        var (before, after) = (alter.Before, alter.After);
        var column = Quote(after.Name);
        if (!string.Equals(before.DataType, after.DataType, StringComparison.OrdinalIgnoreCase) || before.IsNullable != after.IsNullable)
        {
            statements.Add($"ALTER TABLE {qualified} ALTER COLUMN {column} {after.DataType}{(after.IsNullable ? string.Empty : " NOT NULL")}");
        }

        if (!string.Equals(before.DefaultExpression, after.DefaultExpression, StringComparison.Ordinal))
        {
            statements.Add(string.IsNullOrWhiteSpace(after.DefaultExpression)
                ? $"ALTER TABLE {qualified} ALTER COLUMN {column} DROP DEFAULT"
                : $"ALTER TABLE {qualified} ALTER COLUMN {column} SET DEFAULT ({after.DefaultExpression})");
        }

        return statements;
    }
}
