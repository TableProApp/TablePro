using System.Collections.Concurrent;

namespace TablePro.Drivers.Beancount;

internal enum BeancountBackendKind
{
    Python,
    Rledger,
}

/// <summary>A program that can load a ledger, and the arguments that select it (<c>py -3</c> is <c>py</c> plus <c>-3</c>).</summary>
internal sealed record BeancountBackend(BeancountBackendKind Kind, string Executable, IReadOnlyList<string> PrefixArguments)
{
    public static BeancountBackend Python(string executable, params IReadOnlyList<string> prefix) => new(BeancountBackendKind.Python, executable, prefix);

    public static BeancountBackend Rledger(string executable) => new(BeancountBackendKind.Rledger, executable, []);

    public ProcessSpec Spec(IReadOnlyList<string> arguments, IReadOnlyDictionary<string, string>? environment = null, string? standardInput = null) =>
        new(Executable, [.. PrefixArguments, .. arguments], environment, standardInput);

    public override string ToString() => PrefixArguments.Count == 0 ? Executable : Executable + " " + string.Join(' ', PrefixArguments);
}

/// <summary>
/// Picks the backend: the connection's <c>backend</c> option, then its <c>python</c> and <c>rledger</c> paths, then
/// <c>py -3</c>, <c>python</c> and <c>rledger</c> on PATH. The macOS app's environment variables stand in for each
/// option, so one setup serves both apps.
/// </summary>
internal sealed class BeancountBackendLocator
{
    public const string BackendVariable = "TABLEPRO_BEANCOUNT_BACKEND";
    public const string PythonVariable = "TABLEPRO_BEANCOUNT_PYTHON";
    public const string RledgerVariable = "TABLEPRO_RUSTLEDGER_BINARY";

    // Importing beancount proves the package works; the version is printed on the same run so connecting costs one launch.
    internal const string PythonProbeScript = "import beancount; from importlib.metadata import version; print(version('beancount'))";

    private const string InstallHint =
        "Install the Python package with \"py -3 -m pip install beancount\" (or \"pip install beancount\"), or install rustledger so rledger.exe is on PATH";

    // A Python that imports beancount keeps doing so; one that cannot is asked again, since the user may install it meanwhile.
    private static readonly ConcurrentDictionary<string, string> PythonVersions = new(StringComparer.OrdinalIgnoreCase);

    private readonly IProcessRunner _runner;
    private readonly Func<string, string?> _environment;
    private readonly Func<string, bool> _fileExists;
    private readonly ConcurrentDictionary<string, string> _pythonVersions;

    public BeancountBackendLocator(IProcessRunner runner)
        : this(runner, Environment.GetEnvironmentVariable, File.Exists, PythonVersions)
    {
    }

    internal BeancountBackendLocator(
        IProcessRunner runner,
        Func<string, string?> environment,
        Func<string, bool> fileExists,
        ConcurrentDictionary<string, string>? pythonVersions = null)
    {
        _runner = runner;
        _environment = environment;
        _fileExists = fileExists;
        _pythonVersions = pythonVersions ?? new ConcurrentDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    }

    public async Task<BeancountBackend> ProjectionBackendAsync(BeancountOptions options, CancellationToken cancellationToken)
    {
        var preference = (options.Backend ?? NonEmpty(_environment(BackendVariable)))?.ToLowerInvariant();
        var pythonPath = Unquote(options.PythonPath ?? NonEmpty(_environment(PythonVariable)));
        var rledgerPath = Unquote(options.RledgerPath ?? NonEmpty(_environment(RledgerVariable)));

        switch (preference)
        {
            case "python" or "beancount":
                if (pythonPath is not null)
                {
                    return await ConfiguredPythonAsync(pythonPath, cancellationToken);
                }

                return await PythonOnPathAsync(cancellationToken)
                    ?? throw new BeancountException(
                        "The Python Beancount backend needs Python 3 with the beancount package. Run \"py -3 -m pip install beancount\", "
                        + "or set the connection's python option to a Python that has it.");
            case "rledger" or "rustledger":
                return Rledger(rledgerPath);
            case null:
                break;
            default:
                throw new BeancountException($"Unknown Beancount backend \"{preference}\". Use \"python\" or \"rledger\".");
        }

        if (pythonPath is not null)
        {
            return await ConfiguredPythonAsync(pythonPath, cancellationToken);
        }

        if (rledgerPath is not null)
        {
            return Rledger(rledgerPath);
        }

        if (await PythonOnPathAsync(cancellationToken) is { } python)
        {
            return python;
        }

        if (FindOnPath("rledger") is { } rledger)
        {
            return BeancountBackend.Rledger(rledger);
        }

        throw new BeancountException($"Beancount needs Python Beancount or rledger, and neither was found. {InstallHint}, or set the connection's python or rledger option to its path.");
    }

