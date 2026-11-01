using System.Globalization;
using System.Text;
using TablePro.Core.Localization;

namespace TablePro.Core.Connections;

/// <summary>The program and argument list a tunnel command runs, passed to the OS as a list and never through a shell.</summary>
public sealed record TunnelCommandInvocation(string Executable, IReadOnlyList<string> Arguments);

/// <summary>
/// Turns <see cref="TunnelCommandSettings"/> into a program and its arguments. A custom command is split into
/// arguments first and the placeholders are filled in afterwards, one argument at a time, so a host name can never
/// add an argument or reach a shell. The placeholders are the macOS app's, so a command imported from a Mac runs
/// unchanged: <c>{port}</c> (or <c>{localPort}</c>) is the local port the app chose, <c>{host}</c> and
/// <c>{remotePort}</c> are where the database listens.
/// </summary>
public static class TunnelCommandLine
{
    public const string LocalPortPlaceholder = "{port}";
    public const string LocalPortAlias = "{localPort}";
    public const string HostPlaceholder = "{host}";
    public const string RemotePortPlaceholder = "{remotePort}";

    public const string KubectlExecutable = "kubectl";
    public const string AwsExecutable = "aws";

    /// <summary>
    /// Splits a command line the way a Windows user writes one. Whitespace separates arguments. Double quotes group,
    /// and inside them <c>\"</c> is a literal quote. Single quotes group with no escapes at all. A backslash anywhere
    /// else is literal, so <c>C:\Tools\kubectl.exe</c> needs no quoting.
    /// </summary>
    /// <exception cref="FormatException">A quote is left open.</exception>
    public static IReadOnlyList<string> Tokenize(string commandLine)
    {
        ArgumentNullException.ThrowIfNull(commandLine);
        var tokens = new List<string>();
        var current = new StringBuilder();
        var inToken = false;
        char? quote = null;
        for (var i = 0; i < commandLine.Length; i++)
        {
            var c = commandLine[i];
            if (quote == '\'')
            {
                if (c == '\'')
                {
                    quote = null;
                }
                else
                {
                    current.Append(c);
                }

                continue;
            }

            if (c == '\\' && i + 1 < commandLine.Length && commandLine[i + 1] == '"')
            {
                current.Append('"');
                inToken = true;
                i++;
                continue;
            }

            if (quote == '"')
            {
                if (c == '"')
                {
                    quote = null;
                }
                else
                {
                    current.Append(c);
                }

                continue;
            }

            if (c is '"' or '\'')
            {
                quote = c;
                inToken = true;
            }
            else if (char.IsWhiteSpace(c))
            {
                if (inToken)
                {
                    tokens.Add(current.ToString());
                    current.Clear();
                    inToken = false;
                }
            }
            else
            {
                current.Append(c);
                inToken = true;
            }
        }

        if (quote is not null)
        {
            throw new FormatException(CoreStrings.Get("Connection/CommandUnclosedQuote"));
        }

        if (inToken)
        {
            tokens.Add(current.ToString());
        }

        return tokens;
    }

    /// <summary>The message the form shows for settings that cannot run, or null when they can.</summary>
    public static string? Validate(TunnelCommandSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        switch (settings.Method)
        {
            case TunnelCommandMethod.Custom:
                if (string.IsNullOrWhiteSpace(settings.Command))
                {
                    return CoreStrings.Get("Connection/CommandRequired");
                }

                IReadOnlyList<string> tokens;
                try
                {
                    tokens = Tokenize(settings.Command);
                }
                catch (FormatException)
                {
                    return CoreStrings.Get("Connection/CommandUnclosedQuote");
                }

                if (tokens.Count == 0)
                {
                    return CoreStrings.Get("Connection/CommandRequired");
                }

                return tokens.Skip(1).Any(ContainsLocalPort) ? null : CoreStrings.Format("Connection/CommandNeedsLocalPort", LocalPortPlaceholder);

            case TunnelCommandMethod.Kubectl:
                if (string.IsNullOrWhiteSpace(settings.KubernetesResource))
                {
                    return CoreStrings.Get("Connection/KubernetesResourceRequired");
                }

                return PresetFieldProblem(TunnelField.Resource, settings.KubernetesResource)
                    ?? PresetFieldProblem(TunnelField.Namespace, settings.KubernetesNamespace)
                    ?? PresetFieldProblem(TunnelField.Context, settings.KubernetesContext);

            case TunnelCommandMethod.AwsSsm:
                if (string.IsNullOrWhiteSpace(settings.AwsTarget))
                {
                    return CoreStrings.Get("Connection/SsmTargetRequired");
                }

                return PresetFieldProblem(TunnelField.Target, settings.AwsTarget)
                    ?? PresetFieldProblem(TunnelField.Profile, settings.AwsProfile)
                    ?? PresetFieldProblem(TunnelField.Region, settings.AwsRegion);

            default:
                return CoreStrings.Get("Connection/ChooseTunnelMethod");
        }
    }

