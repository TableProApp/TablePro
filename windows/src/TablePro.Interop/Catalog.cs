namespace TablePro.Interop;

public enum DataModel
{
    Relational,
    KeyValue,
    Document,
}

/// <summary>An engine linked into the core, as the connect dialog lists it.</summary>
/// <param name="FileSuffixes">For an engine that opens files, the name suffixes it claims, the one a new file
/// gets first. Empty for a network engine.</param>
public sealed record DatabaseEngine(
    string Id,
    string DisplayName,
    DataModel DataModel,
    int? DefaultPort,
    IReadOnlyList<string> FileSuffixes);

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

    /// <summary>A kind a newer core reports that this build does not name.</summary>
    Other,
}

/// <param name="ParentTable">The table a trigger fires on.</param>
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

/// <summary>A table as the server qualifies it. No schema means the engine has none, or the default one.</summary>
public sealed record TableName(string? Schema, string Name);

/// <param name="TypeName">The type as the server spells it, for display.</param>
public sealed record ColumnEntry(
    string Name,
    string TypeName,
    ValueKind ValueKind,
    bool IsNullable,
    bool IsPrimaryKey,
    bool IsAutoIncrement,
    bool IsGenerated,
    string? Comment);
