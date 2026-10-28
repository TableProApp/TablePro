using TablePro.Core.Browse;
using TablePro.Core.Schema;

namespace TablePro.Core.Compare;

/// <summary>How values are judged equal, how far a comparison reads, and which kinds of difference a sync writes.</summary>
public sealed record DataCompareOptions
{
    public static readonly DataCompareOptions Default = new();

    /// <summary>Write rows that exist only in the source.</summary>
    public bool InsertMissingRows { get; init; } = true;

    /// <summary>Write the source's values over rows that differ.</summary>
    public bool UpdateChangedRows { get; init; } = true;

    /// <summary>Delete rows that exist only in the target. Off by default, as on macOS, because it loses data.</summary>
    public bool DeleteExtraRows { get; init; }

    /// <summary>The largest difference at which two floating-point values still count as equal. Zero means exact.</summary>
    public double FloatTolerance { get; init; }

    /// <summary>Fractional second digits two timestamps must agree on. Engines keep different precision.</summary>
    public int TimestampFractionalDigits { get; init; } = 6;

    /// <summary>Text keys sort case-insensitively, as a MySQL <c>_ci</c> or SQL Server <c>CI</c> collation does.</summary>
    public bool KeysIgnoreCase { get; init; }

    /// <summary>Rows read per round trip from each side.</summary>
    public int ChunkSize { get; init; } = 2_000;

    /// <summary>Read at most this many rows from each side; null reads the whole table.</summary>
    public long? RowLimit { get; init; }

    /// <summary>
    /// Differences kept for the grid and the sync plan. Beyond it the counts stay exact but the comparison is marked
    /// truncated and cannot be synced, so a plan never silently covers only part of the differences.
    /// </summary>
    public int MaxRetainedDifferences { get; init; } = 200_000;

    public bool Writes(RowDiffKind kind) => kind switch
    {
        RowDiffKind.OnlyInSource => InsertMissingRows,
        RowDiffKind.Changed => UpdateChangedRows,
        RowDiffKind.OnlyInTarget => DeleteExtraRows,
        _ => false,
    };
}

/// <summary>One compared column, named as each side spells it.</summary>
public sealed record ComparedColumn(string Source, string Target, bool IsKey, string? TargetDataType = null, bool TargetIsIdentity = false);

/// <summary>What to compare: two tables, the columns both sides share, and the columns that identify a row.</summary>
public sealed record DataCompareSpec
{
    private readonly int[] _keyIndexes;

    public DataCompareSpec(ObjectName sourceTable, ObjectName targetTable, IReadOnlyList<ComparedColumn> columns)
    {
        ArgumentNullException.ThrowIfNull(columns);
        SourceTable = sourceTable;
        TargetTable = targetTable;
        Columns = columns;
        _keyIndexes = [.. Enumerable.Range(0, columns.Count).Where(i => columns[i].IsKey)];
        if (_keyIndexes.Length == 0)
        {
            throw new CompareException("Choose at least one key column that identifies a row on both sides.");
        }
    }

    public ObjectName SourceTable { get; }

    public ObjectName TargetTable { get; }

    /// <summary>Every row a side yields is laid out in this order.</summary>
    public IReadOnlyList<ComparedColumn> Columns { get; }

    public ReadOnlySpan<int> KeyIndexes => _keyIndexes;

    public IReadOnlyList<string> SourceColumnNames => [.. Columns.Select(c => c.Source)];

    public IReadOnlyList<string> TargetColumnNames => [.. Columns.Select(c => c.Target)];

    public IReadOnlyList<string> SourceKeyColumns => [.. _keyIndexes.Select(i => Columns[i].Source)];

    public IReadOnlyList<string> TargetKeyColumns => [.. _keyIndexes.Select(i => Columns[i].Target)];

    /// <summary>Applied to the source when it is read. The target's own filter is <see cref="TargetFilter"/>.</summary>
    public BrowseFilter SourceFilter { get; init; } = BrowseFilter.None;

    public BrowseFilter TargetFilter { get; init; } = BrowseFilter.None;