    /// <summary>The program and arguments for a run that forwards <paramref name="localPort"/> to the database.</summary>
    /// <exception cref="FormatException">The settings fail <see cref="Validate"/>.</exception>
    public static TunnelCommandInvocation Build(TunnelCommandSettings settings, int localPort, string remoteHost, int remotePort)
    {
        ArgumentNullException.ThrowIfNull(settings);
        if (Validate(settings) is { } problem)
        {
            throw new FormatException(problem);
        }

        var local = localPort.ToString(CultureInfo.InvariantCulture);
        var remote = remotePort.ToString(CultureInfo.InvariantCulture);
        switch (settings.Method)
        {
            case TunnelCommandMethod.Kubectl:
            {
                var arguments = new List<string>();
                if (!string.IsNullOrWhiteSpace(settings.KubernetesContext))
                {
                    arguments.Add("--context=" + settings.KubernetesContext.Trim());
                }

                if (!string.IsNullOrWhiteSpace(settings.KubernetesNamespace))
                {
                    arguments.Add("--namespace=" + settings.KubernetesNamespace.Trim());
                }

                arguments.AddRange(["port-forward", "--address=127.0.0.1", settings.KubernetesResource!.Trim(), $"{local}:{remote}"]);
                return new TunnelCommandInvocation(PresetExecutable(settings, KubectlExecutable), arguments);
            }

            case TunnelCommandMethod.AwsSsm:
            {
                List<string> arguments =
                [
                    "ssm", "start-session",
                    "--target=" + settings.AwsTarget!.Trim(),
                    "--document-name=AWS-StartPortForwardingSessionToRemoteHost",
                    $"--parameters=host={remoteHost},portNumber={remote},localPortNumber={local}",
                ];
                if (!string.IsNullOrWhiteSpace(settings.AwsProfile))
                {
                    arguments.Add("--profile=" + settings.AwsProfile.Trim());
                }

                if (!string.IsNullOrWhiteSpace(settings.AwsRegion))
                {
                    arguments.Add("--region=" + settings.AwsRegion.Trim());
                }

                return new TunnelCommandInvocation(PresetExecutable(settings, AwsExecutable), arguments);
            }

            default:
            {
                var tokens = Tokenize(settings.Command!);
                var expanded = tokens.Select(t => Expand(t, local, remoteHost, remote)).ToArray();
                return new TunnelCommandInvocation(ExpandHome(expanded[0]), expanded[1..]);
            }
        }
    }

    /// <summary>
    /// What the form shows under the command: the run with the database's host and port filled in and the local
    /// port left as <c>{port}</c>, quoted the way a Windows command line would need.
    /// </summary>
    public static string Preview(TunnelCommandSettings settings, string remoteHost, int remotePort)
    {
        ArgumentNullException.ThrowIfNull(settings);
        if (Validate(settings) is not null)
        {
            return string.Empty;
        }

        // A sentinel port that Build formats like any other, swapped back for the placeholder afterwards.
        const int Sentinel = 65599;
        var invocation = Build(settings, Sentinel, remoteHost, remotePort);
        var sentinel = Sentinel.ToString(CultureInfo.InvariantCulture);
        return string.Join(' ', new[] { invocation.Executable }.Concat(invocation.Arguments).Select(a => Quote(a.Replace(sentinel, LocalPortPlaceholder, StringComparison.Ordinal))));
    }

    private static bool ContainsLocalPort(string token) =>
        token.Contains(LocalPortPlaceholder, StringComparison.Ordinal) || token.Contains(LocalPortAlias, StringComparison.Ordinal);

    private static string Expand(string token, string localPort, string host, string remotePort) => token
        .Replace(LocalPortAlias, localPort, StringComparison.Ordinal)
        .Replace(LocalPortPlaceholder, localPort, StringComparison.Ordinal)
        .Replace(HostPlaceholder, host, StringComparison.Ordinal)
        .Replace(RemotePortPlaceholder, remotePort, StringComparison.Ordinal);

    private static string PresetExecutable(TunnelCommandSettings settings, string fallback) =>
        string.IsNullOrWhiteSpace(settings.ExecutablePath) ? fallback : ExpandHome(settings.ExecutablePath.Trim());

    /// <summary>A preset value becomes part of one argument; a leading dash or a space would let it act as another.</summary>
    private static string? PresetFieldProblem(TunnelField field, string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        var trimmed = value.Trim();
        return trimmed.StartsWith('-') || trimmed.Any(char.IsWhiteSpace) ? CoreStrings.Format("Connection/TunnelFieldInvalid", FieldName(field)) : null;
    }

    // The field is named as the form labels it, in the UI language, so the message points at the box to fix.
    private static string FieldName(TunnelField field) => field switch
    {
        TunnelField.Resource => CoreStrings.Get("Connection/TunnelFieldResource"),
        TunnelField.Namespace => CoreStrings.Get("Connection/TunnelFieldNamespace"),
        TunnelField.Context => CoreStrings.Get("Connection/TunnelFieldContext"),
        TunnelField.Target => CoreStrings.Get("Connection/TunnelFieldTarget"),
        TunnelField.Profile => CoreStrings.Get("Connection/TunnelFieldProfile"),
        _ => CoreStrings.Get("Connection/TunnelFieldRegion"),
    };

    private enum TunnelField
    {
        Resource,
        Namespace,
        Context,
        Target,
        Profile,
        Region,
    }

    private static string ExpandHome(string path)
    {
        if (path == "~" || path.StartsWith("~/", StringComparison.Ordinal) || path.StartsWith(@"~\", StringComparison.Ordinal))
        {
            return Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + path[1..];
        }

        return path;
    }

    private static string Quote(string argument) =>
        argument.Length > 0 && !argument.Any(c => char.IsWhiteSpace(c) || c == '"') ? argument : "\"" + argument.Replace("\"", "\\\"", StringComparison.Ordinal) + "\"";
}
