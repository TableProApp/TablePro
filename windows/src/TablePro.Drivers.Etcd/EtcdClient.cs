using System.Globalization;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization.Metadata;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.Etcd;

/// <summary>A refusal from etcd or its gateway.</summary>
public sealed class EtcdException : Exception
{
    public EtcdException()
    {
    }

    public EtcdException(string message)
        : base(message)
    {
    }

    public EtcdException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    public EtcdException(string message, HttpStatusCode statusCode, int code)
        : base(message)
    {
        StatusCode = statusCode;
        Code = code;
    }

    public HttpStatusCode? StatusCode { get; }

    /// <summary>The gRPC status code the gateway reports.</summary>
    public int Code { get; }
}

/// <summary>
/// How a profile reaches etcd. TLS follows the profile's SSL mode unless the macOS <c>etcdTlsMode</c> option names one;
/// Preferred stays on plain HTTP because etcd's client port speaks one or the other, never both.
/// </summary>
internal sealed record EtcdSettings(Uri BaseUri, string TlsMode, string? CaPath, string? ClientCertPath, string? ClientKeyPath, string KeyPrefix)
{
    public static EtcdSettings From(ConnectionRequest request)
    {
        var options = request.Profile.AdditionalOptions;
        var tls = Option(options, "etcdTlsMode") ?? request.Profile.SslMode switch
        {
            SslMode.Required => "Required",
            SslMode.VerifyCa => "VerifyCA",
            SslMode.VerifyIdentity => "VerifyIdentity",
            _ => "Disabled",
        };
        var scheme = tls.Equals("Disabled", StringComparison.OrdinalIgnoreCase) ? "http" : "https";
        var host = request.Host.Contains(':', StringComparison.Ordinal) && !request.Host.StartsWith('[') ? $"[{request.Host}]" : request.Host;
        var uri = new Uri(string.Create(CultureInfo.InvariantCulture, $"{scheme}://{host}:{request.Port}/"));
        var prefix = Option(options, "etcdKeyPrefix") ?? Option(options, "keyPrefix") ?? request.Database ?? string.Empty;
        return new EtcdSettings(uri, tls, Option(options, "etcdCaCertPath"), Option(options, "etcdClientCertPath"), Option(options, "etcdClientKeyPath"), prefix);
    }

    public HttpMessageHandler CreateHandler(int connectTimeoutSeconds)
    {
        var handler = new SocketsHttpHandler
        {
            ConnectTimeout = TimeSpan.FromSeconds(Math.Max(1, connectTimeoutSeconds)),
            PooledConnectionIdleTimeout = TimeSpan.FromMinutes(2),
        };
        if (BaseUri.Scheme != Uri.UriSchemeHttps)
        {
            return handler;
        }

        X509Certificate2? authority = string.IsNullOrEmpty(CaPath) ? null : X509CertificateLoader.LoadCertificateFromFile(CaPath);
        var checkName = TlsMode.Equals("VerifyIdentity", StringComparison.OrdinalIgnoreCase);
        var verify = !TlsMode.Equals("Required", StringComparison.OrdinalIgnoreCase);
        handler.SslOptions.RemoteCertificateValidationCallback = (_, certificate, chain, errors) =>
        {
            // Required encrypts without checking who answers, as the macOS "Required (skip verify)" does.
            if (!verify)
            {
                return true;
            }

            if (checkName && errors.HasFlag(SslPolicyErrors.RemoteCertificateNameMismatch))
            {
                return false;
            }

            if (authority is null || certificate is null)
            {
                return (errors & ~SslPolicyErrors.RemoteCertificateNameMismatch) == SslPolicyErrors.None;
            }

            // A private CA is trusted for this connection only, not added to the machine's store.
            using var custom = new X509Chain();
            custom.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
            custom.ChainPolicy.CustomTrustStore.Add(authority);
            custom.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
            if (chain is not null)
            {
                foreach (var element in chain.ChainElements)
                {
                    custom.ChainPolicy.ExtraStore.Add(element.Certificate);
                }
            }

            return custom.Build(certificate as X509Certificate2 ?? X509CertificateLoader.LoadCertificate(certificate.GetRawCertData()));
        };

        if (!string.IsNullOrEmpty(ClientCertPath) && !string.IsNullOrEmpty(ClientKeyPath))
        {
            // SChannel cannot use a key that lives only in memory, so the PEM pair goes through PKCS#12 first.
            using var pem = X509Certificate2.CreateFromPemFile(ClientCertPath, ClientKeyPath);
            var client = X509CertificateLoader.LoadPkcs12(pem.Export(X509ContentType.Pkcs12), null);
            handler.SslOptions.ClientCertificates = [client];
        }

        return handler;
    }

