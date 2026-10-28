using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.Tests;

internal static class Profiles
{
    public static ConnectionRequest Request(
        DatabaseEngine engine,
        SslMode ssl = SslMode.Preferred,
        string? user = "app",
        string? database = "shop",
        SafeModeLevel safeMode = SafeModeLevel.Silent,
        IReadOnlyDictionary<string, string>? options = null)
    {
        var profile = new ConnectionProfile
        {
            Name = "test",
            Engine = engine,
            Host = "db.example.com",
            Port = 0,
            Database = database,
            Username = user,
            SslMode = ssl,
            SafeMode = safeMode,
            ConnectTimeoutSeconds = 7,
            AdditionalOptions = options ?? new Dictionary<string, string>(),
        };

        // A tunnel replaces where to dial, so the request's host and port must win over the profile's.
        return new ConnectionRequest(profile, "s3cret;'x", "127.0.0.1", 15432, database);
    }
}
