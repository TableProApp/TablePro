namespace TablePro.Interop;

// Ddl: the engine's CREATE script for a table; null for a view, or where the engine writes none.
public sealed record TableStructure(
    IReadOnlyList<StructureColumn> Columns,
    IReadOnlyList<StructureIndex> Indexes,
    IReadOnlyList<StructureForeignKey> ForeignKeys,
    string? Ddl);

// TypeName: as the server spells it. DefaultValue: SQL the user could type back in; null for no default.
public sealed record StructureColumn(
    string Name,
    string TypeName,
    bool Nullable,
    string? DefaultValue,
    bool PrimaryKey,
    bool AutoIncrement,
    bool Generated,
    string? Comment);

// Keys: a column name or an expression each, with " DESC" after a descending one.
public sealed record StructureIndex(
    string Name,
    IReadOnlyList<string> Keys,
    bool Unique,
    bool Primary,
    string? Predicate);

// OnDelete and OnUpdate: the SQL keywords, null where the server spelled one this build does not know.
public sealed record StructureForeignKey(
    string Name,
    IReadOnlyList<string> Columns,
    string? ReferencedSchema,
    string ReferencedTable,
    IReadOnlyList<string> ReferencedColumns,
    string? OnDelete,
    string? OnUpdate);

// Database: where Sql runs when it names none. OpensInEditor: false when an editor run would not make it as it is.
public sealed record ObjectSource(string Sql, string? Database, bool OpensInEditor);
