using System.Buffers;
using System.Net;
using System.Threading.Channels;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Connections;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Net.Http.Headers;
using TablePro.Mcp.Audit;
using TablePro.Mcp.Auth;
using TablePro.Mcp.Protocol;
using TablePro.Mcp.Tools;

namespace TablePro.Mcp;

/// <summary>The port is taken, most likely by another TablePro or a second copy of the app.</summary>
public sealed class McpPortInUseException : IOException
{
    public McpPortInUseException()
    {
    }

    public McpPortInUseException(string message)
        : base(message)
    {
    }

    public McpPortInUseException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    public McpPortInUseException(int port, Exception innerException)
        : base($"Port {port} on 127.0.0.1 is in use.", innerException)
    {
        Port = port;
    }

    public int Port { get; }
}

/// <summary>
/// The MCP server: Streamable HTTP on 127.0.0.1 only, one endpoint, bearer token on every request. The token is the
/// settings page's own or one issued to a paired client. Start it when the user turns it on in preferences and
/// dispose it when they turn it off or the app quits.
/// </summary>
public sealed class McpServer : IAsyncDisposable
{
    // A pairing body is a name, a challenge and a few ids.
    private const int MaxPairingBodyBytes = 16 * 1024;

    // Audit entries wait here for the host's store. Bounded, so a client looping faster than the disk cannot grow the
    // queue without limit; past this the newest entries are dropped from the persisted log (the in-memory ring still
    // shows them).
    private const int AuditQueueCapacity = 10_000;

    private readonly IMcpHost _host;
    private readonly McpProtocolHandler _protocol;
    private readonly McpPairingService _pairing;
    private readonly SemaphoreSlim _lifecycle = new(1, 1);
    private readonly Channel<McpAuditEntry> _auditQueue = Channel.CreateBounded<McpAuditEntry>(new BoundedChannelOptions(AuditQueueCapacity)
    {
        SingleReader = true,
        FullMode = BoundedChannelFullMode.DropWrite,
    });

    private readonly Task _auditWriter;
    private McpAccessToken _token;
    private WebApplication? _app;
    private int _auditPending;

    public McpServer(IMcpHost host, McpAccessToken token, McpServerOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(host);
        ArgumentNullException.ThrowIfNull(token);
        _host = host;
        Options = options ?? new McpServerOptions();
        _token = token;
        AuditLog = new McpAuditLog(Options.AuditCapacity);
        AuditLog.EntryRecorded += (_, entry) =>
        {
            Interlocked.Increment(ref _auditPending);
            if (!_auditQueue.Writer.TryWrite(entry))
            {
                Interlocked.Decrement(ref _auditPending);
            }
        };
        Clients = new McpClientRegistry(host, entry =>
        {
            AuditLog.Record(entry);
            return ValueTask.CompletedTask;
        }, Options.Time);
        _pairing = new McpPairingService(host, Clients, AuditLog, Options, Options.Time);
        _protocol = new McpProtocolHandler(new McpTools(host, Options), AuditLog, Options);
        _auditWriter = Task.Run(PersistAuditAsync);
    }

    public McpServerOptions Options { get; }

    public McpAuditLog AuditLog { get; }

    /// <summary>The paired clients. Revoking here turns a client away from its next request.</summary>
    public McpClientRegistry Clients { get; }

    internal McpPairingService Pairing => _pairing;

    /// <summary>The token clients must present. Store <see cref="McpAccessToken.Value"/> in the credential vault.</summary>
    public McpAccessToken Token => Volatile.Read(ref _token);

    public bool IsRunning => _app is not null;

    /// <summary>The port bound, which differs from <see cref="McpServerOptions.Port"/> when that is 0. Zero when stopped.</summary>
    public int Port { get; private set; }

    /// <summary>The address to paste into a client, such as <c>http://127.0.0.1:23508/mcp</c>. Null when stopped.</summary>
    public Uri? Endpoint => Port == 0 ? null : new Uri($"http://127.0.0.1:{Port}{Options.Path}");

    /// <summary>Clients holding the old token are refused from their next request; nothing restarts.</summary>
    public McpAccessToken RegenerateToken()
    {
        var token = McpAccessToken.Generate();
        Volatile.Write(ref _token, token);
        return token;
    }