    private static string? Option(IReadOnlyDictionary<string, string> options, string key) =>
        options.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value) ? value.Trim() : null;
}

/// <summary>
/// The etcd v3 JSON gateway on the client port. It finds which API prefix the server routes (v3, or v3beta and
/// v3alpha on old releases), and signs in with a token when the profile has a user name.
/// </summary>
internal sealed class EtcdClient(HttpClient http, Uri baseUri, string? user, string? password) : IDisposable
{
    internal static readonly string[] Prefixes = ["v3", "v3beta", "v3alpha"];

    private readonly SemaphoreSlim _authLock = new(1, 1);
    private string _prefix = "v3";
    private string? _token;

    public Uri BaseUri => baseUri;

    public string Prefix => _prefix;

    public Uri Endpoint(string path) => new(baseUri, $"{_prefix}/{path}");

    public static byte[] Utf8(string text) => Encoding.UTF8.GetBytes(text);

    public void Dispose() => _authLock.Dispose();

    /// <summary>
    /// The first key past every key that starts with <paramref name="prefix"/>: the last byte below 0xFF is raised by
    /// one and what follows it dropped. A prefix of all 0xFF bytes, or an empty one, reaches the end of the key space.
    /// </summary>
    public static byte[] PrefixEnd(byte[] prefix)
    {
        for (var i = prefix.Length - 1; i >= 0; i--)
        {
            if (prefix[i] < 0xFF)
            {
                var end = prefix[..(i + 1)];
                end[i]++;
                return end;
            }
        }

        return [0];
    }

    public async Task ConnectAsync(CancellationToken cancellationToken)
    {
        await DetectPrefixAsync(cancellationToken);
        if (!string.IsNullOrEmpty(user))
        {
            await AuthenticateAsync(null, cancellationToken);
        }

        await RangeAsync(new EtcdRangeRequest { Key = Utf8("health"), Limit = 1, KeysOnly = true }, cancellationToken);
    }

    public Task<EtcdRangeResponse> RangeAsync(EtcdRangeRequest request, CancellationToken cancellationToken) =>
        PostAsync("kv/range", request, EtcdJsonContext.Default.EtcdRangeRequest, EtcdJsonContext.Default.EtcdRangeResponse, cancellationToken);

    public Task<EtcdPutResponse> PutAsync(EtcdPutRequest request, CancellationToken cancellationToken) =>
        PostAsync("kv/put", request, EtcdJsonContext.Default.EtcdPutRequest, EtcdJsonContext.Default.EtcdPutResponse, cancellationToken);

    public Task<EtcdDeleteRangeResponse> DeleteAsync(EtcdDeleteRangeRequest request, CancellationToken cancellationToken) =>
        PostAsync("kv/deleterange", request, EtcdJsonContext.Default.EtcdDeleteRangeRequest, EtcdJsonContext.Default.EtcdDeleteRangeResponse, cancellationToken);

    public Task<EtcdTxnResponse> TxnAsync(EtcdTxnRequest request, CancellationToken cancellationToken) =>
        PostAsync("kv/txn", request, EtcdJsonContext.Default.EtcdTxnRequest, EtcdJsonContext.Default.EtcdTxnResponse, cancellationToken);

    public Task<EtcdLeaseResponse> LeaseAsync(string action, EtcdLeaseRequest request, CancellationToken cancellationToken) =>
        PostAsync("lease/" + action, request, EtcdJsonContext.Default.EtcdLeaseRequest, EtcdJsonContext.Default.EtcdLeaseResponse, cancellationToken);

    public Task<EtcdLeasesResponse> LeasesAsync(CancellationToken cancellationToken) =>
        PostAsync("lease/leases", new EtcdEmpty(), EtcdJsonContext.Default.EtcdEmpty, EtcdJsonContext.Default.EtcdLeasesResponse, cancellationToken);

    public Task<EtcdMemberListResponse> MembersAsync(CancellationToken cancellationToken) =>
        PostAsync("cluster/member/list", new EtcdEmpty(), EtcdJsonContext.Default.EtcdEmpty, EtcdJsonContext.Default.EtcdMemberListResponse, cancellationToken);

    public Task<EtcdStatusResponse> StatusAsync(CancellationToken cancellationToken) =>
        PostAsync("maintenance/status", new EtcdEmpty(), EtcdJsonContext.Default.EtcdEmpty, EtcdJsonContext.Default.EtcdStatusResponse, cancellationToken);

