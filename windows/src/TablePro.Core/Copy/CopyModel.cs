using TablePro.Core.Drivers;
using TablePro.Core.Schema;

namespace TablePro.Core.Copy;

/// <summary>Which halves of an object take part.</summary>
public enum CopyContent
{
    StructureAndData,
    Structure,
    Data,
}

/// <summary>
/// What to do about an object the target already has. There is no silent default on macOS either: replacing is a drop,
/// and adding rows to a table that already holds them duplicates them, so the choice is made before the run.
/// </summary>
public enum CopyExistingPolicy
{
    Skip,

    /// <summary>Drops and creates it again; with data only, empties the table instead.</summary>
    Replace,

    /// <summary>Adds the source's rows to the table; a view or routine that exists is skipped.</summary>
    AppendData,
}

public enum CopyErrorHandling
{
    /// <summary>The first failure ends the run; what ran before it stays.</summary>
    Stop,

    /// <summary>A failed object is reported and the run goes on with the next.</summary>
    SkipAndContinue,
}

/// <summary>What the user asked to copy, from which session to which, and how.</summary>
public sealed record CopyRequest(
    IDatabaseSession Source,
    IReadOnlyList<DatabaseObject> Objects,
    IDatabaseSession Target,
    string? TargetSchema,
    CopyContent Content = CopyContent.StructureAndData,
    CopyExistingPolicy ExistingPolicy = CopyExistingPolicy.Skip,
    CopyErrorHandling ErrorHandling = CopyErrorHandling.Stop)
{
    /// <summary>Rows read per page and inserted per transaction.</summary>
    public int BatchSize { get; init; } = 500;

    public bool IncludesStructure => Content != CopyContent.Data;

    public bool IncludesData => Content != CopyContent.Structure;
}

public enum CopyAction
{
    Create,

    /// <summary>Drop and create; for data only, empty the table.</summary>
    Replace,
    Append,
    Skip,
}

/// <summary>One table of the copy: how its columns, indexes and keys read in the target, and what the run does with it.</summary>
public sealed record CopyTablePlan(DatabaseObject Source, TableStructure Structure, ObjectName Target, CopyAction Action)
{
    /// <summary>The target's CREATE TABLE columns, in the source's order.</summary>
    public IReadOnlyList<ColumnDefinition> Columns { get; init; } = [];

    public IReadOnlyList<IndexDefinition> Indexes { get; init; } = [];

    /// <summary>Added after every table's rows are in, so rows can arrive in any order: the macOS copy defers its checks to the commit the same way.</summary>
    public IReadOnlyList<ForeignKeyDefinition> ForeignKeys { get; init; } = [];

    /// <summary>The columns each copied row writes, source name to target name.</summary>
    public IReadOnlyList<(string Source, string Target)> InsertColumns { get; init; } = [];

    /// <summary>The target type of each written column, for converting values.</summary>
    public IReadOnlyDictionary<string, SqlTypeShape> TargetShapes { get; init; } = new Dictionary<string, SqlTypeShape>();

    /// <summary>The columns pages are read in order of, so offset paging never skips or repeats a row.</summary>
    public IReadOnlyList<string> PageOrder { get; init; } = [];

    /// <summary>Approximations and dropped parts the review shows before anything runs.</summary>
    public IReadOnlyList<string> Notes { get; init; } = [];

    /// <summary>Identity columns whose sequence is moved past the copied rows afterwards.</summary>
    public IReadOnlyList<string> IdentityColumns { get; init; } = [];
}

/// <summary>A view, routine or sequence, copied as its definition with the source schema replaced by the target's.</summary>
public sealed record CopyDefinitionPlan(DatabaseObject Source, ObjectName Target, CopyAction Action)
{
    public IReadOnlyList<string> Notes { get; init; } = [];
}

public sealed record CopyPlan(IReadOnlyList<CopyTablePlan> Tables, IReadOnlyList<CopyDefinitionPlan> Definitions)
{
    /// <summary>Whether the types are translated, because the two engines do not share a type system.</summary>
    public bool CrossesEngines { get; init; }

    /// <summary>Problems with the copy as a whole, such as a target with no DDL support.</summary>
    public IReadOnlyList<string> Warnings { get; init; } = [];

    public bool IsEmpty => Tables.All(t => t.Action == CopyAction.Skip) && Definitions.All(d => d.Action == CopyAction.Skip);
}

public enum CopyPhase
{
    Preparing,
    Dropping,
    Creating,
    CopyingRows,
    Indexing,
    LinkingKeys,
    Definitions,
    Finished,
}

public sealed record CopyProgress(CopyPhase Phase, string? Object, long RowsCopied, long? ObjectRows, long? ObjectTotal);

public enum CopyOutcomeStatus
{
    Copied,
    Skipped,
    Failed,
    Cancelled,
}

public sealed record CopyObjectOutcome(string Name, CopyOutcomeStatus Status, long RowsCopied, string? Error = null)
{
    public IReadOnlyList<string> Notes { get; init; } = [];
}

public sealed record CopyResult(IReadOnlyList<CopyObjectOutcome> Outcomes, bool Cancelled)
{
    public long RowsCopied => Outcomes.Sum(o => o.RowsCopied);

    public bool Succeeded => !Cancelled && Outcomes.All(o => o.Status is CopyOutcomeStatus.Copied or CopyOutcomeStatus.Skipped);
}
