using System.Buffers.Binary;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text;
using TablePro.Core.Connections;

namespace TablePro.Ssh;

/// <summary>
/// Opens a connection through a proxy on an already connected stream: SOCKS5 (RFC 1928) with optional user and
/// password (RFC 1929), or HTTP <c>CONNECT</c>. The target travels as a name, so the proxy resolves it the way the
/// macOS app relies on, and a host only the proxy's network knows still works.
/// </summary>
internal static class ProxyHandshake
{
    private const byte SocksVersion = 5;
    private const byte NoAuthentication = 0;
    private const byte UserPassword = 2;
    private const byte NoAcceptableMethod = 0xFF;
    private const int MaxHttpHeaderBytes = 16 * 1024;

    public static Task ConnectAsync(Stream stream, ProxyProtocol protocol, string host, int port, string? user, string? password, CancellationToken cancellationToken) =>
        protocol == ProxyProtocol.HttpConnect
            ? ConnectHttpAsync(stream, host, port, user, password, cancellationToken)
            : ConnectSocks5Async(stream, host, port, user, password, cancellationToken);

    public static async Task ConnectSocks5Async(Stream stream, string host, int port, string? user, string? password, CancellationToken cancellationToken)
    {
        var authenticates = !string.IsNullOrEmpty(user);
        byte[] greeting = authenticates ? [SocksVersion, 2, NoAuthentication, UserPassword] : [SocksVersion, 1, NoAuthentication];
        await stream.WriteAsync(greeting, cancellationToken);

        var choice = await ReadExactlyAsync(stream, 2, cancellationToken);
        if (choice[0] != SocksVersion)
        {
            throw new TunnelException(TunnelFailureKind.ProxyRefused, "The proxy did not answer as a SOCKS5 proxy.");
        }

        switch (choice[1])
        {
            case NoAuthentication:
                break;
            case UserPassword when authenticates:
                await stream.WriteAsync(UserPasswordRequest(user!, password ?? string.Empty), cancellationToken);
                var status = await ReadExactlyAsync(stream, 2, cancellationToken);
                if (status[1] != 0)
                {
                    throw new TunnelException(TunnelFailureKind.ProxyAuthenticationFailed, "The proxy rejected the user name and password.");
                }

                break;
            case NoAcceptableMethod or UserPassword:
                throw new TunnelException(
                    TunnelFailureKind.ProxyAuthenticationFailed,
                    authenticates ? "The proxy accepts none of the sign-in methods offered." : "The proxy requires a user name and password.");
            default:
                throw new TunnelException(TunnelFailureKind.ProxyRefused, "The proxy asked for a sign-in method TablePro does not support.");
        }

        await stream.WriteAsync(ConnectRequest(host, port), cancellationToken);
        var reply = await ReadExactlyAsync(stream, 4, cancellationToken);
        if (reply[1] != 0)
        {
            throw new TunnelException(TunnelFailureKind.ProxyRefused, $"The proxy could not connect to {host}:{port}: {ReplyMessage(reply[1])}.");
        }

        // The bound address the proxy reports is of no use to a client; it is read only to reach the payload.
        var remaining = reply[3] switch
        {
            1 => 4 + 2,
            4 => 16 + 2,
            3 => (await ReadExactlyAsync(stream, 1, cancellationToken))[0] + 2,
            _ => throw new TunnelException(TunnelFailureKind.ProxyRefused, "The proxy sent a reply TablePro cannot read."),
        };
        await ReadExactlyAsync(stream, remaining, cancellationToken);
    }

    public static async Task ConnectHttpAsync(Stream stream, string host, int port, string? user, string? password, CancellationToken cancellationToken)
    {
        await stream.WriteAsync(Encoding.ASCII.GetBytes(HttpConnectRequest(host, port, user, password)), cancellationToken);

        // Read one byte at a time up to the blank line, so nothing the database sends after the headers is consumed.
        var header = new List<byte>(256);
        var one = new byte[1];
        while (!EndsWithBlankLine(header))
        {
            if (header.Count >= MaxHttpHeaderBytes)
            {
                throw new TunnelException(TunnelFailureKind.ProxyRefused, "The proxy's reply was too long.");
            }

            if (await stream.ReadAsync(one, cancellationToken) == 0)
            {
                throw new TunnelException(TunnelFailureKind.ProxyRefused, "The proxy closed the connection.");
            }

            header.Add(one[0]);
        }

        var statusLine = Encoding.ASCII.GetString([.. header]).Split("\r\n", 2)[0];
        var parts = statusLine.Split(' ', 3);
        if (parts.Length < 2 || !parts[0].StartsWith("HTTP/", StringComparison.Ordinal) || !int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var code))
        {
            throw new TunnelException(TunnelFailureKind.ProxyRefused, "The proxy did not answer as an HTTP proxy.");
        }

