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

/// <summary>
/// A table-level CHECK constraint as the server reports it. <see cref="Expression"/> is the catalog's normal form, not
/// the text that was typed: PostgreSQL rewrites <c>a IN (1, 2)</c> as <c>a = ANY (ARRAY[1, 2])</c> and SQL Server wraps
/// every operand in parentheses, so a driver passes it through rather than guessing the original spelling.
/// </summary>
public sealed record CheckConstraintInfo(string Name, string Expression)
{
    /// <summary>The columns the check reads, where the engine's catalog says; empty where it cannot.</summary>
    public IReadOnlyList<string> Columns { get; init; } = [];

    /// <summary>False for a constraint added without checking the rows already there (NOT VALID, NOVALIDATE, NOCHECK).</summary>
    public bool IsValidated { get; init; } = true;

    public CheckConstraintDefinition ToDefinition() => new(Name, Expression);
}

/// <summary>
/// One partition of a partitioned table. On PostgreSQL a partition is a relation of its own and can be dropped or
/// truncated by name; on MySQL, Oracle and ClickHouse it is a segment of its table, named only within it.
/// </summary>
public sealed record PartitionInfo(string Name, string? Bound = null)
{
    /// <summary>The schema of a partition that is a relation, which need not be its parent's.</summary>
    public string? Schema { get; init; }

    /// <summary>The partition a subpartition divides; null for a top-level partition.</summary>
    public string? Parent { get; init; }

    /// <summary>Where the partition sits in its parent's declared order, counting from 1.</summary>
    public int? Ordinal { get; init; }

    /// <summary>The engine's row estimate, which is not a count.</summary>
    public long? RowEstimate { get; init; }

    public long? SizeBytes { get; init; }

    /// <summary>True when the partition is itself a table, as on PostgreSQL.</summary>
    public bool IsRelation { get; init; }

    public bool IsSubpartitioned { get; init; }

    public bool IsSubpartition => Parent is not null;
}

/// <summary>How a table is partitioned, such as <c>RANGE</c> over <c>created_at</c>, and the partitions it has now.</summary>
public sealed record PartitioningInfo(string Method, string Key, IReadOnlyList<PartitionInfo> Partitions)
{
    /// <summary>The subpartitioning method and key, for a table partitioned on two levels.</summary>
    public string? Subpartitioning { get; init; }

    public override string ToString() => string.IsNullOrEmpty(Key) ? Method : $"{Method} ({Key})";
}

/// <summary>A table option as the catalog reports it: the storage engine, collation, tablespace, comment and so on.</summary>
/// <remarks><see cref="Name"/> is also what the structure tab shows, so the well-known ones are spelled in <see cref="TableOptionNames"/>.</remarks>
public sealed record TableOption(string Name, string? Value);

/// <summary>The option names drivers share, so the same setting reads the same on every engine.</summary>
public static class TableOptionNames
{
    public const string Engine = "Engine";
    public const string Charset = "Character set";
    public const string Collation = "Collation";
    public const string RowFormat = "Row format";
    public const string AutoIncrement = "Next auto increment";
    public const string Comment = "Comment";
    public const string Tablespace = "Tablespace";
    public const string FillFactor = "Fill factor";
    public const string Persistence = "Persistence";
    public const string StorageParameters = "Storage parameters";
    public const string DataCompression = "Data compression";
    public const string LockEscalation = "Lock escalation";
    public const string Filegroup = "Filegroup";
    public const string PctFree = "Percent free";
    public const string Logging = "Logging";
    public const string Compression = "Compression";
    public const string RowMovement = "Row movement";
    public const string SortingKey = "Sorting key";
    public const string PrimaryKey = "Primary key";
    public const string SamplingKey = "Sampling key";
    public const string WithoutRowid = "Without rowid";
    public const string Strict = "Strict";
}

public enum TableOptionKind
{
    Text,
    Number,

    /// <summary>One of <see cref="TableOptionSpec.Choices"/>, or any other value the user types.</summary>
    Choice,
}

/// <summary>An option the structure tab may edit, and how its editor looks.</summary>
public sealed record TableOptionSpec(string Name, TableOptionKind Kind, IReadOnlyList<string>? Choices = null, string? Placeholder = null)
{
    public IReadOnlyList<string> ChoiceList => Choices ?? [];
}

/// <summary>The parts of a table's structure beyond its columns, keys and triggers, read by <see cref="Drivers.ITableDetailsProvider"/>.</summary>
public sealed record TableDetails(IReadOnlyList<CheckConstraintInfo> CheckConstraints, PartitioningInfo? Partitioning, IReadOnlyList<TableOption> Options)
{
    public static TableDetails Empty { get; } = new([], null, []);
}

public sealed record TableStructure(
    ObjectName Table,
    IReadOnlyList<ColumnInfo> Columns,
    IReadOnlyList<IndexInfo> Indexes,
    IReadOnlyList<ForeignKeyInfo> ForeignKeys,
    IReadOnlyList<TriggerInfo> Triggers)
{
    /// <summary>
    /// Derived on each read rather than stored, so a copy made with <c>with { Columns = ... }</c> reports its own key
    /// instead of the original's, and the record's equality is not affected by a cached copy.
    /// </summary>
    public IReadOnlyList<string> PrimaryKey => Columns.Where(c => c.IsPrimaryKey).Select(c => c.Name).ToArray();

    public IReadOnlyList<CheckConstraintInfo> CheckConstraints { get; init; } = [];

    /// <summary>Null for a table that is not partitioned, or an engine that cannot say.</summary>
    public PartitioningInfo? Partitioning { get; init; }

    public IReadOnlyList<TableOption> Options { get; init; } = [];

    /// <summary>The structure with the details a separate catalog read found.</summary>
    public TableStructure With(TableDetails details) =>
        this with { CheckConstraints = details.CheckConstraints, Partitioning = details.Partitioning, Options = details.Options };

    /// <summary>The value of one option, matched without regard to case; null when the engine did not report it.</summary>
    public string? Option(string name)
    {
        foreach (var option in Options)
        {
            if (string.Equals(option.Name, name, StringComparison.OrdinalIgnoreCase))
            {
                return option.Value;
            }
        }

        return null;
    }
}
