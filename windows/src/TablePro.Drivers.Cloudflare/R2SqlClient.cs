using System.Buffers;
using System.Collections.Frozen;
using System.Globalization;
using System.Text.Json;
using TablePro.Core.Browse;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.Cloudflare;

/// <summary>A column R2 SQL's DESCRIBE reports.</summary>
internal sealed record R2SqlColumn(string Name, string TypeName, bool IsNullable, string? Comment);

/// <summary>
/// R2 SQL's query endpoint, which reads Apache Iceberg tables in an R2 bucket. It is read-only, takes no parameters,
/// returns at most <see cref="MaximumRows"/> rows per query and has no OFFSET.
/// </summary>
internal sealed class R2SqlClient(HttpClient http, string accountId, string bucket, string token)
{
    public const string QueryHost = "api.sql.cloudflarestorage.com";

    public const int MaximumRows = 10_000;

    private const string AuthHint = "The API token needs the R2 SQL, R2 Data Catalog and R2 Storage permissions for this account.";

    private static readonly string[] NamespaceColumns = ["namespace", "namespace_name", "database_name", "schema_name", "databaseName"];
    private static readonly string[] TableColumns = ["table_name", "tableName", "name"];

    private static readonly FrozenDictionary<string, (string Display, Type Clr)> Types = new Dictionary<string, (string, Type)>(StringComparer.OrdinalIgnoreCase)
    {
        ["int8"] = ("TINYINT", typeof(long)),
        ["int16"] = ("SMALLINT", typeof(long)),
        ["int32"] = ("INT", typeof(long)),
        ["int64"] = ("BIGINT", typeof(long)),
        ["uint8"] = ("TINYINT UNSIGNED", typeof(long)),
        ["uint16"] = ("SMALLINT UNSIGNED", typeof(long)),
        ["uint32"] = ("INT UNSIGNED", typeof(long)),
        ["uint64"] = ("BIGINT UNSIGNED", typeof(decimal)),
        ["float16"] = ("REAL", typeof(double)),
        ["float32"] = ("REAL", typeof(double)),
        ["float64"] = ("DOUBLE", typeof(double)),
        ["decimal"] = ("DECIMAL", typeof(decimal)),
        ["decimal128"] = ("DECIMAL", typeof(decimal)),
        ["decimal256"] = ("DECIMAL", typeof(decimal)),
        ["bool"] = ("BOOLEAN", typeof(bool)),
        ["boolean"] = ("BOOLEAN", typeof(bool)),
        ["utf8"] = ("TEXT", typeof(string)),
        ["largeutf8"] = ("TEXT", typeof(string)),
        ["utf8view"] = ("TEXT", typeof(string)),
        ["string"] = ("TEXT", typeof(string)),
        ["bytes"] = ("BINARY", typeof(byte[])),
        ["binary"] = ("BINARY", typeof(byte[])),
        ["largebinary"] = ("BINARY", typeof(byte[])),
        ["binaryview"] = ("BINARY", typeof(byte[])),
        ["fixedsizebinary"] = ("BINARY", typeof(byte[])),
        ["date"] = ("DATE", typeof(string)),
        ["date32"] = ("DATE", typeof(string)),
        ["date64"] = ("DATE", typeof(string)),
        ["time"] = ("TIME", typeof(string)),
        ["time32"] = ("TIME", typeof(string)),
        ["time64"] = ("TIME", typeof(string)),
        ["timestamp"] = ("TIMESTAMP", typeof(string)),
        ["list"] = ("ARRAY", typeof(string)),
        ["largelist"] = ("ARRAY", typeof(string)),
        ["fixedsizelist"] = ("ARRAY", typeof(string)),
        ["struct"] = ("STRUCT", typeof(string)),
        ["map"] = ("MAP", typeof(string)),
    }.ToFrozenDictionary(StringComparer.OrdinalIgnoreCase);

    public Uri QueryUri => new($"https://{QueryHost}/api/v1/accounts/{Uri.EscapeDataString(accountId)}/r2-sql/query/{Uri.EscapeDataString(bucket)}");

    public static byte[] BuildBody(string sql)
    {
        var buffer = new ArrayBufferWriter<byte>(sql.Length + 16);
        using (var writer = new Utf8JsonWriter(buffer))
        {
            writer.WriteStartObject();
            writer.WriteString("query", sql);
            writer.WriteEndObject();
        }

        return buffer.WrittenSpan.ToArray();
    }

    public Task<R2SqlResult> QueryAsync(string sql, CancellationToken cancellationToken) =>
        CloudflareHttp.SendAsync(
            http, HttpMethod.Post, QueryUri, token, BuildBody(sql),
            CloudflareJsonContext.Default.CloudflareEnvelopeR2SqlResult, AuthHint, cancellationToken);

    public static string QuoteIdentifier(string identifier) => SqliteDialect.Instance.QuoteIdentifier(identifier);

    public static string ShowTables(string ns) => "SHOW TABLES IN " + QuoteIdentifier(ns);

    public static string Describe(string ns, string table) => $"DESCRIBE {QuoteIdentifier(ns)}.{QuoteIdentifier(table)}";

