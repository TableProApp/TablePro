namespace TablePro.Interop;

public enum DataModel
{
    Relational,
    KeyValue,
    Document,
}

// FileSuffixes: the suffixes a file engine claims, the one a new file gets first. Empty for a network engine.
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

// The engine's row address may follow the visible columns; a grid shows the first VisibleColumns.
public sealed record TableQuery(string Sql, int VisibleColumns);

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
