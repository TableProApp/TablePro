using TablePro.Interop;

namespace TablePro.App.Model;

// Database set: the connection opens in that database first, as its database switcher would open it.
public sealed record LinkedTablePlace(string? Database, string? Schema);

// A link's database and schema segments read as macOS reads them for the engine's layout.
public static class LinkedTable
{
    // A segment naming a dimension the engine does not have is dropped rather than applied to the other one.
    public static LinkedTablePlace Place(DatabaseLayout layout, string? current, string? database, string? schema) =>
        layout switch
        {
            DatabaseLayout.WithSchemas when database is not null && database != current => new(database, schema),
            DatabaseLayout.WithSchemas => new(null, schema),
            DatabaseLayout.AsSchemas => new(null, database ?? schema),
            _ => new(null, schema),
        };
}

// What a tablepro://connect link opens once its connection is up.
public abstract record LinkTarget
{
    private LinkTarget()
    {
    }

    public sealed record Table(string? Database, string? Schema, string Name) : LinkTarget;

    public sealed record Query(string Sql) : LinkTarget;
}
