using Microsoft.Data.Sqlite;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.Sqlite;

internal static class SqliteConnectionStringFactory
{
    public static string Build(ConnectionRequest request)
    {
        var profile = request.Profile;
        var path = !string.IsNullOrWhiteSpace(profile.FilePath) ? profile.FilePath : request.Database;
        if (string.IsNullOrWhiteSpace(path))
        {
            throw new InvalidOperationException("A SQLite connection needs a database file.");
        }

        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = Environment.ExpandEnvironmentVariables(path),
            Mode = profile.IsReadOnly ? SqliteOpenMode.ReadOnly : SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Default,
            Pooling = true,

            // The provider runs PRAGMA foreign_keys on every open, including a pooled connection handed out again,
            // which a one-off PRAGMA at connect time would miss.
            ForeignKeys = true,

            // Doubles as the busy timeout, so a writer in another process makes us wait instead of failing at once.
            DefaultTimeout = Math.Max(profile.ConnectTimeoutSeconds, 1),
        };

        foreach (var (key, value) in profile.AdditionalOptions)
        {
            builder[key] = value;
        }

        return builder.ConnectionString;
    }
}
