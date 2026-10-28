namespace TablePro.Core.Results;

public sealed record ResultColumn(string Name, string DataType, Type ClrType)
{
    private static readonly System.Collections.Frozen.FrozenSet<Type> NumericTypes = System.Collections.Frozen.FrozenSet.Create(
        [typeof(int), typeof(long), typeof(short), typeof(byte), typeof(sbyte), typeof(ushort), typeof(uint), typeof(ulong),
         typeof(decimal), typeof(double), typeof(float), typeof(System.Numerics.BigInteger)]);

    // Computed rather than stored, so a `with` copy that changes ClrType stays consistent.
    public bool IsNumeric => NumericTypes.Contains(ClrType);
}

/// <summary>
/// Rows held row-major as the provider hands them over (<c>DbDataReader.GetValues</c>), with database nulls stored as
/// <see langword="null"/>. A result is written once by the reader and only read afterwards.
/// </summary>
public sealed class ResultSet
{
    private readonly List<object?[]> _rows;

    public ResultSet(IReadOnlyList<ResultColumn> columns, List<object?[]> rows, bool isTruncated = false)
    {
        Columns = columns;
        _rows = rows;
        IsTruncated = isTruncated;
    }

    public IReadOnlyList<ResultColumn> Columns { get; }

    public IReadOnlyList<object?[]> Rows => _rows;

    public int RowCount => _rows.Count;

    /// <summary>The reader stopped at the row limit and the server had more.</summary>
    public bool IsTruncated { get; }

    public object? this[int row, int column] => _rows[row][column];

    public int ColumnIndex(string name)
    {
        for (var i = 0; i < Columns.Count; i++)
        {
            if (string.Equals(Columns[i].Name, name, StringComparison.OrdinalIgnoreCase))
            {
                return i;
            }
        }

        return -1;
    }
}

/// <summary>What one statement produced: its result sets, the rows it changed, or the error that stopped it.</summary>
public sealed record StatementResult(
    string Sql,
    IReadOnlyList<ResultSet> ResultSets,
    int RecordsAffected,
    TimeSpan Elapsed,
    string? Error = null,
    IReadOnlyList<string>? Messages = null)
{
    public bool Succeeded => Error is null;
}

public sealed record ExecuteOptions(int RowLimit = 10_000, int CommandTimeoutSeconds = 0, bool StopOnError = true);
