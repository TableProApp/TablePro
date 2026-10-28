using System.Globalization;

namespace TablePro.Storage.Connections;

/// <summary>One hop of <c>SshTunnelSettings.JumpHosts</c>, written as OpenSSH's <c>[user@]host[:port]</c>.</summary>
internal sealed record JumpHostSpec(string? User, string Host, int? Port)
{
    public static IReadOnlyList<JumpHostSpec> Parse(string? jumpHosts)
    {
        if (string.IsNullOrWhiteSpace(jumpHosts))
        {
            return [];
        }

        var result = new List<JumpHostSpec>();
        foreach (var raw in jumpHosts.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var rest = raw;
            string? user = null;
            var at = rest.LastIndexOf('@');
            if (at > 0)
            {
                user = rest[..at];
                rest = rest[(at + 1)..];
            }

            int? port = null;
            string host;
            if (rest.StartsWith('['))
            {
                var close = rest.IndexOf(']', StringComparison.Ordinal);
                host = close > 0 ? rest[1..close] : rest.Trim('[', ']');
                if (close > 0 && close + 1 < rest.Length && rest[close + 1] == ':' && int.TryParse(rest.AsSpan(close + 2), NumberStyles.None, CultureInfo.InvariantCulture, out var bracketPort))
                {
                    port = bracketPort;
                }
            }
            else
            {
                var colon = rest.LastIndexOf(':');
                if (colon > 0 && rest.IndexOf(':', StringComparison.Ordinal) == colon && int.TryParse(rest.AsSpan(colon + 1), NumberStyles.None, CultureInfo.InvariantCulture, out var parsedPort))
                {
                    host = rest[..colon];
                    port = parsedPort;
                }
                else
                {
                    host = rest;
                }
            }

            if (host.Length > 0)
            {
                result.Add(new JumpHostSpec(user, host, port));
            }
        }

        return result;
    }

    public override string ToString()
    {
        var host = Host.Contains(':', StringComparison.Ordinal) ? "[" + Host + "]" : Host;
        var prefix = string.IsNullOrEmpty(User) ? string.Empty : User + "@";
        return Port is { } port and not 22
            ? string.Create(CultureInfo.InvariantCulture, $"{prefix}{host}:{port}")
            : prefix + host;
    }
}
