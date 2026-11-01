using TablePro.Core.Drivers;
using TablePro.Drivers.Beancount.Localization;

namespace TablePro.Drivers.Beancount;

/// <summary>What a Beancount connection reads from its profile.</summary>
internal sealed record BeancountOptions(
    string LedgerPath,
    TimeSpan Timeout,
    string? Backend,
    string? PythonPath,
    string? RledgerPath,
    bool RunLedgerPlugins)
{
    /// <summary><c>python</c> or <c>rledger</c>; any other value is refused at connect.</summary>
    public const string BackendKey = "backend";

    /// <summary>The Python executable that has the beancount package.</summary>
    public const string PythonKey = "python";

    /// <summary>The rledger executable, for the rledger backend and for BQL queries.</summary>
    public const string RledgerKey = "rledger";

    /// <summary>The macOS app's field id, so a profile carried over keeps its setting.</summary>
    public const string RunLedgerPluginsKey = "beancountRunLedgerPlugins";

    public static BeancountOptions From(ConnectionRequest request)
    {
        var profile = request.Profile;
        var path = !string.IsNullOrWhiteSpace(profile.FilePath) ? profile.FilePath : request.Database;
        if (string.IsNullOrWhiteSpace(path))
        {
            throw new BeancountException(BeancountStrings.Get("Beancount/NeedsLedger"));
        }

        var options = profile.AdditionalOptions;
        return new BeancountOptions(
            Path.GetFullPath(Environment.ExpandEnvironmentVariables(path.Trim())),
            TimeSpan.FromSeconds(Math.Max(profile.ConnectTimeoutSeconds, 1)),
            Option(options, BackendKey),
            Option(options, PythonKey),
            Option(options, RledgerKey),
            Option(options, RunLedgerPluginsKey) is { } plugins
                && (plugins.Equals("true", StringComparison.OrdinalIgnoreCase) || plugins is "1" || plugins.Equals("yes", StringComparison.OrdinalIgnoreCase)));
    }

    // Keys are matched without case: the form writes them by hand, and a typed "Python" should not be ignored.
    private static string? Option(IReadOnlyDictionary<string, string> options, string key)
    {
        foreach (var (name, value) in options)
        {
            if (string.Equals(name, key, StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(value))
            {
                return Environment.ExpandEnvironmentVariables(value.Trim());
            }
        }

        return null;
    }
}
