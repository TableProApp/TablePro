using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.WideColumn.Tests;

internal static class Requests
{
    public static ConnectionRequest For(
        DatabaseEngine engine,
        string host = "db.example.com",
        int port = 0,
        string? user = "app",
        string? password = "s3cret",
        string? database = "shop",
        SslMode ssl = SslMode.Preferred,
        IReadOnlyDictionary<string, string>? options = null,
        string? dialHost = null,
        int? dialPort = null)
    {
        var profile = new ConnectionProfile
        {
            Name = "test",
            Engine = engine,
            Host = host,
            Port = port,
            Database = database,
            Username = user,
            SslMode = ssl,
            ConnectTimeoutSeconds = 7,
            AdditionalOptions = options ?? new Dictionary<string, string>(),
        };

        return new ConnectionRequest(profile, password, dialHost ?? host, dialPort ?? profile.EffectivePort, database);
    }
}
