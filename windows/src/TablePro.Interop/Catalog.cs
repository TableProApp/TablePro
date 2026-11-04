namespace TablePro.Interop;

public enum DataModel
{
    Relational,
    KeyValue,
    Document,
}

// The family the connect dialog lists an engine under, in the order it lists them.
public enum EngineCategory
{
    Relational,
    Document,
    KeyValue,
    Analytical,
    WideColumn,
}

// FileSuffixes: the suffixes a file engine claims, the one a new file gets first. Empty for a network engine.
public sealed record DatabaseEngine(
    string Id,
    string DisplayName,
    DataModel DataModel,
    int? DefaultPort,
    IReadOnlyList<string> FileSuffixes,
    EngineCategory Category = EngineCategory.Relational)
{
    public IReadOnlyList<TlsMode> SupportedTlsModes { get; init; } = [];

    public bool SupportsIntegratedAuth { get; init; }

    public bool SupportsClientIdentity { get; init; }
}

public sealed record SchemaEntry(string Name, bool IsDefault, bool IsSystem);

public enum ObjectKind
{
    Table,
    PartitionedTable,
    View,
    MaterializedView,
    ForeignTable,
    Sequence,
    Function,
    Procedure,
    Trigger,
    Dictionary,
    Key,

    // A kind a newer core reports that this build does not name.
    Other,
}

// ParentTable: the table a trigger fires on.
public sealed record ObjectEntry(string? Schema, string Name, ObjectKind Kind, string? ParentTable);

public abstract record ObjectScope
{
    private ObjectScope()
    {
    }

    public static ObjectScope DefaultSchema { get; } = new DefaultSchemaScope();

    public static ObjectScope AllSchemas { get; } = new AllSchemasScope();

    public static ObjectScope Schema(string name) => new NamedSchema(name);

    public sealed record NamedSchema(string Name) : ObjectScope;

    public sealed record DefaultSchemaScope : ObjectScope;

    public sealed record AllSchemasScope : ObjectScope;
}

// No schema means the engine has none, or the default one.
public sealed record TableName(string? Schema, string Name);

// Column is the table's column position, as the grid numbers its columns.
public sealed record ColumnSort(int Column, bool Ascending);

// Any columns past VisibleColumns are the engine's row address; without CanSeek only the first page can be read.
public sealed record TableQuery(string Sql, int VisibleColumns, bool CanSeek = true);

public enum FailureCause
{
    Authentication,
    Tls,
    Configuration,
    HostKey,
}

// How a session's connection is doing. A reconnect replaces it on its own; a failed one waits for Reconnect.
public abstract record SessionHealth
{
    private SessionHealth()
    {
    }

    public sealed record Online : SessionHealth;

    public sealed record Reconnecting(int Attempt) : SessionHealth;

    // The server is unreachable; the core checks again on a long timer.
    public sealed record Offline : SessionHealth;

    public sealed record Failed(FailureCause Cause, CoreError? Reason) : SessionHealth;
}

// TypeName: the type as the server spells it, for display.
public sealed record ColumnEntry(
    string Name,
    string TypeName,
    ValueKind ValueKind,
    bool IsNullable,
    bool IsPrimaryKey,
    bool IsAutoIncrement,
    bool IsGenerated,
    string? Comment);
