using TablePro.Core.Localization;

namespace TablePro.Core.Editing;

/// <summary>A pending edit from the grid, applied by the driver inside one transaction.</summary>
public abstract record RowChange;

/// <summary>Sets <see cref="Values"/> on the one row <see cref="Key"/> identifies.</summary>
public sealed record RowUpdate(IReadOnlyDictionary<string, object?> Key, IReadOnlyDictionary<string, object?> Values) : RowChange;

public sealed record RowInsert(IReadOnlyDictionary<string, object?> Values) : RowChange;

public sealed record RowDelete(IReadOnlyDictionary<string, object?> Key) : RowChange;

/// <summary>A save that would have touched more or fewer rows than the grid showed is rolled back.</summary>
public sealed class RowCountMismatchException(int expected, int actual, string statement)
    : InvalidOperationException(CoreStrings.Format("Editing/RowCountMismatch", actual, expected, statement))
{
    public int Expected { get; } = expected;

    public int Actual { get; } = actual;
}
