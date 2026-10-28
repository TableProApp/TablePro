using System.Net;
using System.Net.Http.Headers;
using System.Net.Security;
using System.Security.Authentication;
using System.Text;
using System.Text.Json;
using TablePro.Core.Connections;

// Linked into each HTTP search driver as source rather than referenced as a project, because drivers reference Core
// only. Each assembly compiles its own internal copy.
namespace TablePro.Drivers.Http;

/// <summary>Where a driver sends its requests: the scheme, host and port the profile's SSL mode and the request decide.</summary>
internal static class HttpEndpoint
{
    /// <summary>
    /// Builds the base address. A host typed as a URL keeps its own scheme and port, since a pasted
    /// <c>https://host:9243</c> means exactly that, and a pasted <c>https://host</c> means port 443.
    /// </summary>
    public static Uri BaseUri(string host, int port, bool tls)
    {
        var trimmed = host.Trim();
        if (trimmed.Contains("://", StringComparison.Ordinal) && Uri.TryCreate(trimmed, UriKind.Absolute, out var typed))
        {
            return new UriBuilder(typed.Scheme, typed.Host, typed.Port).Uri;
        }

        if (trimmed.Length == 0)
        {
            trimmed = "localhost";
        }

        // An IPv6 literal needs brackets inside a URL.
        if (trimmed.Contains(':', StringComparison.Ordinal) && !trimmed.StartsWith('['))
        {
            trimmed = $"[{trimmed}]";
        }

        return new UriBuilder(tls ? "https" : "http", trimmed, port).Uri;
    }

    public static bool HostSetsScheme(string host) => host.Contains("://", StringComparison.Ordinal);

    public static SocketsHttpHandler CreateHandler(SslMode mode, int connectTimeoutSeconds)
    {
        var handler = new SocketsHttpHandler
        {
            ConnectTimeout = TimeSpan.FromSeconds(connectTimeoutSeconds > 0 ? connectTimeoutSeconds : 15),
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
            AutomaticDecompression = DecompressionMethods.All,
            AllowAutoRedirect = false,
        };

        handler.SslOptions.RemoteCertificateValidationCallback = mode switch
        {
            SslMode.VerifyIdentity => null,

            // Verify CA trusts the chain but not the name, as libpq's verify-ca does.
            SslMode.VerifyCa => static (_, _, _, errors) => (errors & ~SslPolicyErrors.RemoteCertificateNameMismatch) == SslPolicyErrors.None,

            // Required and Preferred encrypt without checking who answers, matching libpq's require and prefer. The
            // user picks Verify CA or Verify Identity for a checked certificate.
#pragma warning disable CA5359
            _ => static (_, _, _, _) => true,
#pragma warning restore CA5359
        };

        return handler;
    }

    /// <summary>
    /// Preferred tries TLS first and falls back to plain HTTP when the server does not speak it, as libpq's prefer does,
    /// so a local engine on http works with the profile's default mode.
    /// </summary>
    public static bool IsTlsFailure(Exception exception) =>
        exception is HttpRequestException { HttpRequestError: HttpRequestError.SecureConnectionError }
        || exception is HttpRequestException { InnerException: AuthenticationException or IOException };
}

/// <summary>A response read whole: the status, the bytes and, on demand, the parsed JSON.</summary>
internal sealed class HttpReply
{
    public HttpReply(HttpStatusCode status, byte[] body, string? mediaType)
    {
        Status = status;
        Body = body;
        MediaType = mediaType;
    }

    public HttpStatusCode Status { get; }

    public int StatusCode => (int)Status;

    public bool IsSuccess => StatusCode is >= 200 and < 300;

    public byte[] Body { get; }

    public string? MediaType { get; }

    public string Text => Encoding.UTF8.GetString(Body);

