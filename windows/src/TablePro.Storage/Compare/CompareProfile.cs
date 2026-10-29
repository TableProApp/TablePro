using TablePro.Core.Compare;

namespace TablePro.Storage.Compare;

/// <summary>
/// A named comparison setup the user can reopen: both endpoints, the mode, which tables and how each is scoped, and
/// the options. Mirrors the macOS app's <c>CompareSyncProfile</c>. It holds no results; reopening one compares again.
/// </summary>
public sealed record CompareProfile
{
    public Guid Id { get; init; } = Guid.NewGuid();

    public string Name { get; init; } = string.Empty;

    public CompareEndpointScope Source { get; init; } = new();

    public CompareEndpointScope Target { get; init; } = new();

    public CompareMode Mode { get; init; }

    public DataCompareScope Scope { get; init; } = DataCompareScope.ChosenTables;

    /// <summary>
    /// The chosen pairs and their scopes. Under <see cref="DataCompareScope.WholeSchema"/> it keeps only the tables
    /// whose scope was changed, since every shared table is compared anyway.
    /// </summary>
    public IReadOnlyList<CompareProfileTable> Tables { get; init; } = [];

    public CompareProfileOptions Options { get; init; } = new();

    public DateTimeOffset CreatedAt { get; init; } = DateTimeOffset.UtcNow;

    public DateTimeOffset UpdatedAt { get; init; } = DateTimeOffset.UtcNow;
}

/// <summary>
/// One side of a saved comparison. The database is the one the connection pointed at when it was saved, kept so a
/// list of profiles can be told apart and a connection moved to another database can be noticed.
/// </summary>
public sealed record CompareEndpointScope
{
    public Guid ConnectionId { get; init; }

    public string? Database { get; init; }

    public string? Schema { get; init; }
}

/// <summary>A saved table pair and how it is compared.</summary>
public sealed record CompareProfileTable
{
    public string? SourceSchema { get; init; }

    public string Source { get; init; } = string.Empty;

    public string? TargetSchema { get; init; }

    public string Target { get; init; } = string.Empty;

    /// <summary>Whether the pair takes part in a run; a chosen-tables profile also remembers the unticked ones' scopes.</summary>
    public bool IsIncluded { get; init; } = true;

    public CompareTableScope Scope { get; init; } = CompareTableScope.Default;
}

/// <summary>The options a saved comparison restores, independent of the engine's internal tuning.</summary>
public sealed record CompareProfileOptions
{
    public bool InsertMissingRows { get; init; } = true;

    public bool UpdateChangedRows { get; init; } = true;

    public bool DeleteExtraRows { get; init; }

    public bool KeysIgnoreCase { get; init; }

    public double FloatTolerance { get; init; }

    public bool ApplyInBatches { get; init; }

    /// <summary>The row limit for every table without its own, in one-table scope the table's own.</summary>
    public long? RowLimit { get; init; }

    public bool DropExtraTables { get; init; }

    public bool DropExtraColumns { get; init; }
}

internal sealed record CompareProfilesDocument
{
    public int Version { get; init; } = 1;

    public IReadOnlyList<CompareProfile> Profiles { get; init; } = [];

    /// <summary>The setup the tab last held, kept apart from the named profiles so it never joins their list.</summary>
    public CompareProfile? LastSetup { get; init; }
}