    /// <summary>Maps an answer to a result, skipping the first <paramref name="skip"/> rows and keeping at most <paramref name="rowLimit"/>.</summary>
    public static ResultSet Map(R2SqlResult result, int skip, int rowLimit)
    {
        var fields = result.Schema ?? [];
        var columns = new ResultColumn[fields.Count];
        for (var c = 0; c < fields.Count; c++)
        {
            var typeName = fields[c].Descriptor?.Type?.Name ?? string.Empty;
            var (display, clr) = Types.TryGetValue(typeName.Trim(), out var known) ? known : (typeName.Trim().ToUpperInvariant(), typeof(string));
            columns[c] = new ResultColumn(fields[c].Name, display, clr);
        }

        var source = result.Rows ?? [];
        var start = Math.Min(Math.Max(skip, 0), source.Count);
        var take = Math.Min(source.Count - start, rowLimit);
        var rows = new List<object?[]>(take);
        for (var r = start; r < start + take; r++)
        {
            var record = source[r];
            var row = new object?[columns.Length];
            for (var c = 0; c < columns.Length; c++)
            {
                row[c] = record.TryGetValue(columns[c].Name, out var value) ? Cell(value, columns[c].ClrType) : null;
            }

            rows.Add(row);
        }

        return new ResultSet(columns, rows, source.Count - start > take);
    }

    public static IReadOnlyList<string> Namespaces(R2SqlResult result) => Names(result, NamespaceColumns, "SHOW NAMESPACES");

    public static IReadOnlyList<string> Tables(R2SqlResult result) => Names(result, TableColumns, "SHOW TABLES");

    public static IReadOnlyList<R2SqlColumn> Columns(R2SqlResult result)
    {
        var available = (result.Schema ?? []).Select(f => f.Name).ToHashSet(StringComparer.Ordinal);
        if (!available.Contains("column_name") || !available.Contains("type"))
        {
            throw new CloudflareApiException($"DESCRIBE returned columns TablePro does not recognize: {string.Join(", ", available)}.");
        }

        var columns = new List<R2SqlColumn>();
        foreach (var row in result.Rows ?? [])
        {
            var name = Text(row, "column_name");
            if (string.IsNullOrEmpty(name))
            {
                continue;
            }

            var required = row.TryGetValue("required", out var flag)
                && (flag.ValueKind == JsonValueKind.True || (flag.ValueKind == JsonValueKind.String && string.Equals(flag.GetString(), "true", StringComparison.OrdinalIgnoreCase)));
            var doc = Text(row, "doc");
            columns.Add(new R2SqlColumn(name, Text(row, "type") ?? string.Empty, !required, string.IsNullOrEmpty(doc) ? null : doc));
        }

        return columns;
    }

    /// <summary>
    /// The query that shows one page. With no OFFSET, a page is the first <c>offset + limit</c> rows with the first
    /// <c>offset</c> dropped here, so nothing past the 10,000-row ceiling can be shown.
    /// </summary>
    public static (string Sql, int Skip) BuildBrowse(SqlDialect dialect, BrowseRequest request)
    {
        if (request.Offset >= MaximumRows)
        {
            throw new NotSupportedException(string.Create(
                CultureInfo.InvariantCulture,
                $"R2 SQL returns at most {MaximumRows:N0} rows per query and has no OFFSET, so rows past {MaximumRows:N0} cannot be paged to. Narrow the rows with a filter or sort instead."));
        }

        var fetch = (int)Math.Min((long)request.Offset + request.Limit, MaximumRows);
        var spec = dialect.BuildBrowse(request with { Offset = 0, Limit = fetch });
        var sql = SqlValues.Inline(spec, dialect);

        // The shared builder always ends with the paging clause, and R2 SQL refuses OFFSET even when it is zero.
        const string zeroOffset = " OFFSET 0";
        if (sql.EndsWith(zeroOffset, StringComparison.Ordinal))
        {
            sql = sql[..^zeroOffset.Length];
        }

        return (sql, request.Offset);
    }

    public static string BuildCount(SqlDialect dialect, ObjectName table, BrowseFilter filter) =>
        SqlValues.Inline(dialect.BuildCount(table, filter), dialect);

    private static object? Cell(JsonElement value, Type clr)
    {
        switch (value.ValueKind)
        {
            case JsonValueKind.Null or JsonValueKind.Undefined:
                return null;
            case JsonValueKind.True:
                return true;
            case JsonValueKind.False:
                return false;
            case JsonValueKind.Number:
                if (clr == typeof(long) && value.TryGetInt64(out var integer))
                {
                    return integer;
                }

                if (clr == typeof(double))
                {
                    return value.GetDouble();
                }

                return value.TryGetDecimal(out var exact) && clr == typeof(decimal) ? exact : value.GetRawText();
            case JsonValueKind.String:
                var text = value.GetString();
                if (clr == typeof(byte[]) && text is not null)
                {
                    try
                    {
                        return Convert.FromBase64String(text);
                    }
                    catch (FormatException)
                    {
                        return text;
                    }
                }

                return text;
            default:
                return value.GetRawText();
        }
    }

    private static string[] Names(R2SqlResult result, string[] candidates, string statement)
    {
        var available = (result.Schema ?? []).Select(f => f.Name).ToArray();
        var column = candidates.FirstOrDefault(available.Contains) ?? (available.Length == 1 ? available[0] : null)
            ?? throw new CloudflareApiException($"{statement} returned columns TablePro does not recognize: {string.Join(", ", available)}.");
        return (result.Rows ?? [])
            .Select(row => Text(row, column))
            .Where(name => !string.IsNullOrEmpty(name))
            .Select(name => name!)
            .Order(StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    private static string? Text(Dictionary<string, JsonElement> row, string column) =>
        !row.TryGetValue(column, out var value) ? null : value.ValueKind switch
        {
            JsonValueKind.String => value.GetString(),
            JsonValueKind.Number => value.GetRawText(),
            JsonValueKind.True => "true",
            JsonValueKind.False => "false",
            _ => null,
        };
}
