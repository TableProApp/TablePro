using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.Warehouse.Tests;

internal static class Profiles
{
    public static ConnectionRequest Request(
        DatabaseEngine engine,
        string host = "db.example.com",
        int port = 0,
        string? user = "app",
        string? database = "shop",
        string? password = "s3cret;'x",
        string? filePath = null,
        SslMode ssl = SslMode.Preferred,
        IReadOnlyDictionary<string, string>? options = null)
    {
        var profile = new ConnectionProfile
        {
            Name = "test",
            Engine = engine,
            Host = host,
            Port = port,
            Database = database,
            Username = user,
            FilePath = filePath,
            SslMode = ssl,
            ConnectTimeoutSeconds = 7,
            AdditionalOptions = options ?? new Dictionary<string, string>(),
        };

        return new ConnectionRequest(profile, password, host, port > 0 ? port : profile.EffectivePort, database);
    }
}
