using System.Globalization;
using TablePro.Core.Connections;

namespace TablePro.Ssh;

/// <summary>Builds the ssh.exe command line for one local forward. Pure, so tests can pin every option.</summary>
internal static class SshArguments
{
    public const string LoopbackAddress = "127.0.0.1";

    /// <param name="settings">The hop the user configured.</param>
    /// <param name="remoteHost">The database host as the SSH server resolves it.</param>
    /// <param name="remotePort">The database port.</param>
    /// <param name="localPort">The loopback port the forward listens on.</param>
    /// <param name="connectTimeoutSeconds">How long ssh waits for the SSH server's TCP handshake.</param>
    /// <param name="serverAliveIntervalSeconds">Keepalive period, so a dead link is noticed instead of hanging queries.</param>
    /// <param name="answersPrompts">True when a secret is handed to ssh through the askpass helper.</param>
    public static IReadOnlyList<string> Build(
        SshTunnelSettings settings,
        string remoteHost,
        int remotePort,
        int localPort,
        int connectTimeoutSeconds,
        int serverAliveIntervalSeconds,
        bool answersPrompts)
    {
        ArgumentNullException.ThrowIfNull(settings);
        RequireSafe(settings.Host, "SSH host");
        RequireSafe(remoteHost, "database host");
        if (settings.Username is { Length: > 0 } user)
        {
            RequireSafe(user, "SSH user");
        }

        ArgumentOutOfRangeException.ThrowIfLessThan(remotePort, 1);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(remotePort, 65535);
        ArgumentOutOfRangeException.ThrowIfLessThan(localPort, 1);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(localPort, 65535);

        var args = new List<string>(40)
        {
            // No remote command, no TTY and no stdin: the process exists only to carry the forward.
            "-N",
            "-T",
            "-n",
        };

        Option(args, "ExitOnForwardFailure=yes");

        // Without a secret to give, a prompt could only hang until the timeout; batch mode makes ssh fail at once.
        Option(args, answersPrompts ? "BatchMode=no" : "BatchMode=yes");
        Option(args, "StrictHostKeyChecking=accept-new");
        Option(args, Invariant($"ConnectTimeout={Math.Max(1, connectTimeoutSeconds)}"));
        Option(args, Invariant($"ServerAliveInterval={Math.Max(1, serverAliveIntervalSeconds)}"));
        Option(args, "ServerAliveCountMax=3");
        Option(args, "ForwardAgent=no");
        Option(args, "ForwardX11=no");
        Option(args, "PermitLocalCommand=no");

        args.Add("-L");
        args.Add(Invariant($"{LoopbackAddress}:{localPort}:{Bracket(remoteHost)}:{remotePort}"));

        switch (settings.AuthMethod)
        {
            case SshAuthMethod.PrivateKey when !string.IsNullOrWhiteSpace(settings.PrivateKeyPath):
                args.Add("-i");
                args.Add(settings.PrivateKeyPath);

                // ssh offers the agent's keys before a file-only key, and MaxAuthTries can end the login first (Linux ADR 0019).
                Option(args, "IdentitiesOnly=yes");
                break;
            case SshAuthMethod.Password:
                Option(args, "PreferredAuthentications=password,keyboard-interactive,publickey");

                // The helper always gives the same answer, so a second prompt only means the password was wrong.
                Option(args, "NumberOfPasswordPrompts=1");
                break;
        }

        if (NormalizeJumpHosts(settings.JumpHosts) is { } jumps)
        {
            args.Add("-J");
            args.Add(jumps);
        }

        if (settings.Port is > 0 and <= 65535)
        {
            args.Add("-p");
            args.Add(settings.Port.ToString(CultureInfo.InvariantCulture));
        }

        if (!string.IsNullOrEmpty(settings.Username))
        {
            args.Add("-l");
            args.Add(settings.Username);
        }

        // Ends option parsing, so a host that slipped past validation still cannot be read as a flag.
        args.Add("--");
        args.Add(settings.Host.Trim());
        return args;
    }

    /// <summary>Trims each hop and drops empty ones; null when nothing is left.</summary>
    internal static string? NormalizeJumpHosts(string? jumpHosts)
    {
        if (string.IsNullOrWhiteSpace(jumpHosts))
        {
            return null;
        }

        var hops = jumpHosts.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        foreach (var hop in hops)
        {
            RequireSafe(hop, "jump host");
        }

        return hops.Length == 0 ? null : string.Join(',', hops);
    }

    private static void Option(List<string> args, string option)
    {
        args.Add("-o");
        args.Add(option);
    }

    private static string Bracket(string host)
    {
        host = host.Trim();
        return host.Contains(':', StringComparison.Ordinal) && !host.StartsWith('[') ? "[" + host + "]" : host;
    }

    /// <summary>
    /// Rejects a leading dash and whitespace or control characters. ssh would read a leading dash as an option, and a
    /// jump host is pasted into the command line of a second ssh it starts.
    /// </summary>
    private static void RequireSafe(string? value, string what)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new ArgumentException($"The {what} is empty.");
        }

        var trimmed = value.Trim();
        if (trimmed.StartsWith('-') || trimmed.Any(c => char.IsWhiteSpace(c) || char.IsControl(c) || c is '\'' or '"' or '`' or ';' or '|' or '&' or '$'))
        {
            throw new ArgumentException($"The {what} \"{value}\" contains characters ssh does not accept.");
        }
    }

    private static string Invariant(FormattableString value) => FormattableString.Invariant(value);
}
