using System.Net;
using System.Net.Sockets;

namespace TablePro.Ssh;

internal static class FreePort
{
    /// <summary>
    /// Asks the OS for an unused loopback port. Another process can take it before ssh binds; ssh then exits with a
    /// bind error under ExitOnForwardFailure and the factory retries with a fresh port.
    /// </summary>
    public static int Find()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        try
        {
            return ((IPEndPoint)listener.LocalEndpoint).Port;
        }
        finally
        {
            listener.Stop();
        }
    }

    /// <summary>True once something accepts TCP connections on the loopback port.</summary>
    public static async Task<bool> AcceptsConnectionsAsync(int port, TimeSpan attemptTimeout, CancellationToken cancellationToken)
    {
        using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
        using var attempt = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        attempt.CancelAfter(attemptTimeout);
        try
        {
            await socket.ConnectAsync(IPAddress.Loopback, port, attempt.Token);
            return true;
        }
        catch (SocketException)
        {
            return false;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return false;
        }
    }
}
