using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.Analytics.Tests;

internal static class Profiles
{
    public const string Password = "s3cret;'x";

    public static ConnectionProfile Profile(
        DatabaseEngine engine,
        SslMode ssl = SslMode.Preferred,
        string? user = "app",
        string? database = "shop",
        int port = 0,
        SafeModeLevel safeMode = SafeModeLevel.Silent,
        IReadOnlyDictionary<string, string>? options = null,
        string? startup = null) =>
        new()
        {
            Name = "test",
            Engine = engine,
            Host = "db.example.com",
            Port = port,
            Database = database,
            Username = user,
            SslMode = ssl,
            SafeMode = safeMode,
            ConnectTimeoutSeconds = 7,
            AdditionalOptions = options ?? new Dictionary<string, string>(),
            StartupCommands = startup,
        };

    /// <summary>Through a tunnel: the request's host and port must win over the profile's.</summary>
    public static ConnectionRequest Tunnelled(ConnectionProfile profile) =>
        new(profile, Password, "127.0.0.1", 15432, profile.Database);

    public static ConnectionRequest Tunnelled(
        DatabaseEngine engine,
        SslMode ssl = SslMode.Preferred,
        string? user = "app",
        string? database = "shop",
        SafeModeLevel safeMode = SafeModeLevel.Silent,
        IReadOnlyDictionary<string, string>? options = null) =>
        Tunnelled(Profile(engine, ssl, user, database, safeMode: safeMode, options: options));

    public static ConnectionRequest Direct(ConnectionProfile profile) => ConnectionRequest.Direct(profile, Password);
}
