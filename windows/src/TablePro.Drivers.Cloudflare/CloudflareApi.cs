using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;

namespace TablePro.Drivers.Cloudflare;

/// <summary>A refusal from the Cloudflare API, or a connection setting it would refuse.</summary>
public sealed class CloudflareApiException : Exception
{
    public CloudflareApiException()
    {
    }

    public CloudflareApiException(string message)
        : base(message)
    {
    }

    public CloudflareApiException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    public CloudflareApiException(string message, HttpStatusCode statusCode)
        : base(message)
    {
        StatusCode = statusCode;
    }

    public HttpStatusCode? StatusCode { get; }
}

internal sealed class CloudflareError
{
    public int Code { get; set; }

    public string Message { get; set; } = string.Empty;
}

/// <summary>Every Cloudflare v4 and R2 SQL answer wraps its result the same way.</summary>
internal sealed class CloudflareEnvelope<T>
{
    public bool Success { get; set; }

    public List<CloudflareError>? Errors { get; set; }

    public T? Result { get; set; }
}

internal sealed class D1RawPayload
{
    public D1RawResults? Results { get; set; }

    public D1Meta? Meta { get; set; }

    public bool Success { get; set; }
}

internal sealed class D1RawResults
{
    public List<string>? Columns { get; set; }

    public List<List<JsonElement>>? Rows { get; set; }
}

internal sealed class D1Meta
{
    public double? Duration { get; set; }

    public long? Changes { get; set; }

    [JsonPropertyName("rows_read")]
    public long? RowsRead { get; set; }

    [JsonPropertyName("rows_written")]
    public long? RowsWritten { get; set; }

    [JsonPropertyName("last_row_id")]
    public long? LastRowId { get; set; }
}

internal sealed class D1DatabaseInfo
{
    public string Uuid { get; set; } = string.Empty;

    public string Name { get; set; } = string.Empty;

    public string? Version { get; set; }

    [JsonPropertyName("num_tables")]
    public long? NumTables { get; set; }

    [JsonPropertyName("file_size")]
    public long? FileSize { get; set; }
}

internal sealed class R2SqlResult
{
    public List<R2SqlField>? Schema { get; set; }

    public List<Dictionary<string, JsonElement>>? Rows { get; set; }
}

internal sealed class R2SqlField
{
    public string Name { get; set; } = string.Empty;

    public R2SqlDescriptor? Descriptor { get; set; }
}

internal sealed class R2SqlDescriptor
{
    public R2SqlType? Type { get; set; }

    public bool? Nullable { get; set; }
}

internal sealed class R2SqlType
{
    public string Name { get; set; } = string.Empty;
}

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.SnakeCaseLower, PropertyNameCaseInsensitive = true)]
[JsonSerializable(typeof(CloudflareEnvelope<List<D1RawPayload>>))]
[JsonSerializable(typeof(CloudflareEnvelope<D1DatabaseInfo>))]
[JsonSerializable(typeof(CloudflareEnvelope<List<D1DatabaseInfo>>))]
[JsonSerializable(typeof(CloudflareEnvelope<R2SqlResult>))]
[JsonSerializable(typeof(CloudflareEnvelope<JsonElement>))]
internal sealed partial class CloudflareJsonContext : JsonSerializerContext;

/// <summary>Sends one request to a Cloudflare endpoint and unwraps its envelope, turning every failure into one message.</summary>
internal static class CloudflareHttp
{
    public static HttpClient CreateClient(HttpMessageHandler? handler, int connectTimeoutSeconds)
    {
        handler ??= new SocketsHttpHandler
        {
            ConnectTimeout = TimeSpan.FromSeconds(Math.Max(1, connectTimeoutSeconds)),
            PooledConnectionIdleTimeout = TimeSpan.FromMinutes(2),
            AutomaticDecompression = DecompressionMethods.All,
        };

        // Each call carries its own cancellation, which is where the query timeout lives.
        return new HttpClient(handler, disposeHandler: true) { Timeout = Timeout.InfiniteTimeSpan };
    }

    public static async Task<T> SendAsync<T>(
        HttpClient http,
        HttpMethod method,
        Uri uri,
        string token,
        byte[]? body,
        JsonTypeInfo<CloudflareEnvelope<T>> typeInfo,
        string? authHint,
        CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(method, uri);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (body is not null)
        {
            request.Content = new ByteArrayContent(body);
            request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        }

        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
        CloudflareEnvelope<T>? envelope = null;
        try
        {
            envelope = bytes.Length == 0 ? null : JsonSerializer.Deserialize(bytes, typeInfo);
        }
        catch (JsonException) when (!response.IsSuccessStatusCode)
        {
            // An error page from a proxy is not JSON; the status and body below explain it.
        }
        catch (JsonException ex)
        {
            throw new CloudflareApiException($"Cloudflare returned a response TablePro could not read (HTTP {(int)response.StatusCode}): {Snippet(bytes)}", ex);
        }

        if (response.IsSuccessStatusCode && envelope is { Success: true })
        {
            return envelope.Result ?? throw new CloudflareApiException("Cloudflare returned an empty result.");
        }

        throw Failure(response, envelope?.Errors, bytes, authHint);
    }

    public static CloudflareApiException Failure(HttpResponseMessage response, List<CloudflareError>? errors, byte[] body, string? authHint)
    {
        var status = response.StatusCode;
        var messages = errors?.Select(e => e.Message).Where(m => !string.IsNullOrWhiteSpace(m)).ToArray() ?? [];
        var detail = messages.Length > 0 ? string.Join("\n", messages) : null;
        var message = status switch
        {
            HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden =>
                $"{detail ?? "Authentication failed"}. {authHint ?? "Check the API token and account ID."}",
            HttpStatusCode.TooManyRequests => response.Headers.RetryAfter?.Delta is { } delay
                ? string.Create(CultureInfo.InvariantCulture, $"Cloudflare is rate limiting this token. Retry after {delay.TotalSeconds:0} seconds.")
                : "Cloudflare is rate limiting this token. Try again shortly.",
            _ => detail ?? $"Cloudflare returned HTTP {(int)status}: {Snippet(body)}",
        };
        return new CloudflareApiException(message, status);
    }

    public static string Snippet(byte[] body)
    {
        var text = Encoding.UTF8.GetString(body, 0, Math.Min(body.Length, 300)).Trim();
        return text.Length == 0 ? "empty body" : text;
    }
}
