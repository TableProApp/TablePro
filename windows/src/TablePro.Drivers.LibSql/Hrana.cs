using System.Buffers;
using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using TablePro.Core.Results;

namespace TablePro.Drivers.LibSql;

/// <summary>A refusal from a libSQL server, or a connection setting it would refuse.</summary>
public sealed class LibSqlException : Exception
{
    public LibSqlException()
    {
    }

    public LibSqlException(string message)
        : base(message)
    {
    }

    public LibSqlException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    public LibSqlException(string message, HttpStatusCode statusCode)
        : base(message)
    {
        StatusCode = statusCode;
    }

    public HttpStatusCode? StatusCode { get; }
}

/// <summary>One request of a Hrana pipeline.</summary>
internal abstract record HranaRequest;

/// <summary>
/// Runs a statement. Positional <see cref="Args"/> bind <c>?</c> and <c>?1</c>; <see cref="NamedArgs"/> bind names
/// such as <c>@p0</c>, which the server matches with their prefix.
/// </summary>
internal sealed record HranaExecute(string Sql, IReadOnlyList<object?> Args, IReadOnlyList<KeyValuePair<string, object?>> NamedArgs) : HranaRequest
{
    public HranaExecute(string sql)
        : this(sql, [], [])
    {
    }
}

/// <summary>Ends the stream, which rolls back a transaction left open on it.</summary>
internal sealed record HranaClose : HranaRequest
{
    public static readonly HranaClose Instance = new();
}

/// <summary>A cell as Hrana sends it: integers as decimal strings so 64 bits survive JSON, blobs as base64.</summary>
[JsonConverter(typeof(HranaValueConverter))]
internal readonly record struct HranaValue(object? Value);

internal sealed class HranaValueConverter : JsonConverter<HranaValue>
{
    public override HranaValue Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.StartObject)
        {
            reader.Skip();
            return default;
        }

        string? type = null;
        object? value = null;
        string? base64 = null;
        while (reader.Read() && reader.TokenType != JsonTokenType.EndObject)
        {
            var property = reader.GetString();
            reader.Read();
            switch (property)
            {
                case "type":
                    type = reader.GetString();
                    break;
                case "value":
                    value = reader.TokenType switch
                    {
                        JsonTokenType.String => reader.GetString(),
                        JsonTokenType.Number => reader.GetDouble(),
                        _ => null,
                    };
                    break;
                case "base64":
                    base64 = reader.GetString();
                    break;
                default:
                    reader.Skip();
                    break;
            }
        }

        return new HranaValue(type switch
        {
            "integer" => value is string s && long.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var integer) ? integer : value,
            "float" => value is string f ? double.Parse(f, CultureInfo.InvariantCulture) : value,
            "text" => value as string ?? Convert.ToString(value, CultureInfo.InvariantCulture),
            "blob" => base64 is null ? Array.Empty<byte>() : Convert.FromBase64String(base64),
            _ => null,
        });
    }

    public override void Write(Utf8JsonWriter writer, HranaValue value, JsonSerializerOptions options) => Hrana.WriteValue(writer, value.Value);
}

internal sealed class HranaPipelineResponse
{
    public string? Baton { get; set; }

    public string? BaseUrl { get; set; }

    public List<HranaStreamResult> Results { get; set; } = [];
}

internal sealed class HranaStreamResult
{
    public string Type { get; set; } = string.Empty;

    public HranaStreamResponse? Response { get; set; }

    public HranaError? Error { get; set; }
}

internal sealed class HranaStreamResponse
{
    public string Type { get; set; } = string.Empty;

    public HranaStatementResult? Result { get; set; }
}

internal sealed class HranaStatementResult
{
    public List<HranaColumn> Cols { get; set; } = [];

    public List<List<HranaValue>> Rows { get; set; } = [];

    public long AffectedRowCount { get; set; }

    public string? LastInsertRowid { get; set; }
}

internal sealed class HranaColumn
{
    public string? Name { get; set; }

    public string? Decltype { get; set; }
}

