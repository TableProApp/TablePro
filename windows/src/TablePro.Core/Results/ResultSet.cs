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

    /// <summary>What the driver could not do on the server for this page, such as a sort CQL cannot apply, shown under the grid.</summary>
    public IReadOnlyList<string> Notices { get; init; } = [];

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

/// <summary>How a channel runs a list of statements.</summary>
/// <param name="RowLimit">The most rows read from each result; the rest are left unread.</param>
/// <param name="CommandTimeoutSeconds">How long a statement may run, or 0 for no limit.</param>
/// <param name="StopOnError">Whether a failed statement skips the ones after it.</param>
/// <param name="EditorTransaction">
/// Whether the channel keeps the transaction an editor tab's writes open until a COMMIT or ROLLBACK typed there, on an
/// engine whose provider otherwise commits every statement (Oracle). Imports, copies and MCP calls leave it off, so
/// each statement they run commits as before and nothing is rolled back when their channel closes.
/// </param>
public sealed record ExecuteOptions(int RowLimit = 10_000, int CommandTimeoutSeconds = 0, bool StopOnError = true, bool EditorTransaction = false);
