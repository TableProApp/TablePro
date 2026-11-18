using System.Globalization;

namespace TablePro.Interop.Tests.Live;

// A server windows/ci/live-servers.ps1 started on this machine, from its TABLEPRO_TEST_LIVE_<ENGINE>_* variables.
internal sealed record LiveServer(int Port, string UserName, string? Password)
{
    public const string Host = "127.0.0.1";

    public static LiveServer? Find(string engine)
    {
        var prefix = $"TABLEPRO_TEST_LIVE_{engine}_";
        if (Environment.GetEnvironmentVariable(prefix + "PORT") is not { Length: > 0 } port)
        {
            return null;
        }

        return new LiveServer(
            int.Parse(port, CultureInfo.InvariantCulture),
            Environment.GetEnvironmentVariable(prefix + "USER") ?? string.Empty,
            Environment.GetEnvironmentVariable(prefix + "PASSWORD"));
    }

    public static LiveServer Require(string engine)
    {
        var server = Find(engine);
        Assert.SkipWhen(server is null, $"Requires the live {engine} server that windows/ci/live-servers.ps1 starts.");
        return server!;
    }

    // An empty password for a server that takes none, as the connection form saves one.
    public ConnectionSecrets Secrets => new(DatabasePassword: Password ?? string.Empty);
}
