using System.Text;

namespace TablePro.DataGrid.Model;

[Flags]
public enum CellState : byte
{
    None = 0,
    Null = 1,

    // The core cut the value at the fetch's cap. The text ends with an ellipsis the grid draws apart.
    Truncated = 2,

    RightToLeft = 4,

    // Outside what the data held when the block was read.
    Missing = 8,

    // The core shows control characters as spaces, so a copy reads text with a space whole.
    Lossy = 16,
}

public readonly ref struct CellText(ReadOnlySpan<char> text, CellState state)
{
    public ReadOnlySpan<char> Text { get; } = text;

    public CellState State { get; } = state;

    public bool IsNull => (State & CellState.Null) != 0;

    public bool IsTruncated => (State & CellState.Truncated) != 0;

    public bool IsRightToLeft => (State & CellState.RightToLeft) != 0;
}

// Refilled in place, so a scrolling grid makes no string or array per cell once its blocks exist.
public sealed class CellBlock
{
    public const char Ellipsis = '…';

    private char[] _chars = new char[8192];
    private int[] _starts = new int[1];
    private CellState[] _flags = [];
    private int _length;
    private int _cells;

    public int FirstRow { get; private set; }

    public int RowCount { get; private set; }

    public int FirstColumn { get; private set; }

    public int ColumnCount { get; private set; }

    public int MaxCharacters { get; private set; }

    internal long LastUse { get; set; }

    public bool Covers(int row, int column) =>
        row >= FirstRow && row < FirstRow + RowCount && column >= FirstColumn && column < FirstColumn + ColumnCount;

    public void Reset(int firstRow, int rowCount, int firstColumn, int columnCount, int maxCharacters)
    {
        FirstRow = firstRow;
        RowCount = Math.Max(0, rowCount);
        FirstColumn = firstColumn;
        ColumnCount = Math.Max(0, columnCount);
        MaxCharacters = maxCharacters;
        var cells = RowCount * ColumnCount;
        if (_starts.Length < cells + 1)
        {
            _starts = new int[cells + 1];
            _flags = new CellState[cells];
        }
        _length = 0;
        _cells = 0;
        _starts[0] = 0;
    }

    public void AddNull() => Close(CellState.Null);

    // Grows the buffer once for a window's text, where adding cell by cell would grow it several times.
    public void EnsureCapacity(int characters) => Reserve(characters - _length, exact: true);

    public void Add(ReadOnlySpan<byte> utf8, bool truncated, bool lossy = false)
    {
        Reserve(Encoding.UTF8.GetMaxCharCount(utf8.Length) + 1);
        var start = _length;
        _length += Encoding.UTF8.GetChars(utf8, _chars.AsSpan(_length));
        Finish(start, truncated, lossy);
    }

    // A cell another block already read, copied as it is.
    public void Add(CellText cell)
    {
        Reserve(cell.Text.Length);
        cell.Text.CopyTo(_chars.AsSpan(_length));
        _length += cell.Text.Length;
        Close(cell.State);
    }

    public void Add(ReadOnlySpan<char> text, bool truncated, bool lossy = false)
    {
        Reserve(text.Length + 1);
        var start = _length;
        text.CopyTo(_chars.AsSpan(_length));
        _length += text.Length;
        Finish(start, truncated, lossy);
    }

    // The span stays valid until the block is refilled.
    public CellText Get(int row, int column)
    {
        var cell = ((column - FirstColumn) * RowCount) + (row - FirstRow);
        if (!Covers(row, column) || cell >= _cells)
        {
            return new CellText([], CellState.Missing);
        }
        var start = _starts[cell];
        return new CellText(_chars.AsSpan(start, _starts[cell + 1] - start), _flags[cell]);
    }

    private void Finish(int start, bool truncated, bool lossy)
    {
        var flags = TextDirection.IsRightToLeft(_chars.AsSpan(start, _length - start)) ? CellState.RightToLeft : CellState.None;
        if (lossy)
        {
            flags |= CellState.Lossy;
        }
        if (truncated)
        {
            _chars[_length++] = Ellipsis;
            flags |= CellState.Truncated;
        }
        Close(flags);
    }

    private void Close(CellState flags)
    {
        if (_cells >= _flags.Length)
        {
            throw new InvalidOperationException("The block holds the cells Reset asked for.");
        }
        _flags[_cells] = flags;
        _cells++;
        _starts[_cells] = _length;
    }

    private void Reserve(int more, bool exact = false)
    {
        if (_length + more <= _chars.Length)
        {
            return;
        }
        var grown = new char[exact ? _length + more : Math.Max(_chars.Length * 2, _length + more)];
        _chars.AsSpan(0, _length).CopyTo(grown);
        _chars = grown;
    }
}
