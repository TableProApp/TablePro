using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

public enum DatabaseEnvironment
{
    Development,
    Testing,
    Production,
    Unassigned,
}

// Database and Schema are null where the engine has none.
public sealed record FavouriteTable(string? Database, string? Schema, string Name);

public sealed record FavouriteDatabase(string Database, DatabaseEnvironment Environment);

// The tables and databases a user marked, per connection, in the query history's database (core ADR 0017).
public sealed class Favourites : IDisposable
{
    private readonly Native.FavouriteStore _store;

    internal Favourites(Native.FavouriteStore store)
    {
        _store = store;
    }

    public async Task<IReadOnlyList<FavouriteTable>> GetTablesAsync(Guid connectionId)
    {
        var tables = await CoreCall.RunAsync(() => _store.Tables(connectionId.ToString())).ConfigureAwait(false);
        return [.. tables.Select(table => new FavouriteTable(table.Database, table.Schema, table.Name))];
    }

    // A table marked already stays as it is.
    public Task AddTableAsync(Guid connectionId, FavouriteTable table)
    {
        ArgumentNullException.ThrowIfNull(table);
        var native = Table(table);
        return CoreCall.RunAsync(() => _store.AddTable(connectionId.ToString(), native));
    }

    public Task RemoveTableAsync(Guid connectionId, FavouriteTable table)
    {
        ArgumentNullException.ThrowIfNull(table);
        var native = Table(table);
        return CoreCall.RunAsync(() => _store.RemoveTable(connectionId.ToString(), native));
    }

    public async Task<IReadOnlyList<FavouriteDatabase>> GetDatabasesAsync(Guid connectionId)
    {
        var databases = await CoreCall.RunAsync(() => _store.Databases(connectionId.ToString())).ConfigureAwait(false);
        return [.. databases.Select(database => new FavouriteDatabase(database.Database, Environment(database.Environment)))];
    }

    // Marks the database, or files a marked one under another environment.
    public Task SetDatabaseAsync(Guid connectionId, string database, DatabaseEnvironment environment)
    {
        ArgumentNullException.ThrowIfNull(database);
        var native = Environment(environment);
        return CoreCall.RunAsync(() => _store.SetDatabase(connectionId.ToString(), database, native));
    }

    public Task RemoveDatabaseAsync(Guid connectionId, string database)
    {
        ArgumentNullException.ThrowIfNull(database);
        return CoreCall.RunAsync(() => _store.RemoveDatabase(connectionId.ToString(), database));
    }

    public void Dispose() => _store.Dispose();

    private static Native.FavouriteTableInfo Table(FavouriteTable table) => new(table.Database, table.Schema, table.Name);

    private static DatabaseEnvironment Environment(Native.DatabaseEnvironmentTag environment) => environment switch
    {
        Native.DatabaseEnvironmentTag.Development => DatabaseEnvironment.Development,
        Native.DatabaseEnvironmentTag.Testing => DatabaseEnvironment.Testing,
        Native.DatabaseEnvironmentTag.Production => DatabaseEnvironment.Production,
        _ => DatabaseEnvironment.Unassigned,
    };

    private static Native.DatabaseEnvironmentTag Environment(DatabaseEnvironment environment) => environment switch
    {
        DatabaseEnvironment.Development => Native.DatabaseEnvironmentTag.Development,
        DatabaseEnvironment.Testing => Native.DatabaseEnvironmentTag.Testing,
        DatabaseEnvironment.Production => Native.DatabaseEnvironmentTag.Production,
        _ => Native.DatabaseEnvironmentTag.Unassigned,
    };
}
