namespace TablePro.DataGrid.Model;

// The data with the edits laid over it. Grid rows are the data's rows, then the new rows.
public sealed class EditedGridData : IGridData
{
    private GridEdits _edits;

    public EditedGridData(IGridData data, GridEdits edits)
    {
        ArgumentNullException.ThrowIfNull(data);
        ArgumentNullException.ThrowIfNull(edits);
        Data = data;
        _edits = edits;
    }

    public IGridData Data { get; }

    // The host swaps it on the UI thread and calls the grid's EditsChanged; a copy reads it from a pool thread.
    public GridEdits Edits
    {
        get => Volatile.Read(ref _edits);
        set
        {
            ArgumentNullException.ThrowIfNull(value);
            Volatile.Write(ref _edits, value);
        }
    }

    public int RowCount => Data.RowCount + Edits.AddedRows;

    public int ColumnCount => Data.ColumnCount;

    public string GetColumnName(int column) => Data.GetColumnName(column);

    public bool IsColumnMasked(int column) => Data.IsColumnMasked(column);

    public RowMark GetRowMark(int row)
    {
        var edits = Edits;
        var dataRows = Data.RowCount;
        if (row < 0)
        {
            return RowMark.None;
        }
        if (row >= dataRows)
        {
            return row - dataRows < edits.AddedRows ? RowMark.Inserted : RowMark.None;
        }
        return edits.IsDeleted(row) ? RowMark.Deleted : edits.IsModified(row) ? RowMark.Modified : RowMark.None;
    }

    // The reader keeps the edits as they are now, so it never sees half a change.
    public IGridReader OpenReader() => OpenReader(Edits);

    // A copy takes the edits on the UI thread and opens its reader on a pool thread.
    public IGridReader OpenReader(GridEdits edits)
    {
        ArgumentNullException.ThrowIfNull(edits);
        return new Reader(Data, Data.OpenReader(), edits);
    }

    private sealed class Reader(IGridData data, IGridReader inner, GridEdits edits) : IGridReader
    {
        private readonly CellBlock _scratch = new();

        // The data's rows come from its own reader into a scratch block; new rows are never asked of the data.
        public void Read(int firstRow, int rowCount, int firstColumn, int columnCount, int maxCharacters, CellBlock block)
        {
            ArgumentNullException.ThrowIfNull(block);
            var dataRows = data.RowCount;
            var columns = Math.Clamp(data.ColumnCount - firstColumn, 0, Math.Max(0, columnCount));
            var wanted = Math.Clamp(dataRows - firstRow, 0, Math.Max(0, rowCount));
            var read = wanted;
            if (wanted > 0 && columns > 0)
            {
                inner.Read(firstRow, wanted, firstColumn, columns, maxCharacters, _scratch);
                read = Math.Min(wanted, _scratch.RowCount);
            }
            var added = 0;
            var firstAdded = 0;
            // New rows follow the data's last row, so a data read that stopped short leaves them out.
            if (read == wanted)
            {
                var start = Math.Max(firstRow, dataRows);
                var end = (int)Math.Min((long)firstRow + rowCount, (long)dataRows + edits.AddedRows);
                added = Math.Max(0, end - start);
                firstAdded = start - dataRows;
            }
            block.Reset(firstRow, read + added, firstColumn, columns, maxCharacters);
            block.EnsureCapacity(Characters(firstRow, read, firstColumn, columns, firstAdded, added, maxCharacters));
            for (var column = firstColumn; column < firstColumn + columns; column++)
            {
                for (var row = firstRow; row < firstRow + read; row++)
                {
                    if (edits.IsDeleted(row))
                    {
                        block.Add(_scratch.Get(row, column), CellState.Deleted);
                    }
                    else if (edits.TryGetCell(row, column, out var pending))
                    {
                        Add(block, pending, CellState.Modified);
                    }
                    else
                    {
                        block.Add(_scratch.Get(row, column));
                    }
                }
                for (var index = firstAdded; index < firstAdded + added; index++)
                {
                    Add(block, edits.GetAddedCell(index, column), CellState.Inserted);
                }
            }
        }

        // The pending text, null for NULL and "" for DEFAULT; a deleted row keeps the data's value.
        public string? ReadWhole(int row, int column)
        {
            var dataRows = data.RowCount;
            if (row >= dataRows)
            {
                return row - dataRows < edits.AddedRows ? Whole(edits.GetAddedCell(row - dataRows, column)) : null;
            }
            return !edits.IsDeleted(row) && edits.TryGetCell(row, column, out var pending)
                ? Whole(pending)
                : inner.ReadWhole(row, column);
        }

        public void Dispose() => inner.Dispose();

        private static void Add(CellBlock block, PendingCell pending, CellState marks)
        {
            switch (pending.Kind)
            {
                case PendingKind.Null:
                    block.AddNull(marks);
                    break;
                case PendingKind.Default:
                    block.AddDefault(marks);
                    break;
                default:
                    block.AddTyped(pending.Text, marks);
                    break;
            }
        }

        private static string? Whole(PendingCell pending) => pending.Kind switch
        {
            PendingKind.Null => null,
            PendingKind.Default => string.Empty,
            _ => pending.Text ?? string.Empty,
        };

        // One more per typed cell for a cut mark.
        private int Characters(int firstRow, int read, int firstColumn, int columns, int firstAdded, int added,
            int maxCharacters)
        {
            var characters = 0;
            for (var column = firstColumn; column < firstColumn + columns; column++)
            {
                for (var row = firstRow; row < firstRow + read; row++)
                {
                    characters += !edits.IsDeleted(row) && edits.TryGetCell(row, column, out var pending)
                        ? Typed(pending, maxCharacters)
                        : _scratch.Get(row, column).Text.Length;
                }
                for (var index = firstAdded; index < firstAdded + added; index++)
                {
                    characters += Typed(edits.GetAddedCell(index, column), maxCharacters);
                }
            }
            return characters;
        }

        private static int Typed(PendingCell pending, int maxCharacters)
        {
            if (pending.Kind != PendingKind.Value || pending.Text is null)
            {
                return 0;
            }
            return (maxCharacters > 0 ? Math.Min(pending.Text.Length, maxCharacters) : pending.Text.Length) + 1;
        }
    }
}