    public Task<EtcdEmpty> CompactAsync(EtcdCompactionRequest request, CancellationToken cancellationToken) =>
        PostAsync("kv/compaction", request, EtcdJsonContext.Default.EtcdCompactionRequest, EtcdJsonContext.Default.EtcdEmpty, cancellationToken);

    public Task<EtcdAuthResponse> AuthAsync(string path, EtcdAuthRequest request, CancellationToken cancellationToken) =>
        PostAsync("auth/" + path, request, EtcdJsonContext.Default.EtcdAuthRequest, EtcdJsonContext.Default.EtcdAuthResponse, cancellationToken);

    /// <summary>One keep-alive round: the gateway answers a single request line and ends the stream.</summary>
    public async Task<EtcdLeaseResponse> KeepAliveOnceAsync(long leaseId, CancellationToken cancellationToken)
    {
        var body = JsonSerializer.SerializeToUtf8Bytes(new EtcdLeaseRequest { Id = leaseId }, EtcdJsonContext.Default.EtcdLeaseRequest);
        var bytes = await SendAsync("lease/keepalive", body, retry: true, cancellationToken);
        var firstLine = FirstLine(bytes);
        var line = JsonSerializer.Deserialize(firstLine, EtcdJsonContext.Default.EtcdKeepAliveLine);
        return line?.Result ?? throw new EtcdException("etcd sent no keep-alive answer.");
    }

    /// <summary>Collects watch events until the window closes or <paramref name="maxEvents"/> arrive.</summary>
    public async Task<IReadOnlyList<EtcdEvent>> WatchAsync(byte[] key, byte[]? rangeEnd, TimeSpan window, int maxEvents, CancellationToken cancellationToken)
    {
        var body = JsonSerializer.SerializeToUtf8Bytes(
            new EtcdWatchRequest { CreateRequest = new EtcdWatchCreate { Key = key, RangeEnd = rangeEnd } },
            EtcdJsonContext.Default.EtcdWatchRequest);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(window);
        var events = new List<EtcdEvent>();
        try
        {
            using var request = Request("watch", body);
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
            if (!response.IsSuccessStatusCode)
            {
                throw Failure(response.StatusCode, await response.Content.ReadAsByteArrayAsync(cancellationToken));
            }

            await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
            using var reader = new StreamReader(stream, Encoding.UTF8);
            while (events.Count < maxEvents && await reader.ReadLineAsync(timeout.Token) is { } line)
            {
                if (line.Length == 0)
                {
                    continue;
                }

                var parsed = JsonSerializer.Deserialize(line, EtcdJsonContext.Default.EtcdWatchLine);
                events.AddRange(parsed?.Result?.Events ?? []);
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            // The window closing is how a watch ends here; what arrived until then is the answer.
        }

        return events;
    }

    public async Task<string?> GatewayVersionAsync(CancellationToken cancellationToken)
    {
        try
        {
            using var response = await http.GetAsync(new Uri(baseUri, "version"), cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                return null;
            }

            var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
            return JsonSerializer.Deserialize(bytes, EtcdJsonContext.Default.EtcdVersionResponse)?.Etcdserver;
        }
        catch (Exception ex) when (ex is HttpRequestException or JsonException)
        {
            return null;
        }
    }

    public async Task<TResponse> PostAsync<TRequest, TResponse>(
        string path,
        TRequest body,
        JsonTypeInfo<TRequest> requestType,
        JsonTypeInfo<TResponse> responseType,
        CancellationToken cancellationToken)
        where TResponse : new()
    {
        var bytes = await SendAsync(path, JsonSerializer.SerializeToUtf8Bytes(body, requestType), retry: true, cancellationToken);
        try
        {
            return bytes.Length == 0 ? new TResponse() : JsonSerializer.Deserialize(bytes, responseType) ?? new TResponse();
        }
        catch (JsonException ex)
        {
            throw new EtcdException($"etcd returned a response TablePro could not read for {path}.", ex);
        }
    }

    public static EtcdException Failure(HttpStatusCode status, byte[] body)
    {
        EtcdErrorBody? error = null;
        try
        {
            error = body.Length == 0 ? null : JsonSerializer.Deserialize(body, EtcdJsonContext.Default.EtcdErrorBody);
        }
        catch (JsonException)
        {
            // A proxy's error page is reported by status below.
        }

        var message = error?.Message ?? error?.Error;
        if (string.IsNullOrWhiteSpace(message))
        {
            message = string.Create(CultureInfo.InvariantCulture, $"etcd returned HTTP {(int)status}: {Encoding.UTF8.GetString(body, 0, Math.Min(body.Length, 200)).Trim()}");
        }

        return new EtcdException(message, status, error?.Code ?? 0);
    }

    private async Task<byte[]> SendAsync(string path, byte[] body, bool retry, CancellationToken cancellationToken)
    {
        var token = _token;
        using var request = Request(path, body);
        using var response = await http.SendAsync(request, cancellationToken);
        var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
        if (response.IsSuccessStatusCode)
        {
            return bytes;
        }

        var failure = Failure(response.StatusCode, bytes);

        // Tokens expire (five minutes by default with simple tokens); one fresh sign-in and a retry covers that.
        if (retry && !string.IsNullOrEmpty(user) && IsTokenProblem(failure))
        {
            await AuthenticateAsync(token, cancellationToken);
            return await SendAsync(path, body, retry: false, cancellationToken);
        }

        throw failure;
    }

    private HttpRequestMessage Request(string path, byte[] body)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, Endpoint(path)) { Content = new ByteArrayContent(body) };
        request.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/json");
        if (_token is { } token)
        {
            // etcd takes the bare token, with no scheme in front of it.
            request.Headers.TryAddWithoutValidation("Authorization", token);
        }

