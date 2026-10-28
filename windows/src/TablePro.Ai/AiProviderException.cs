using System.Net;
using System.Text.Json;
using TablePro.Ai.Serialization;

namespace TablePro.Ai;

public enum AiErrorKind
{
    Authentication,
    RateLimited,
    ModelNotFound,
    BadRequest,
    ServerError,
    Network,
    InvalidResponse,
}

/// <summary>A provider refused a request or answered with something the client cannot read.</summary>
public sealed class AiProviderException : Exception
{
    private const int MaxErrorBodyBytes = 8 * 1024;

    public AiProviderException()
    {
    }

    public AiProviderException(string message)
        : base(message)
    {
    }

    public AiProviderException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    public AiProviderException(AiErrorKind kind, string message, HttpStatusCode? statusCode = null, Exception? innerException = null)
        : base(message, innerException)
    {
        Kind = kind;
        StatusCode = statusCode;
    }

    public AiErrorKind Kind { get; } = AiErrorKind.InvalidResponse;

    public HttpStatusCode? StatusCode { get; }

    internal static async Task<AiProviderException> FromResponseAsync(HttpResponseMessage response, string providerName, CancellationToken cancellationToken)
    {
        var status = response.StatusCode;
        var detail = await ReadErrorDetailAsync(response, cancellationToken);
        var kind = status switch
        {
            HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden => AiErrorKind.Authentication,
            HttpStatusCode.TooManyRequests => AiErrorKind.RateLimited,
            HttpStatusCode.NotFound => AiErrorKind.ModelNotFound,
            >= HttpStatusCode.InternalServerError => AiErrorKind.ServerError,
            _ => AiErrorKind.BadRequest,
        };
        var prefix = kind switch
        {
            AiErrorKind.Authentication => $"{providerName} refused the API key",
            AiErrorKind.RateLimited => $"{providerName} is rate limiting requests",
            AiErrorKind.ModelNotFound => $"{providerName} does not know that model or address",
            AiErrorKind.ServerError => $"{providerName} had a server error",
            _ => $"{providerName} refused the request",
        };
        var message = string.IsNullOrWhiteSpace(detail) ? $"{prefix} (HTTP {(int)status})." : $"{prefix} (HTTP {(int)status}): {detail}";
        return new AiProviderException(kind, message, status);
    }

    private static async Task<string?> ReadErrorDetailAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        byte[] body;
        try
        {
            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            var buffer = new byte[MaxErrorBodyBytes];
            var total = 0;
            int read;
            while (total < buffer.Length && (read = await stream.ReadAsync(buffer.AsMemory(total), cancellationToken)) > 0)
            {
                total += read;
            }

            body = buffer.AsSpan(0, total).ToArray();
        }
        catch (HttpRequestException)
        {
            return null;
        }

        if (body.Length == 0)
        {
            return null;
        }

        // Gemini wraps its error in an array; the others answer with an object.
        try
        {
            using var document = JsonDocument.Parse(body);
            var root = document.RootElement;
            if (root.ValueKind == JsonValueKind.Array && root.GetArrayLength() > 0)
            {
                root = root[0];
            }

            if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("error", out var error))
            {
                if (error.ValueKind == JsonValueKind.String)
                {
                    return error.GetString();
                }

                if (error.ValueKind == JsonValueKind.Object && error.TryGetProperty("message", out var message) && message.ValueKind == JsonValueKind.String)
                {
                    return message.GetString();
                }
            }
        }
        catch (JsonException)
        {
        }

        var text = System.Text.Encoding.UTF8.GetString(body).Trim();
        return text.Length > 500 ? text[..500] : text;
    }

    internal static AiProviderException FromStreamError(string providerName, ErrorBody? error) =>
        new(AiErrorKind.ServerError, $"{providerName} stopped the reply: {error?.Message ?? "unknown error"}");
}
