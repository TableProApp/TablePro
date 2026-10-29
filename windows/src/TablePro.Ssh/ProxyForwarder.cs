using System.Net;
using System.Net.Sockets;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Ssh.Localization;

namespace TablePro.Ssh;

/// <summary>
/// A loopback listener that carries each connection the driver opens through the proxy to the database. Drivers
/// differ in what proxy support they have, and the forwarder gives every engine the same one, as the macOS app's
/// <c>SOCKSProxyManager</c> does.
/// </summary>
public sealed class ProxyForwarder : IConnectionTunnel
{
    private const int RelayBufferSize = 64 * 1024;

    private readonly TcpListener _listener;
    private readonly ProxySettings _settings;
    private readonly string? _password;
    private readonly string _targetHost;
    private readonly int _targetPort;
    private readonly TimeSpan _connectTimeout;
    private readonly CancellationTokenSource _stopping = new();
    private readonly StderrLog _log = new();
    private readonly Task _acceptLoop;
    private int _disposed;

    private ProxyForwarder(TcpListener listener, ProxySettings settings, string? password, string targetHost, int targetPort, TimeSpan connectTimeout, ConnectionRequest request)
    {
        _listener = listener;
        _settings = settings;
        _password = password;
        _targetHost = targetHost;
        _targetPort = targetPort;
        _connectTimeout = connectTimeout;
        LocalPort = ((IPEndPoint)listener.LocalEndpoint).Port;
        Request = request with { Host = SshArguments.LoopbackAddress, Port = LocalPort };
        _acceptLoop = AcceptLoopAsync();
    }

    public ConnectionRequest Request { get; }

    public int LocalPort { get; }

    public bool IsAlive => Volatile.Read(ref _disposed) == 0 && !_acceptLoop.IsCompleted;

    public string Diagnostics => _log.ToString();

    /// <summary>
    /// Checks the proxy and the credentials with one connection to the database, then starts listening. A bad proxy
    /// fails here with a message about the proxy, instead of later as a vague driver timeout.
    /// </summary>
    /// <param name="request">The request whose Host and Port the proxy connects to.</param>
    /// <param name="settings">The proxy.</param>
    /// <param name="password">The proxy password, or null without authentication.</param>
    /// <param name="connectTimeout">The longest wait for the proxy and the database to answer, per connection.</param>
    /// <param name="cancellationToken">Stops the check.</param>
    public static async Task<ProxyForwarder> StartAsync(ConnectionRequest request, ProxySettings settings, string? password, TimeSpan connectTimeout, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(settings);
        if (string.IsNullOrWhiteSpace(settings.Host) || !ConnectionTransports.IsValidPort(settings.Port))
        {
            throw new TunnelException(TunnelFailureKind.InvalidSettings, SshStrings.Get("Tunnel/ProxyIncomplete"));
        }

        var probe = await ConnectThroughProxyAsync(settings, password, request.Host, request.Port, connectTimeout, cancellationToken);
        probe.Dispose();

        var listener = new TcpListener(IPAddress.Loopback, 0);
        try
        {
            listener.Start();
        }
        catch (SocketException ex)
        {
            listener.Dispose();
            throw new TunnelException(TunnelFailureKind.LocalPortUnavailable, SshStrings.Format("Tunnel/ProxyLocalPortFailed", ex.Message), innerException: ex);
        }

        return new ProxyForwarder(listener, settings, password, request.Host, request.Port, connectTimeout, request);
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }

        await _stopping.CancelAsync();
        _listener.Stop();
        try
        {
            await _acceptLoop;
        }
        catch (Exception ex) when (ex is OperationCanceledException or SocketException or ObjectDisposedException)
        {
        }

        _listener.Dispose();
        _stopping.Dispose();
    }

    internal static async Task<Socket> ConnectThroughProxyAsync(ProxySettings settings, string? password, string host, int port, TimeSpan timeout, CancellationToken cancellationToken)
    {
        using var attempt = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        attempt.CancelAfter(timeout);
        var socket = new Socket(SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
        var proxy = $"{settings.Host}:{settings.Port}";
        try
        {
            try
            {
                await socket.ConnectAsync(settings.Host.Trim(), settings.Port, attempt.Token);
            }
            catch (SocketException ex)
            {
                throw new TunnelException(TunnelFailureKind.ProxyUnreachable, SshStrings.Format("Tunnel/ProxyUnreachable", proxy, ex.Message), innerException: ex);
            }

            var stream = new NetworkStream(socket, ownsSocket: false);
            await using (stream)
            {
                await ProxyHandshake.ConnectAsync(stream, settings.Protocol, host, port, settings.Username, password, attempt.Token);
            }

            return socket;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            socket.Dispose();
            throw new TunnelException(
                TunnelFailureKind.ProxyUnreachable,
                SshStrings.Format("Tunnel/ProxyTimedOut", proxy));
        }
        catch (IOException ex)
        {
            socket.Dispose();
            throw new TunnelException(TunnelFailureKind.ProxyRefused, SshStrings.Format("Tunnel/ProxyConnectFailed", proxy, ex.Message), innerException: ex);
        }
        catch
        {
            socket.Dispose();
            throw;
        }
    }

    private async Task AcceptLoopAsync()
    {
        while (!_stopping.IsCancellationRequested)
        {
            Socket client;
            try
            {
                client = await _listener.AcceptSocketAsync(_stopping.Token);
            }
            catch (Exception ex) when (ex is OperationCanceledException or ObjectDisposedException || _stopping.IsCancellationRequested)
            {
                return;
            }
            catch (SocketException ex) when (ex.SocketErrorCode == SocketError.ConnectionReset)
            {
                // A client that gave up before the accept finished; the listener itself is fine.
                continue;
            }

            client.NoDelay = true;
            _ = RelayAsync(client);
        }
    }

    private async Task RelayAsync(Socket client)
    {
        Socket? upstream = null;
        try
        {
            upstream = await ConnectThroughProxyAsync(_settings, _password, _targetHost, _targetPort, _connectTimeout, _stopping.Token);
            await Task.WhenAll(PumpAsync(client, upstream), PumpAsync(upstream, client));
        }
        catch (Exception ex) when (ex is TunnelException or SocketException or IOException or OperationCanceledException or ObjectDisposedException)
        {
            if (ex is TunnelException)
            {
                _log.Append(ex.Message);
            }
        }
        finally
        {
            client.Dispose();
            upstream?.Dispose();
        }
    }

    /// <summary>Copies one direction and passes the end of the stream on, so a half-closed connection stays half-closed.</summary>
    private async Task PumpAsync(Socket from, Socket to)
    {
        var buffer = new byte[RelayBufferSize];
        try
        {
            while (true)
            {
                var read = await from.ReceiveAsync(buffer, SocketFlags.None, _stopping.Token);
                if (read == 0)
                {
                    break;
                }

                await to.SendAsync(buffer.AsMemory(0, read), SocketFlags.None, _stopping.Token);
            }

            to.Shutdown(SocketShutdown.Send);
        }
        catch (SocketException)
        {
            // One side reset; closing both in RelayAsync ends the other direction too.
            from.Dispose();
            to.Dispose();
        }
    }
}