    /// <summary>The body as JSON, or null when it is empty or not JSON.</summary>
    public JsonDocument? TryParseJson()
    {
        var span = Body.AsSpan().TrimStart(" \t\r\n"u8);
        if (span.IsEmpty || (span[0] is not ((byte)'{' or (byte)'[' or (byte)'"') && !char.IsAsciiDigit((char)span[0]) && span[0] is not ((byte)'-' or (byte)'t' or (byte)'f' or (byte)'n')))
        {
            return null;
        }

        try
        {
            return JsonDocument.Parse(Body, new JsonDocumentOptions { AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Skip });
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

/// <summary>A server's refusal, carrying the reason the server gave.</summary>
internal sealed class ServerRequestException : InvalidOperationException
{
    public ServerRequestException(string message, int statusCode = 0)
        : base(message)
    {
        StatusCode = statusCode;
    }

    public ServerRequestException()
    {
    }

    public ServerRequestException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    public int StatusCode { get; }
}

/// <summary>
/// One <see cref="HttpClient"/> over one handler for a session. Paths are resolved against the base address and a path
/// that would leave it is refused, because the auth header rides on every request.
/// </summary>
internal sealed class HttpTransport : IDisposable
{
    private readonly HttpClient _client;

    public HttpTransport(HttpMessageHandler handler, Uri baseAddress, bool disposeHandler = true)
    {
        _client = new HttpClient(handler, disposeHandler) { Timeout = Timeout.InfiniteTimeSpan };
        BaseAddress = baseAddress;
    }

    public Uri BaseAddress { get; set; }

    public HttpRequestHeaders DefaultHeaders => _client.DefaultRequestHeaders;

    public Uri Resolve(string pathAndQuery)
    {
        var path = pathAndQuery.Trim();
        if (path.StartsWith("//", StringComparison.Ordinal) || path.Contains("://", StringComparison.Ordinal))
        {
            throw new ServerRequestException($"The path {path} would leave {BaseAddress.Authority}.");
        }

        if (!path.StartsWith('/'))
        {
            path = "/" + path;
        }

        // Uri unescapes %2E and collapses dot segments, so a document id of ".." would turn a DELETE of one document
        // into a DELETE of its parent, the whole collection.
        var question = path.IndexOf('?', StringComparison.Ordinal);
        foreach (var segment in (question < 0 ? path : path[..question]).Split('/'))
        {
            if (Uri.UnescapeDataString(segment) is "." or "..")
            {
                throw new ServerRequestException($"The path {path} has a . or .. segment, which would address a different resource.");
            }
        }

        var uri = new Uri(BaseAddress, path);
        if (!string.Equals(uri.Authority, BaseAddress.Authority, StringComparison.OrdinalIgnoreCase) || uri.Scheme != BaseAddress.Scheme)
        {
            throw new ServerRequestException($"The path {path} would leave {BaseAddress.Authority}.");
        }

        return uri;
    }

    public Task<HttpReply> SendAsync(HttpMethod method, string pathAndQuery, string? body, CancellationToken cancellationToken, string mediaType = "application/json", Action<HttpRequestMessage>? configure = null) =>
        SendAsync(method, pathAndQuery, body is null ? null : new StringContent(body, Encoding.UTF8, mediaType), cancellationToken, configure);

    public async Task<HttpReply> SendAsync(HttpMethod method, string pathAndQuery, HttpContent? content, CancellationToken cancellationToken, Action<HttpRequestMessage>? configure = null)
    {
        using var request = new HttpRequestMessage(method, Resolve(pathAndQuery)) { Content = content };
        configure?.Invoke(request);
        using var response = await _client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
        return new HttpReply(response.StatusCode, bytes, response.Content.Headers.ContentType?.MediaType);
    }

    /// <summary>
    /// Runs the connect probe within the profile's timeout. Under Preferred a TLS failure retries once over plain HTTP
    /// and keeps that scheme for the session.
    /// </summary>
    public async Task<T> ProbeAsync<T>(SslMode mode, string host, int connectTimeoutSeconds, Func<CancellationToken, Task<T>> probe, CancellationToken cancellationToken)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(connectTimeoutSeconds > 0 ? connectTimeoutSeconds : 15));
        try
        {
            return await probe(deadline.Token);
        }
        catch (Exception ex) when (mode == SslMode.Preferred && BaseAddress.Scheme == Uri.UriSchemeHttps && !HttpEndpoint.HostSetsScheme(host) && HttpEndpoint.IsTlsFailure(ex))
        {
            BaseAddress = new UriBuilder(BaseAddress) { Scheme = Uri.UriSchemeHttp }.Uri;
            return await probe(deadline.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException($"{BaseAddress.Authority} did not answer within {connectTimeoutSeconds} s.");
        }
    }

    public void Dispose() => _client.Dispose();
}
