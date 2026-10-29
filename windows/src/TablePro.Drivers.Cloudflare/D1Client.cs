using System.Buffers;
using System.Text.Json;
using TablePro.Core.Localization;
using TablePro.Core.Results;
using TablePro.Drivers.Cloudflare.Localization;

namespace TablePro.Drivers.Cloudflare;

/// <summary>One statement's answer from D1: its rows, how many rows it changed and what the server reports it cost.</summary>
internal sealed record D1Result(ResultSet Rows, long Changes, double? DurationMs, long? RowsRead, long? RowsWritten);

/// <summary>
/// The D1 REST API. Statements go to the <c>/raw</c> form of the query endpoint, which returns columns and row
/// arrays rather than one object per row, so column order and duplicate names survive.
/// </summary>
internal sealed class D1Client(HttpClient http, string accountId, string token)
{
    public const string ApiBase = "https://api.cloudflare.com/client/v4/";

    private static string AuthHint => CloudflareStrings.Get("Cloudflare/D1AuthHint");

    public Uri DatabaseUri(string? databaseId, string? suffix = null)
    {
        var path = $"{ApiBase}accounts/{Uri.EscapeDataString(accountId)}/d1/database";
        if (databaseId is not null)
        {
            path += "/" + Uri.EscapeDataString(databaseId);
        }

        if (suffix is not null)
        {
            path += "/" + suffix;
        }

        return new Uri(path);
    }

    public static bool IsDatabaseId(string value) => value.Length == 36 && Guid.TryParseExact(value, "D", out _);

    public static byte[] BuildQueryBody(string sql, IReadOnlyList<object?> parameters)
    {
        var buffer = new ArrayBufferWriter<byte>(sql.Length + 64);
        using (var writer = new Utf8JsonWriter(buffer))
        {
            WriteStatement(writer, sql, parameters);
        }

        return buffer.WrittenSpan.ToArray();
    }

    public static byte[] BuildBatchBody(IReadOnlyList<(string Sql, IReadOnlyList<object?> Parameters)> statements)
    {
        var buffer = new ArrayBufferWriter<byte>(256);
        using (var writer = new Utf8JsonWriter(buffer))
        {
            writer.WriteStartObject();
            writer.WriteStartArray("batch");
            foreach (var (sql, parameters) in statements)
            {
                WriteStatement(writer, sql, parameters);
            }

            writer.WriteEndArray();
            writer.WriteEndObject();
        }

        return buffer.WrittenSpan.ToArray();
    }

    public async Task<D1Result> QueryAsync(string databaseId, string sql, IReadOnlyList<object?> parameters, int rowLimit, CancellationToken cancellationToken)
    {
        var payloads = await CloudflareHttp.SendAsync(
            http, HttpMethod.Post, DatabaseUri(databaseId, "raw"), token, BuildQueryBody(sql, parameters),
            CloudflareJsonContext.Default.CloudflareEnvelopeListD1RawPayload, AuthHint, cancellationToken);
        return payloads.Count == 0 ? throw new CloudflareApiException(CoreStrings.Get("Driver/NoResultForStatement")) : Map(payloads[0], rowLimit);
    }

    public async Task<IReadOnlyList<D1Result>> BatchAsync(
        string databaseId, IReadOnlyList<(string Sql, IReadOnlyList<object?> Parameters)> statements, CancellationToken cancellationToken)
    {
        var payloads = await CloudflareHttp.SendAsync(
            http, HttpMethod.Post, DatabaseUri(databaseId, "raw"), token, BuildBatchBody(statements),
            CloudflareJsonContext.Default.CloudflareEnvelopeListD1RawPayload, AuthHint, cancellationToken);
        return payloads.Select(p => Map(p, int.MaxValue)).ToArray();
    }

    public Task<D1DatabaseInfo> GetDatabaseAsync(string databaseId, CancellationToken cancellationToken) =>
        CloudflareHttp.SendAsync(
            http, HttpMethod.Get, DatabaseUri(databaseId), token, null,
            CloudflareJsonContext.Default.CloudflareEnvelopeD1DatabaseInfo, AuthHint, cancellationToken);

    /// <summary>The account's databases, optionally narrowed by the API's own name filter.</summary>
    public Task<List<D1DatabaseInfo>> ListDatabasesAsync(string? name, CancellationToken cancellationToken)
    {
        var uri = DatabaseUri(null);
        uri = new Uri(name is null ? uri + "?per_page=1000" : $"{uri}?name={Uri.EscapeDataString(name)}&per_page=1000");
        return CloudflareHttp.SendAsync(
            http, HttpMethod.Get, uri, token, null,
            CloudflareJsonContext.Default.CloudflareEnvelopeListD1DatabaseInfo, AuthHint, cancellationToken);
    }

    public static D1Result Map(D1RawPayload payload, int rowLimit)
    {
        var names = payload.Results?.Columns ?? [];
        var raw = payload.Results?.Rows ?? [];
        var take = Math.Min(raw.Count, rowLimit);
        var rows = new List<object?[]>(take);
        for (var r = 0; r < take; r++)
        {
            var source = raw[r];
            var row = new object?[names.Count];
            for (var c = 0; c < row.Length && c < source.Count; c++)
            {
                row[c] = SqlValues.FromJson(source[c]);
            }

            rows.Add(row);
        }

        var columns = new ResultColumn[names.Count];
        for (var c = 0; c < columns.Length; c++)
        {
            columns[c] = SqlValues.InferColumn(names[c], rows, c);
        }

        var meta = payload.Meta;
        return new D1Result(new ResultSet(columns, rows, raw.Count > take), meta?.Changes ?? 0, meta?.Duration, meta?.RowsRead, meta?.RowsWritten);
    }

    private static void WriteStatement(Utf8JsonWriter writer, string sql, IReadOnlyList<object?> parameters)
    {
        writer.WriteStartObject();
        writer.WriteString("sql", sql);
        if (parameters.Count > 0)
        {
            writer.WriteStartArray("params");
            foreach (var value in parameters)
            {
                SqlValues.WriteD1Parameter(writer, value);
            }

            writer.WriteEndArray();
        }

        writer.WriteEndObject();
    }
}