        return request;
    }

    private static bool IsTokenProblem(EtcdException failure) =>
        failure.StatusCode == HttpStatusCode.Unauthorized
        || failure.Message.Contains("invalid auth token", StringComparison.OrdinalIgnoreCase)
        || failure.Message.Contains("user name is empty", StringComparison.OrdinalIgnoreCase);

    private async Task AuthenticateAsync(string? staleToken, CancellationToken cancellationToken)
    {
        await _authLock.WaitAsync(cancellationToken);
        try
        {
            if (_token is not null && _token != staleToken)
            {
                return;
            }

            _token = null;
            var body = JsonSerializer.SerializeToUtf8Bytes(new EtcdAuthRequest { Name = user, Password = password }, EtcdJsonContext.Default.EtcdAuthRequest);
            using var request = Request("auth/authenticate", body);
            using var response = await http.SendAsync(request, cancellationToken);
            var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                var failure = Failure(response.StatusCode, bytes);

                // A server without authentication accepts every request, so the user name is simply unused.
                if (failure.Message.Contains("authentication is not enabled", StringComparison.OrdinalIgnoreCase))
                {
                    return;
                }

                throw new EtcdException("etcd refused the user name or password: " + failure.Message, failure);
            }

            var parsed = JsonSerializer.Deserialize(bytes, EtcdJsonContext.Default.EtcdAuthResponse);
            _token = string.IsNullOrEmpty(parsed?.Token) ? throw new EtcdException("etcd signed in but returned no token.") : parsed.Token;
        }
        finally
        {
            _authLock.Release();
        }
    }

    private async Task DetectPrefixAsync(CancellationToken cancellationToken)
    {
        var body = JsonSerializer.SerializeToUtf8Bytes(new EtcdRangeRequest { Key = Utf8("health"), Limit = 1, KeysOnly = true }, EtcdJsonContext.Default.EtcdRangeRequest);
        var sawForeign = false;
        foreach (var candidate in Prefixes)
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(baseUri, $"{candidate}/kv/range")) { Content = new ByteArrayContent(body) };
            request.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/json");
            using var response = await http.SendAsync(request, cancellationToken);
            var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
            switch (ClassifyRoute(response.StatusCode, bytes))
            {
                case GatewayRoute.Routed:
                    _prefix = candidate;
                    return;
                case GatewayRoute.NotEtcd:
                    sawForeign = true;
                    break;
            }
        }

        throw new EtcdException(sawForeign
            ? "The server answered but is not an etcd v3 JSON gateway."
            : $"No etcd v3 API found at {baseUri}. Point the connection at the client port, 2379 by default, not the peer port 2380.");
    }

    internal enum GatewayRoute
    {
        Routed,
        NotRouted,
        NotEtcd,
    }

    /// <summary>A 404 means the prefix is not routed; any JSON object, even an auth error, proves the gateway is there.</summary>
    internal static GatewayRoute ClassifyRoute(HttpStatusCode status, byte[] body)
    {
        if (status == HttpStatusCode.NotFound)
        {
            return GatewayRoute.NotRouted;
        }

        try
        {
            using var document = JsonDocument.Parse(body);
            return document.RootElement.ValueKind == JsonValueKind.Object ? GatewayRoute.Routed : GatewayRoute.NotEtcd;
        }
        catch (JsonException)
        {
            return GatewayRoute.NotEtcd;
        }
    }

    private static byte[] FirstLine(byte[] bytes)
    {
        var newline = Array.IndexOf(bytes, (byte)'\n');
        return newline < 0 ? bytes : bytes[..newline];
    }
}
