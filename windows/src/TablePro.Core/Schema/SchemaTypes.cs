namespace TablePro.Core.Schema;

public enum ObjectKind
{
    Table,
    View,
    MaterializedView,
    Function,
    Procedure,
    Sequence,
    Trigger,

    /// <summary>A document collection (MongoDB, SurrealDB tables) or a search index.</summary>
    Collection,

    /// <summary>One key of a key-value engine; its value's type is in <see cref="DatabaseObject.Comment"/>.</summary>
    Key,

    /// <summary>A streaming topic.</summary>
    Topic,
}

/// <summary>A schema-qualified name. Engines without schemas leave <see cref="Schema"/> null.</summary>
public readonly record struct ObjectName(string? Schema, string Name)
{
    public override string ToString() => string.IsNullOrEmpty(Schema) ? Name : $"{Schema}.{Name}";
}

public sealed record DatabaseObject(ObjectName Name, ObjectKind Kind, long? RowEstimate = null, string? Comment = null)
{
    public bool HasRows => Kind is ObjectKind.Table or ObjectKind.View or ObjectKind.MaterializedView or ObjectKind.Collection or ObjectKind.Key or ObjectKind.Topic;
}

public sealed record ColumnInfo(
    string Name,
    string DataType,
    bool IsNullable,
    string? DefaultValue,
    bool IsPrimaryKey,
    bool IsIdentity,
    int Ordinal,
    string? Comment = null);

public sealed record IndexInfo(string Name, IReadOnlyList<string> Columns, bool IsUnique, bool IsPrimary, string? Method = null);

public sealed record ForeignKeyInfo(
    string Name,
    IReadOnlyList<string> Columns,
    ObjectName ReferencedTable,
    IReadOnlyList<string> ReferencedColumns,
    string? OnUpdate = null,
    string? OnDelete = null);

public sealed record TriggerInfo(string Name, string Timing, string Event, string? Definition = null);

public sealed record TableStructure(
    ObjectName Table,
    IReadOnlyList<ColumnInfo> Columns,
    IReadOnlyList<IndexInfo> Indexes,
    IReadOnlyList<ForeignKeyInfo> ForeignKeys,
    IReadOnlyList<TriggerInfo> Triggers)
{
    public IReadOnlyList<string> PrimaryKey { get; } = Columns.Where(c => c.IsPrimaryKey).Select(c => c.Name).ToArray();
}