    /// <summary>The rledger that answers BQL, whichever backend built the projection.</summary>
    public BeancountBackend QueryBackend(BeancountOptions options)
    {
        var configured = Unquote(options.RledgerPath ?? NonEmpty(_environment(RledgerVariable)));
        if (configured is not null)
        {
            return Rledger(configured);
        }

        return FindOnPath("rledger") is { } rledger
            ? BeancountBackend.Rledger(rledger)
            : throw new BeancountException("BQL queries need rledger. Install rustledger so rledger.exe is on PATH, or set the connection's rledger option to its path.");
    }

    /// <summary>The version a Python reported when it proved it imports beancount.</summary>
    public string? PythonVersion(BeancountBackend backend) => _pythonVersions.TryGetValue(backend.ToString(), out var version) ? version : null;

    /// <summary>An <c>.exe</c> on PATH. Batch files are never run: their arguments are re-parsed by cmd.exe.</summary>
    internal string? FindOnPath(string name)
    {
        var fileName = name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? name : name + ".exe";
        foreach (var entry in (_environment("PATH") ?? string.Empty).Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var directory = entry.Trim('"');
            if (directory.Length == 0)
            {
                continue;
            }

            string candidate;
            try
            {
                candidate = Path.Combine(directory, fileName);
            }
            catch (ArgumentException)
            {
                continue;
            }

            if (_fileExists(candidate))
            {
                return candidate;
            }
        }

        return null;
    }

    private BeancountBackend Rledger(string? configured)
    {
        if (configured is null)
        {
            return FindOnPath("rledger") is { } found
                ? BeancountBackend.Rledger(found)
                : throw new BeancountException("The rledger backend needs rustledger. Install it so rledger.exe is on PATH, or set the connection's rledger option to its path.");
        }

        return ResolveExecutable(configured) is { } path
            ? BeancountBackend.Rledger(path)
            : throw new BeancountException($"The rledger option points to a missing rledger at {configured}.");
    }

    private async Task<BeancountBackend> ConfiguredPythonAsync(string configured, CancellationToken cancellationToken)
    {
        var path = ResolveExecutable(configured) ?? throw new BeancountException($"The python option points to a missing Python at {configured}.");
        var backend = BeancountBackend.Python(path);
        return await ImportsBeancountAsync(backend, cancellationToken)
            ? backend
            : throw new BeancountException($"{path} cannot import beancount. Run \"{path}\" -m pip install beancount, or set the python option to a Python that has it.");
    }

    private async Task<BeancountBackend?> PythonOnPathAsync(CancellationToken cancellationToken)
    {
        if (FindOnPath("py") is { } launcher && await ImportsBeancountAsync(BeancountBackend.Python(launcher, "-3"), cancellationToken))
        {
            return BeancountBackend.Python(launcher, "-3");
        }

        if (FindOnPath("python") is { } python && await ImportsBeancountAsync(BeancountBackend.Python(python), cancellationToken))
        {
            return BeancountBackend.Python(python);
        }

        return null;
    }

    private async Task<bool> ImportsBeancountAsync(BeancountBackend backend, CancellationToken cancellationToken)
    {
        var key = backend.ToString();
        if (_pythonVersions.ContainsKey(key))
        {
            return true;
        }

        ProcessOutput output;
        try
        {
            output = await _runner.RunAsync(backend.Spec(["-c", PythonProbeScript], PythonBackend.Environment(runLedgerPlugins: false)), cancellationToken);
        }
        catch (BeancountException)
        {
            return false;
        }

        if (output.ExitCode != 0)
        {
            return false;
        }

        var version = output.StandardOutputText.Trim();
        _pythonVersions[key] = version.Length == 0 ? "Python Beancount" : "Python Beancount " + version;
        return true;
    }

    /// <summary>A rooted path that exists, or a bare name found on PATH.</summary>
    private string? ResolveExecutable(string configured)
    {
        if (Path.IsPathRooted(configured) || configured.Contains('\\', StringComparison.Ordinal) || configured.Contains('/', StringComparison.Ordinal))
        {
            var full = Path.GetFullPath(configured);
            return _fileExists(full) ? full : null;
        }

        return FindOnPath(configured);
    }

    private static string? NonEmpty(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private static string? Unquote(string? value) => value?.Trim().Trim('"') is { Length: > 0 } unquoted ? unquoted : null;
}