    public void ReplaceToken(McpAccessToken token)
    {
        ArgumentNullException.ThrowIfNull(token);
        Volatile.Write(ref _token, token);
    }

    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        await _lifecycle.WaitAsync(cancellationToken);
        try
        {
            if (_app is not null)
            {
                return;
            }

            try
            {
                await Clients.ReloadAsync(cancellationToken);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // A vault or file the host cannot read must not keep the settings token from working; paired clients
                // are refused until it can, and the settings page shows the list as empty.
                System.Diagnostics.Debug.WriteLine(ex.Message);
            }

            var builder = WebApplication.CreateEmptyBuilder(new WebApplicationOptions { ApplicationName = typeof(McpServer).Assembly.GetName().Name });
            builder.WebHost.UseKestrelCore();
            builder.WebHost.ConfigureKestrel(kestrel =>
            {
                kestrel.AddServerHeader = false;
                kestrel.Limits.MaxRequestBodySize = Options.MaxRequestBytes;
                kestrel.Limits.MaxConcurrentConnections = Options.MaxConnections;
                kestrel.Limits.RequestHeadersTimeout = TimeSpan.FromSeconds(10);

                // Loopback alone: any program on this machine can reach it, nothing on the network can.
                kestrel.Listen(IPAddress.Loopback, Options.Port);
            });

            var app = builder.Build();
            app.Run(HandleAsync);
            try
            {
                await app.StartAsync(cancellationToken);
            }
            catch (Exception ex) when (ex is AddressInUseException || ex.InnerException is AddressInUseException)
            {
                await app.DisposeAsync();
                throw new McpPortInUseException(Options.Port, ex);
            }

            Port = BoundPort(app) ?? Options.Port;
            _app = app;
        }
        finally
        {
            _lifecycle.Release();
        }
    }

    /// <summary>Stops listening and returns once the port is free again, so a restart on the same port can bind it.</summary>
    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        await _lifecycle.WaitAsync(cancellationToken);
        try
        {
            if (_app is not { } app)
            {
                return;
            }

            _app = null;
            Port = 0;
            try
            {
                await app.StopAsync(cancellationToken);
            }
            finally
            {
                await app.DisposeAsync();
            }
        }
        finally
        {
            _lifecycle.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync(CancellationToken.None);
        _auditQueue.Writer.TryComplete();
        try
        {
            // The entries of the last calls still reach the store, unless it hangs.
            await _auditWriter.WaitAsync(TimeSpan.FromSeconds(5));
        }
        catch (TimeoutException)
        {
        }

        Clients.Dispose();
        _lifecycle.Dispose();
    }

    /// <summary>Waits until every audit entry recorded so far has reached the host.</summary>
    internal async Task FlushAuditAsync(CancellationToken cancellationToken = default)
    {
        while (Volatile.Read(ref _auditPending) > 0)
        {
            await Task.Delay(5, cancellationToken);
        }
    }

    private async Task PersistAuditAsync()
    {
        await foreach (var entry in _auditQueue.Reader.ReadAllAsync())
        {
            try
            {
                await _host.RecordAuditAsync(entry, CancellationToken.None);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // The host's store fails however its disk does; the in-memory log still has the entry, and the next
                // one is tried as usual.
                System.Diagnostics.Debug.WriteLine(ex.Message);
            }
            finally
            {
                Interlocked.Decrement(ref _auditPending);
            }
        }
    }

    private static int? BoundPort(WebApplication app)
    {
        foreach (var address in app.Urls)
        {
            if (Uri.TryCreate(address, UriKind.Absolute, out var uri))
            {
                return uri.Port;
            }
        }

        return null;
    }

    private async Task HandleAsync(HttpContext context)
    {
        var request = context.Request;
        var response = context.Response;
        var path = request.Path.Value;
        var pairing = string.Equals(path, McpPairingService.PairPath, StringComparison.Ordinal)
            || string.Equals(path, McpPairingService.ExchangePath, StringComparison.Ordinal);

        if (!pairing && !string.Equals(path, Options.Path, StringComparison.Ordinal))
        {
            await Plain(response, StatusCodes.Status404NotFound, "Not found");
            return;
        }

        // A web page can make the browser reach 127.0.0.1 under a name it controls (DNS rebinding), or post from
        // its own origin. Neither carries a loopback Host or Origin. The pairing endpoints need this most: without it
        // any page the user visits could raise a pairing prompt.
        if (!IsLoopbackHost(request.Host.Host) || (request.Headers.Origin.Count > 0 && !IsLoopbackOrigin(request.Headers.Origin.ToString())))
        {
            await Plain(response, StatusCodes.Status403Forbidden, "Forbidden origin");
            return;
        }

        // The token is checked before anything reads the body. The pairing endpoints are how a client gets one.
        var principal = McpPrincipal.Owner;
        if (!pairing)
        {
            var header = request.Headers.Authorization.Count == 1 ? request.Headers.Authorization[0] : null;
            if (await AuthenticateAsync(header, context.RequestAborted) is { } caller)
            {
                principal = caller;
            }
            else
            {
                response.Headers.WWWAuthenticate = "Bearer realm=\"TablePro\"";
                await Plain(response, StatusCodes.Status401Unauthorized, "A TablePro access token is required");
                return;
            }
        }

        if (!HttpMethods.IsPost(request.Method))
        {
            // No server-to-client stream and no session to delete: the server is stateless.
            response.Headers.Allow = "POST";
            await Plain(response, StatusCodes.Status405MethodNotAllowed, "Use POST");
            return;
        }

        if (!MediaTypeHeaderValue.TryParse(request.ContentType, out var contentType) || !contentType.MediaType.Equals("application/json", StringComparison.OrdinalIgnoreCase))
        {
            await Plain(response, StatusCodes.Status415UnsupportedMediaType, "Content-Type must be application/json");
            return;
        }

        var declaredVersion = request.Headers["MCP-Protocol-Version"].ToString();
        if (!pairing && declaredVersion.Length > 0 && !McpProtocolVersions.IsSupported(declaredVersion))
        {
            await Plain(response, StatusCodes.Status400BadRequest, $"Unsupported MCP-Protocol-Version {declaredVersion}");
            return;
        }

        var limit = pairing ? MaxPairingBodyBytes : Options.MaxRequestBytes;
        if (request.ContentLength > limit)
        {
            await Plain(response, StatusCodes.Status413PayloadTooLarge, "The request is too large");
            return;
        }

        var buffer = ArrayPool<byte>.Shared.Rent((int)Math.Min(request.ContentLength ?? 16 * 1024, limit) + 1);
        try
        {
            var length = 0;
            while (true)
            {
                if (length == buffer.Length)
                {
                    if (buffer.Length > limit)
                    {
                        await Plain(response, StatusCodes.Status413PayloadTooLarge, "The request is too large");
                        return;
                    }

                    var larger = ArrayPool<byte>.Shared.Rent(Math.Min(buffer.Length * 2, limit + 1));
                    Buffer.BlockCopy(buffer, 0, larger, 0, length);
                    ArrayPool<byte>.Shared.Return(buffer);
                    buffer = larger;
                }

                int read;
                try
                {
                    read = await request.Body.ReadAsync(buffer.AsMemory(length), context.RequestAborted);
                }
                catch (Microsoft.AspNetCore.Http.BadHttpRequestException ex) when (ex.StatusCode == StatusCodes.Status413PayloadTooLarge)
                {
                    await Plain(response, StatusCodes.Status413PayloadTooLarge, "The request is too large");
                    return;
                }

                if (read == 0)
                {
                    break;
                }

                length += read;
                if (length > limit)
                {
                    await Plain(response, StatusCodes.Status413PayloadTooLarge, "The request is too large");
                    return;
                }
            }

            if (pairing)
            {
                var body = buffer.AsMemory(0, length);
                var reply = string.Equals(path, McpPairingService.PairPath, StringComparison.Ordinal)
                    ? await _pairing.PairAsync(body, context.RequestAborted)
                    : await _pairing.ExchangeAsync(body);
                response.StatusCode = reply.Status;
                response.ContentType = "application/json";

                // The exchange answer carries a token; nothing on the way should keep a copy.
                response.Headers.CacheControl = "no-store";
                if (reply.RetryAfter is { } retry)
                {
                    response.Headers.RetryAfter = ((int)Math.Ceiling(retry.TotalSeconds)).ToString(System.Globalization.CultureInfo.InvariantCulture);
                }

                response.ContentLength = reply.Json.Length;
                await response.Body.WriteAsync(reply.Json, context.RequestAborted);
                return;
            }

            var answer = await _protocol.HandleAsync(buffer.AsMemory(0, length), principal, context.RequestAborted);
            if (answer is null)
            {
                response.StatusCode = StatusCodes.Status202Accepted;
                return;
            }

            response.StatusCode = StatusCodes.Status200OK;
            response.ContentType = "application/json";
            response.ContentLength = answer.Length;
            await response.Body.WriteAsync(answer, context.RequestAborted);
        }
        catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested)
        {
            // The client went away; there is no one to answer.
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }
    }

    /// <summary>The caller a header presents: the settings token, an active paired client, or null with the refusal logged.</summary>
    private async ValueTask<McpPrincipal?> AuthenticateAsync(string? header, CancellationToken cancellationToken)
    {
        if (Token.Authorizes(header))
        {
            return McpPrincipal.Owner;
        }

        var (grant, failure) = await Clients.AuthenticateAsync(header, cancellationToken);
        if (failure is null && grant is not null)
        {
            return McpPrincipal.For(grant);
        }

        var message = failure switch
        {
            McpAuthFailure.Revoked => "A revoked client's token was refused.",
            McpAuthFailure.Expired => "An expired client token was refused.",
            _ => "A request without a valid access token was refused.",
        };
        AuditLog.Record(new McpAuditEntry(Options.Time.GetLocalNow(), "auth.failure", null, null, McpAuditOutcome.Unauthorized, "unauthorized", message, null, TimeSpan.Zero, grant?.Id, grant?.Name, McpAuditCategory.Auth));
        return null;
    }

    private static bool IsLoopbackHost(string host) =>
        host.Equals("127.0.0.1", StringComparison.Ordinal)
        || host.Equals("localhost", StringComparison.OrdinalIgnoreCase)
        || host.Equals("[::1]", StringComparison.Ordinal);

    private static bool IsLoopbackOrigin(string origin) =>
        Uri.TryCreate(origin, UriKind.Absolute, out var uri) && (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps) && IsLoopbackHost(uri.Host);

    private static async Task Plain(HttpResponse response, int status, string text)
    {
        response.StatusCode = status;
        response.ContentType = "text/plain; charset=utf-8";
        await response.WriteAsync(text);
    }
}