internal sealed class HranaError
{
    public string Message { get; set; } = string.Empty;

    public string? Code { get; set; }
}

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.SnakeCaseLower, PropertyNameCaseInsensitive = true)]
[JsonSerializable(typeof(HranaPipelineResponse))]
internal sealed partial class HranaJsonContext : JsonSerializerContext;

/// <summary>What one pipeline request produced: rows and a change count, or the server's error.</summary>
internal sealed record HranaOutcome(ResultSet? Rows, long AffectedRows, string? Error)
{
    public bool Succeeded => Error is null;
}

/// <summary>What a pipeline call returned: one outcome per request, and the stream to continue on.</summary>
internal sealed record HranaPipelineResult(IReadOnlyList<HranaOutcome> Outcomes, string? Baton, Uri? BaseUri);

/// <summary>
/// The Hrana over HTTP protocol (version 2) that sqld and Turso speak: <c>POST /v2/pipeline</c> with a list of
/// requests. A pipeline without a closing request returns a baton, and sending it back continues the same stream, which
/// is how a transaction spans several calls.
/// </summary>
internal static class Hrana
{
    public static byte[] BuildPipeline(string? baton, IReadOnlyList<HranaRequest> requests)
    {
        var buffer = new ArrayBufferWriter<byte>(256);
        using (var writer = new Utf8JsonWriter(buffer))
        {
            writer.WriteStartObject();
            if (baton is null)
            {
                writer.WriteNull("baton");
            }
            else
            {
                writer.WriteString("baton", baton);
            }

            writer.WriteStartArray("requests");
            foreach (var request in requests)
            {
                writer.WriteStartObject();
                switch (request)
                {
                    case HranaExecute execute:
                        writer.WriteString("type", "execute");
                        writer.WriteStartObject("stmt");
                        writer.WriteString("sql", execute.Sql);
                        if (execute.Args.Count > 0)
                        {
                            writer.WriteStartArray("args");
                            foreach (var arg in execute.Args)
                            {
                                WriteValue(writer, arg);
                            }

                            writer.WriteEndArray();
                        }

                        if (execute.NamedArgs.Count > 0)
                        {
                            writer.WriteStartArray("named_args");
                            foreach (var (name, value) in execute.NamedArgs)
                            {
                                writer.WriteStartObject();
                                writer.WriteString("name", name);
                                writer.WritePropertyName("value");
                                WriteValue(writer, value);
                                writer.WriteEndObject();
                            }

                            writer.WriteEndArray();
                        }

                        writer.WriteBoolean("want_rows", true);
                        writer.WriteEndObject();
                        break;
                    case HranaClose:
                        writer.WriteString("type", "close");
                        break;
                }

                writer.WriteEndObject();
            }

            writer.WriteEndArray();
            writer.WriteEndObject();
        }

        return buffer.WrittenSpan.ToArray();
    }

    public static void WriteValue(Utf8JsonWriter writer, object? value)
    {
        writer.WriteStartObject();
        switch (value)
        {
            case null or DBNull:
                writer.WriteString("type", "null");
                break;
            case bool flag:
                writer.WriteString("type", "integer");
                writer.WriteString("value", flag ? "1" : "0");
                break;
            case long or int or short or sbyte or byte or ushort or uint or ulong:
                writer.WriteString("type", "integer");
                writer.WriteString("value", ((IFormattable)value).ToString(null, CultureInfo.InvariantCulture));
                break;
            case double d:
                writer.WriteString("type", "float");
                writer.WriteNumberValueOrString("value", d);
                break;
            case float f:
                writer.WriteString("type", "float");
                writer.WriteNumberValueOrString("value", f);
                break;
            case decimal m:
                writer.WriteString("type", "float");
                writer.WriteNumber("value", (double)m);
                break;
            case byte[] bytes:
                writer.WriteString("type", "blob");
                writer.WriteString("base64", Convert.ToBase64String(bytes));
                break;
            case string text:
                writer.WriteString("type", "text");
                writer.WriteString("value", text);
                break;
            case DateTime dateTime:
                writer.WriteString("type", "text");
                writer.WriteString("value", dateTime.ToString("yyyy-MM-dd HH:mm:ss.FFFFFFF", CultureInfo.InvariantCulture));
                break;
            case DateTimeOffset offset:
                writer.WriteString("type", "text");
                writer.WriteString("value", offset.ToString("yyyy-MM-dd HH:mm:ss.FFFFFFFzzz", CultureInfo.InvariantCulture));
                break;
            default:
                writer.WriteString("type", "text");
                writer.WriteString("value", Convert.ToString(value, CultureInfo.InvariantCulture));
                break;
        }

        writer.WriteEndObject();
    }

