using System.Data.Common;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.DuckDb;

internal static class DuckDbConnectionStringFactory
{
    public const string Memory = ":memory:";

    public static string Build(ConnectionRequest request)
    {
        var profile = request.Profile;
        var path = !string.IsNullOrWhiteSpace(profile.FilePath) ? profile.FilePath : request.Database;
        path = string.IsNullOrWhiteSpace(path) ? Memory : Environment.ExpandEnvironmentVariables(path);

        var builder = new DbConnectionStringBuilder { ["Data Source"] = path };

        // DuckDB refuses to open an in-memory database READ_ONLY, and there is no file to protect there anyway.
        // The value must be spelled READ_ONLY: a value DuckDB rejects leaves the database writable.
        if (profile.IsReadOnly && !path.StartsWith(Memory, StringComparison.Ordinal))
        {
            builder["access_mode"] = "READ_ONLY";
        }

        foreach (var (key, value) in profile.AdditionalOptions)
        {
            builder[key] = value;
        }

        return builder.ConnectionString;
    }
}