    public bool IsKeyColumn(int column) => Array.IndexOf(_keyIndexes, column) >= 0;

    /// <summary>The key of a row as a person reads it.</summary>
    public string DescribeKey(object?[] row)
    {
        ArgumentNullException.ThrowIfNull(row);
        if (_keyIndexes.Length == 1)
        {
            return CompareValues.Describe(row[_keyIndexes[0]]);
        }

        return string.Join(", ", _keyIndexes.Select(i => CompareValues.Describe(row[i])));
    }

    /// <summary>
    /// The row's identity, which excluding a row from a sync keys on. A unit separator joins the parts so
    /// ("a", "b, c") and ("a, b", "c") never collide.
    /// </summary>
    public string KeyIdentity(object?[] row)
    {
        ArgumentNullException.ThrowIfNull(row);
        return string.Join('\u001F', _keyIndexes.Select(i => row[i] is null ? "\0" : CompareValues.Text(row[i]!)));
    }
}

public enum RowDiffKind : byte
{
    /// <summary>The row exists only in the source; a sync inserts it.</summary>
    OnlyInSource,

    /// <summary>The row exists only in the target; a sync deletes it when deletes are on.</summary>
    OnlyInTarget,

    /// <summary>Both sides have the key with different values; a sync updates the target.</summary>
    Changed,

    Identical,
}

/// <summary>One row's difference. Rows are laid out as <see cref="DataCompareSpec.Columns"/>.</summary>
public sealed class RowDiff(RowDiffKind kind, object?[]? source, object?[]? target, int[] changedColumns)
{
    public RowDiffKind Kind { get; } = kind;

    public object?[]? Source { get; } = source;

    public object?[]? Target { get; } = target;

    /// <summary>Indexes into <see cref="DataCompareSpec.Columns"/> whose values differ. Empty unless <see cref="Kind"/> is Changed.</summary>
    public IReadOnlyList<int> ChangedColumns => changedColumns;

    /// <summary>The row the key is read from: the source's when it has one.</summary>
    public object?[] KeyRow => Source ?? Target ?? [];

    public bool Differs(int column) => Array.IndexOf(changedColumns, column) >= 0;
}

/// <summary>Counts as rows are read, for a progress line.</summary>
public readonly record struct DataCompareProgress(long SourceRows, long TargetRows, long Differences);

/// <summary>What a data comparison found.</summary>
public sealed class DataDiffResult
{
    public required DataCompareSpec Spec { get; init; }

    public long OnlyInSourceCount { get; init; }

    public long OnlyInTargetCount { get; init; }

    public long ChangedCount { get; init; }

    public long IdenticalCount { get; init; }

    public long SourceRows { get; init; }

    public long TargetRows { get; init; }

    /// <summary>Rows left out because a key column held NULL, which can never identify one row.</summary>
    public long SkippedNullKeyCount { get; init; }

    /// <summary>A row limit cut the walk short; rows past it on either side were not compared.</summary>
    public bool StoppedAtRowLimit { get; init; }

    /// <summary>More differences were found than <see cref="DataCompareOptions.MaxRetainedDifferences"/> keeps.</summary>
    public bool IsTruncated { get; init; }

    public TimeSpan Elapsed { get; init; }

    /// <summary>Differences in key order, at most the retained limit.</summary>
    public required IReadOnlyList<RowDiff> Differences { get; init; }

    public long DifferenceCount => OnlyInSourceCount + OnlyInTargetCount + ChangedCount;

    public long Count(RowDiffKind kind) => kind switch
    {
        RowDiffKind.OnlyInSource => OnlyInSourceCount,
        RowDiffKind.OnlyInTarget => OnlyInTargetCount,
        RowDiffKind.Changed => ChangedCount,
        _ => IdenticalCount,
    };
}

/// <summary>A comparison or sync that cannot go on, with a message the user can act on.</summary>
public sealed class CompareException : Exception
{
    public CompareException()
    {
    }

    public CompareException(string message)
        : base(message)
    {
    }

    public CompareException(string message, Exception inner)
        : base(message, inner)
    {
    }
}