        if (code == 407)
        {
            throw new TunnelException(TunnelFailureKind.ProxyAuthenticationFailed, "The proxy rejected the user name and password.");
        }

        if (code is < 200 or > 299)
        {
            throw new TunnelException(TunnelFailureKind.ProxyRefused, $"The proxy could not connect to {host}:{port}: {statusLine}.");
        }
    }

    internal static byte[] UserPasswordRequest(string user, string password)
    {
        var name = Encoding.UTF8.GetBytes(user);
        var secret = Encoding.UTF8.GetBytes(password);
        if (name.Length > 255 || secret.Length > 255)
        {
            throw new TunnelException(TunnelFailureKind.InvalidSettings, "A SOCKS5 user name and password are at most 255 bytes each.");
        }

        var request = new byte[3 + name.Length + secret.Length];
        request[0] = 1;
        request[1] = (byte)name.Length;
        name.CopyTo(request, 2);
        request[2 + name.Length] = (byte)secret.Length;
        secret.CopyTo(request, 3 + name.Length);
        return request;
    }

    internal static byte[] ConnectRequest(string host, int port)
    {
        byte[] address;
        byte type;
        if (IPAddress.TryParse(host, out var ip))
        {
            type = ip.AddressFamily == AddressFamily.InterNetworkV6 ? (byte)4 : (byte)1;
            address = ip.GetAddressBytes();
        }
        else
        {
            var name = Encoding.ASCII.GetBytes(IdnHost(host));
            if (name.Length is 0 or > 255)
            {
                throw new TunnelException(TunnelFailureKind.InvalidSettings, $"The host name {host} is too long for a SOCKS5 proxy.");
            }

            type = 3;
            address = [(byte)name.Length, .. name];
        }

        var request = new byte[4 + address.Length + 2];
        request[0] = SocksVersion;
        request[1] = 1;
        request[3] = type;
        address.CopyTo(request, 4);
        BinaryPrimitives.WriteUInt16BigEndian(request.AsSpan(4 + address.Length), checked((ushort)port));
        return request;
    }

    internal static string HttpConnectRequest(string host, int port, string? user, string? password)
    {
        var authority = (IPAddress.TryParse(host, out var ip) && ip.AddressFamily == AddressFamily.InterNetworkV6 ? $"[{host}]" : host)
            + ":" + port.ToString(CultureInfo.InvariantCulture);
        var builder = new StringBuilder()
            .Append("CONNECT ").Append(authority).Append(" HTTP/1.1\r\n")
            .Append("Host: ").Append(authority).Append("\r\n");
        if (!string.IsNullOrEmpty(user))
        {
            var token = Convert.ToBase64String(Encoding.UTF8.GetBytes(user + ":" + (password ?? string.Empty)));
            builder.Append("Proxy-Authorization: Basic ").Append(token).Append("\r\n");
        }

        return builder.Append("\r\n").ToString();
    }

    internal static string ReplyMessage(byte code) => code switch
    {
        1 => "general failure",
        2 => "not allowed by the proxy's rules",
        3 => "network unreachable",
        4 => "host unreachable",
        5 => "connection refused",
        6 => "timed out",
        7 => "command not supported",
        8 => "address type not supported",
        _ => "error " + code.ToString(CultureInfo.InvariantCulture),
    };

    private static string IdnHost(string host)
    {
        try
        {
            return new IdnMapping().GetAscii(host);
        }
        catch (ArgumentException)
        {
            return host;
        }
    }

    private static bool EndsWithBlankLine(List<byte> header) =>
        header.Count >= 4 && header[^4] == '\r' && header[^3] == '\n' && header[^2] == '\r' && header[^1] == '\n';

    private static async Task<byte[]> ReadExactlyAsync(Stream stream, int count, CancellationToken cancellationToken)
    {
        var buffer = new byte[count];
        try
        {
            await stream.ReadExactlyAsync(buffer, cancellationToken);
        }
        catch (EndOfStreamException ex)
        {
            throw new TunnelException(TunnelFailureKind.ProxyRefused, "The proxy closed the connection.", innerException: ex);
        }

        return buffer;
    }
}
