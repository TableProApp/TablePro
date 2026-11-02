using System.Runtime.InteropServices;
using System.Text;
using TablePro.Interop.Native;

namespace TablePro.Interop;

/// <summary>
/// Reads windows of display text from one result set through the core's C ABI. A cursor keeps its buffers
/// between fetches, so it belongs to one thread at a time, such as the grid's UI thread.
/// </summary>
public sealed unsafe class ResultCursor : IDisposable
{
    private readonly CursorHandle _handle;

    internal ResultCursor(ulong address)
    {
        _handle = new CursorHandle(checked((nint)address));
    }

    internal long Generation { get; private set; }

    /// <summary>
    /// Packs the rows from <paramref name="firstRow"/> and the columns from <paramref name="firstColumn"/> the
    /// set holds, up to the counts asked for, each cell cut at <paramref name="maxCharacters"/> on one line.
    /// The window stays readable until the next fetch or the dispose.
    /// </summary>
    public ResultWindow Fetch(long firstRow, int rowCount, int firstColumn, int columnCount, int maxCharacters)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(firstRow);
        ArgumentOutOfRangeException.ThrowIfNegative(rowCount);
        ArgumentOutOfRangeException.ThrowIfNegative(firstColumn);
        ArgumentOutOfRangeException.ThrowIfNegative(columnCount);
        ArgumentOutOfRangeException.ThrowIfNegative(maxCharacters);
        ObjectDisposedException.ThrowIf(_handle.IsClosed, this);
        var added = false;
        try
        {
            _handle.DangerousAddRef(ref added);
            var window = WindowMethods.tablepro_cursor_fetch(
                (TpCursor*)_handle.DangerousGetHandle(),
                (ulong)firstRow,
                (uint)rowCount,
                (uint)firstColumn,
                (uint)columnCount,
                (uint)maxCharacters);
            Generation++;
            if (window == null)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(maxCharacters),
                    "The window's text could pass 4 GiB. Ask for fewer cells or characters.");
            }

            return new ResultWindow(this, window, Generation);
        }
        finally
        {
            if (added)
            {
                _handle.DangerousRelease();
            }
        }
    }

    public void Dispose()
    {
        Generation++;
        _handle.Dispose();
    }

    private sealed class CursorHandle : SafeHandle
    {
        public CursorHandle(nint address)
            : base(IntPtr.Zero, ownsHandle: true)
        {
            SetHandle(address);
        }

        public override bool IsInvalid => handle == IntPtr.Zero;

        protected override bool ReleaseHandle()
        {
            WindowMethods.tablepro_cursor_free((TpCursor*)handle);
            return true;
        }
    }
}

/// <summary>
/// One fetched window. Rows and columns count from the window's first, and every cell read checks that no
/// later fetch or dispose has replaced the memory it reads.
/// </summary>
public readonly unsafe ref struct ResultWindow
{
    private readonly ResultCursor _cursor;
    private readonly TpWindow* _window;
    private readonly long _generation;

    internal ResultWindow(ResultCursor cursor, TpWindow* window, long generation)
    {
        _cursor = cursor;
        _window = window;
        _generation = generation;
    }

    public long FirstRow => (long)Window->first_row;

    /// <summary>The set's rows when the window was read, from the same moment as its cells.</summary>
    public long TotalRows => (long)Window->total_rows;

    public int RowCount => (int)Window->row_count;

    public int FirstColumn => (int)Window->first_column;

    public int ColumnCount => (int)Window->column_count;

    /// <summary>True once the set holds every row it will.</summary>
    public bool IsFinished => Window->finished != 0;

    private TpWindow* Window
    {
        get
        {
            if (_cursor is null || _cursor.Generation != _generation)
            {
                throw new InvalidOperationException("A later fetch or a dispose replaced this window.");
            }

            return _window;
        }
    }

    public ValueKind GetColumnKind(int column)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(column);
        ArgumentOutOfRangeException.ThrowIfGreaterThanOrEqual(column, ColumnCount);
        return (ValueKind)Window->column_kinds[column];
    }

    /// <summary>What the cell holds, which says what <see cref="GetRaw"/> means. A null has the column's.</summary>
    public ValueKind GetKind(int row, int column) => (ValueKind)Window->cell_kinds[Cell(row, column)];

    public bool IsNull(int row, int column) => Bit(Window->nulls, Cell(row, column));

    /// <summary>True when the text was cut at the fetch's character cap.</summary>
    public bool IsTruncated(int row, int column) => Bit(Window->truncated, Cell(row, column));

    /// <summary>The value as a number, by the cell's <see cref="ValueKind"/>, for locale formatting.</summary>
    public long GetRaw(int row, int column) => Window->raw[Cell(row, column)];

    public ReadOnlySpan<byte> GetUtf8(int row, int column)
    {
        var cell = Cell(row, column);
        var window = Window;
        var start = window->offsets[cell];
        return new ReadOnlySpan<byte>(window->text + start, (int)(window->offsets[cell + 1] - start));
    }

    /// <summary>The cell's display text, or null for SQL NULL.</summary>
    public string? GetText(int row, int column) =>
        IsNull(row, column) ? null : Encoding.UTF8.GetString(GetUtf8(row, column));

    private int Cell(int row, int column)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(row);
        ArgumentOutOfRangeException.ThrowIfNegative(column);
        ArgumentOutOfRangeException.ThrowIfGreaterThanOrEqual(row, RowCount);
        ArgumentOutOfRangeException.ThrowIfGreaterThanOrEqual(column, ColumnCount);
        return (column * RowCount) + row;
    }

    private static bool Bit(byte* bits, int index) => (bits[index >> 3] & (1 << (index & 7))) != 0;
}