    // JSON has no NaN or infinity, which SQLite stores as NULL anyway.
    private static void WriteNumberValueOrString(this Utf8JsonWriter writer, string name, double value)
    {
        if (double.IsFinite(value))
        {
            writer.WriteNumber(name, value);
        }
        else
        {
            writer.WriteNull(name);
        }
    }

    public static HranaPipelineResult Map(HranaPipelineResponse response, int rowLimit)
    {
        var outcomes = new List<HranaOutcome>(response.Results.Count);
        foreach (var item in response.Results)
        {
            if (item.Type == "error")
            {
                outcomes.Add(new HranaOutcome(null, 0, item.Error?.Message ?? "The server reported an error without a message."));
                continue;
            }

            var result = item.Response?.Result;
            outcomes.Add(result is null ? new HranaOutcome(null, 0, null) : new HranaOutcome(MapRows(result, rowLimit), result.AffectedRowCount, null));
        }

        Uri? baseUri = null;
        if (!string.IsNullOrEmpty(response.BaseUrl) && Uri.TryCreate(LibSqlSettings.Normalize(response.BaseUrl) + "/", UriKind.Absolute, out var parsed))
        {
            baseUri = parsed;
        }

        return new HranaPipelineResult(outcomes, response.Baton, baseUri);
    }

    public static ResultSet MapRows(HranaStatementResult result, int rowLimit)
    {
        var take = Math.Min(result.Rows.Count, rowLimit);
        var rows = new List<object?[]>(take);
        for (var r = 0; r < take; r++)
        {
            var source = result.Rows[r];
            var row = new object?[result.Cols.Count];
            for (var c = 0; c < row.Length && c < source.Count; c++)
            {
                row[c] = source[c].Value;
            }

            rows.Add(row);
        }

        var columns = new ResultColumn[result.Cols.Count];
        for (var c = 0; c < columns.Length; c++)
        {
            columns[c] = InferColumn(result.Cols[c], rows, c);
        }

        return new ResultSet(columns, rows, result.Rows.Count > take);
    }

    /// <summary>
    /// The CLR type from the page's values, since SQLite types values rather than columns; the declared type is kept
    /// as the type name the grid shows.
    /// </summary>
    private static ResultColumn InferColumn(HranaColumn column, List<object?[]> rows, int ordinal)
    {
        Type? seen = null;
        var mixed = false;
        foreach (var row in rows)
        {
            var type = row[ordinal]?.GetType();
            if (type is null || type == seen)
            {
                continue;
            }

            if (seen is null)
            {
                seen = type;
            }
            else if ((seen == typeof(long) && type == typeof(double)) || (seen == typeof(double) && type == typeof(long)))
            {
                seen = typeof(double);
            }
            else
            {
                mixed = true;
            }
        }

        var clr = mixed ? typeof(object) : seen ?? typeof(string);
        var name = column.Name ?? string.Empty;
        var declared = column.Decltype ?? (seen is null || mixed ? string.Empty
            : clr == typeof(long) ? "INTEGER" : clr == typeof(double) ? "REAL" : clr == typeof(byte[]) ? "BLOB" : "TEXT");
        return new ResultColumn(name, declared, clr);
    }
}

/// <summary>Sends pipelines to one libSQL server.</summary>
internal sealed class HranaClient(HttpClient http, Uri baseUri, string? token)
{
    public Uri BaseUri { get; } = baseUri;

