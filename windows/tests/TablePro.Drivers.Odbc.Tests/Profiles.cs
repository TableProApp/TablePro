using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.Odbc.Tests;

internal static class Profiles
{
    public const string Password = "s3cret;}{x";

    public static ConnectionProfile Profile(
        DatabaseEngine engine,
        SslMode ssl = SslMode.Disabled,
        string? user = "app",
        string? database = "SHOP",
        SafeModeLevel safeMode = SafeModeLevel.Silent,
        IReadOnlyDictionary<string, string>? options = null,
        string? startup = null) =>
        new()
        {
            Name = "test",
            Engine = engine,
            Host = "db.example.com",
            Database = database,
            Username = user,
            SslMode = ssl,
            SafeMode = safeMode,
            ConnectTimeoutSeconds = 7,
            AdditionalOptions = options ?? new Dictionary<string, string>(),
            StartupCommands = startup,
        };

    /// <summary>Through a tunnel: the request's host and port must win over the profile's.</summary>
    public static ConnectionRequest Tunnelled(ConnectionProfile profile) => new(profile, Password, "127.0.0.1", 15432, profile.Database);

    public static ConnectionRequest Tunnelled(
        DatabaseEngine engine,
        SslMode ssl = SslMode.Disabled,
        string? database = "SHOP",
        SafeModeLevel safeMode = SafeModeLevel.Silent,
        IReadOnlyDictionary<string, string>? options = null,
        string? startup = null) =>
        Tunnelled(Profile(engine, ssl, database: database, safeMode: safeMode, options: options, startup: startup));

    /// <summary>
    /// Splits a connection string with .NET's ODBC parser, so a test reads back what the driver manager would. The
    /// builder keeps braced values as written and always lists Dsn and Driver, so braces are undone here and those two
    /// are dropped when the string did not set them.
    /// </summary>
    public static Dictionary<string, string> Parse(string connectionString)
    {
        var builder = new System.Data.Odbc.OdbcConnectionStringBuilder(connectionString);
        var pairs = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (string key in builder.Keys)
        {
            var value = Convert.ToString(builder[key], System.Globalization.CultureInfo.InvariantCulture) ?? string.Empty;
            if (value.Length == 0 && key is "Dsn" or "Driver")
            {
                continue;
            }

            pairs[key] = value.Length >= 2 && value[0] == '{' && value[^1] == '}'
                ? value[1..^1].Replace("}}", "}", StringComparison.Ordinal)
                : value;
        }

        return pairs;
    }
}