    public static Uri PipelineUri(Uri baseUri) => new(baseUri, "v2/pipeline");

    public async Task<HranaPipelineResult> PipelineAsync(Uri? streamBase, string? baton, IReadOnlyList<HranaRequest> requests, int rowLimit, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, PipelineUri(streamBase ?? BaseUri));
        if (!string.IsNullOrEmpty(token))
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        }

        request.Content = new ByteArrayContent(Hrana.BuildPipeline(baton, requests));
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            var body = await response.Content.ReadAsByteArrayAsync(cancellationToken);
            throw Failure(response, body);
        }

        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        HranaPipelineResponse? parsed;
        try
        {
            parsed = await JsonSerializer.DeserializeAsync(stream, HranaJsonContext.Default.HranaPipelineResponse, cancellationToken);
        }
        catch (JsonException ex)
        {
            throw new LibSqlException("The server returned a response TablePro could not read.", ex);
        }

        return Hrana.Map(parsed ?? new HranaPipelineResponse(), rowLimit);
    }

    /// <summary>Runs statements on a stream of their own, closed in the same call.</summary>
    public async Task<IReadOnlyList<HranaOutcome>> ExecuteAsync(IReadOnlyList<HranaExecute> statements, int rowLimit, CancellationToken cancellationToken)
    {
        var requests = new List<HranaRequest>(statements.Count + 1);
        requests.AddRange(statements);
        requests.Add(HranaClose.Instance);
        var result = await PipelineAsync(null, null, requests, rowLimit, cancellationToken);
        return result.Outcomes.Take(statements.Count).ToArray();
    }

    /// <summary>One statement on a stream of its own, throwing the server's error.</summary>
    public async Task<ResultSet> QueryAsync(HranaExecute statement, CancellationToken cancellationToken)
    {
        var outcomes = await ExecuteAsync([statement], int.MaxValue, cancellationToken);
        var outcome = outcomes.Count > 0 ? outcomes[0] : throw new LibSqlException("The server returned no result for the statement.");
        return outcome.Error is { } error ? throw new LibSqlException(error) : outcome.Rows ?? new ResultSet([], []);
    }

    public async Task<string?> VersionAsync(CancellationToken cancellationToken)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(BaseUri, "version"));
            if (!string.IsNullOrEmpty(token))
            {
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            }

            using var response = await http.SendAsync(request, cancellationToken);
            var text = response.IsSuccessStatusCode ? (await response.Content.ReadAsStringAsync(cancellationToken)).Trim() : null;
            return string.IsNullOrEmpty(text) || text.Length > 64 ? null : text;
        }
        catch (HttpRequestException)
        {
            // Older servers have no version route; the SQLite version still names the server.
            return null;
        }
    }

    public static LibSqlException Failure(HttpResponseMessage response, byte[] body)
    {
        var status = response.StatusCode;
        string? detail = null;
        try
        {
            var parsed = JsonSerializer.Deserialize(body, HranaJsonContext.Default.HranaPipelineResponse);
            detail = parsed?.Results.FirstOrDefault(r => r.Error is not null)?.Error?.Message;
        }
        catch (JsonException)
        {
            // Plain-text errors are reported as they are below.
        }

        var text = detail ?? Encoding.UTF8.GetString(body, 0, Math.Min(body.Length, 300)).Trim();
        var message = status switch
        {
            HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden => "Authentication failed. Check the auth token in the Password field.",
            HttpStatusCode.NotFound => "The server has no Hrana pipeline at this URL. Check the database URL.",
            HttpStatusCode.TooManyRequests => response.Headers.RetryAfter?.Delta is { } delay
                ? string.Create(CultureInfo.InvariantCulture, $"Rate limited. Retry after {delay.TotalSeconds:0} seconds.")
                : "Rate limited. Try again shortly.",
            _ => text.Length > 0 ? text : $"The server returned HTTP {(int)status}.",
        };
        return new LibSqlException(message, status);
    }
}
