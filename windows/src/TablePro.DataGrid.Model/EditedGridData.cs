using System.Collections.ObjectModel;

namespace TablePro.DataGrid.Model;

// Rows are the data's, then the new rows; columns follow ColumnOrder, so the grid works in display columns only.
public sealed class EditedGridData : IGridData
{
    private GridEdits _edits;
    private ColumnArrangement? _arrangement;

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

    // Display position to data column: every data column in order until Arrange.
    public IReadOnlyList<int> ColumnOrder =>
        Volatile.Read(ref _arrangement)?.Order ?? Array.AsReadOnly(Enumerable.Range(0, Data.ColumnCount).ToArray());

    public int RowCount => Data.RowCount + Edits.AddedRows;

    public int ColumnCount => Volatile.Read(ref _arrangement)?.Count ?? Data.ColumnCount;

    public string GetColumnName(int column) => Data.GetColumnName(DataColumn(column));

    // On the UI thread, then the grid's RearrangeColumns; a reader keeps the order it opened with, as with the edits.
    public void Arrange(IReadOnlyList<int> order)
    {
        ArgumentNullException.ThrowIfNull(order);
        Volatile.Write(ref _arrangement, new ColumnArrangement(order, Data.ColumnCount));
    }

    public int DataColumn(int column)
    {
        var arrangement = Volatile.Read(ref _arrangement);
        ArgumentOutOfRangeException.ThrowIfNegative(column);
        ArgumentOutOfRangeException.ThrowIfGreaterThanOrEqual(column, arrangement?.Count ?? Data.ColumnCount);
        return arrangement?.DataColumn(column) ?? column;
    }

    // -1 for a hidden column.
    public int DisplayColumn(int dataColumn)
    {
        if (dataColumn < 0 || dataColumn >= Data.ColumnCount)
        {
            return -1;
        }
        return Volatile.Read(ref _arrangement)?.DisplayColumn(dataColumn) ?? dataColumn;
    }

    // A pending value on a data row, in display columns.
    public bool IsCellEdited(int row, int column)
    {
        var arrangement = Volatile.Read(ref _arrangement);
        if (row < 0 || row >= Data.RowCount || column < 0 || column >= (arrangement?.Count ?? Data.ColumnCount))
        {
            return false;
        }
        return Edits.TryGetCell(row, arrangement?.DataColumn(column) ?? column, out _);
    }

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
        return new Reader(Data, Data.OpenReader(), edits, Volatile.Read(ref _arrangement));
    }

    private sealed class ColumnArrangement
    {
        private readonly int[] _order;
        private readonly int[] _display;

        public ColumnArrangement(IReadOnlyList<int> order, int dataColumns)
        {
            if (order.Count == 0)
            {
                throw new ArgumentException("The order shows no column.", nameof(order));
            }
            _order = new int[order.Count];
            _display = new int[dataColumns];
            Array.Fill(_display, -1);
            for (var position = 0; position < order.Count; position++)
            {
                var column = order[position];
                ArgumentOutOfRangeException.ThrowIfNegative(column, nameof(order));
                ArgumentOutOfRangeException.ThrowIfGreaterThanOrEqual(column, dataColumns, nameof(order));
                if (_display[column] >= 0)
                {
                    throw new ArgumentException("The order shows a column twice.", nameof(order));
                }
                _order[position] = column;
                _display[column] = position;
            }
            Order = Array.AsReadOnly(_order);
        }

        public ReadOnlyCollection<int> Order { get; }

        public int Count => _order.Length;

        public int DataColumn(int column) => _order[column];

        public int DisplayColumn(int dataColumn) => dataColumn < _display.Length ? _display[dataColumn] : -1;
    }

    // Display columns whose data columns follow on: one read of the data each, so the data's order costs one read.
    private readonly record struct Run(int Data, int Count);

    private sealed class Reader(IGridData data, IGridReader inner, GridEdits edits, ColumnArrangement? arrangement)
        : IGridReader
    {
        private readonly List<CellBlock> _scratch = [];
        private readonly List<Run> _runs = [];

        private int ColumnCount => arrangement?.Count ?? data.ColumnCount;

        public bool KeepsLineBreaks
        {
            get => inner.KeepsLineBreaks;
            set => inner.KeepsLineBreaks = value;
        }

        // The data's rows come from its own reader into scratch blocks; new rows are never asked of the data.
        public void Read(int firstRow, int rowCount, int firstColumn, int columnCount, int maxCharacters, CellBlock block)
        {
            ArgumentNullException.ThrowIfNull(block);
            var dataRows = data.RowCount;
            var columns = firstColumn < 0 ? 0 : Math.Clamp(ColumnCount - firstColumn, 0, Math.Max(0, columnCount));
            var wanted = Math.Clamp(dataRows - firstRow, 0, Math.Max(0, rowCount));
            var read = wanted;
            FindRuns(firstColumn, columns);
            if (wanted > 0 && columns > 0)
            {
                for (var index = 0; index < _runs.Count; index++)
                {
                    var run = _runs[index];
                    inner.Read(firstRow, wanted, run.Data, run.Count, maxCharacters, _scratch[index]);
                    read = Math.Min(read, _scratch[index].RowCount);
                }
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
            block.Reset(firstRow, read + added, firstColumn, columns, maxCharacters, KeepsLineBreaks);
            block.EnsureCapacity(Characters(firstRow, read, firstAdded, added, maxCharacters));
            for (var index = 0; index < _runs.Count; index++)
            {
                var run = _runs[index];
                var scratch = _scratch[index];
                for (var dataColumn = run.Data; dataColumn < run.Data + run.Count; dataColumn++)
                {
                    for (var row = firstRow; row < firstRow + read; row++)
                    {
                        if (edits.IsDeleted(row))
                        {
                            block.Add(scratch.Get(row, dataColumn), CellState.Deleted);
                        }
                        else if (edits.TryGetCell(row, dataColumn, out var pending))
                        {
                            Add(block, pending, CellState.Modified);
                        }
                        else
                        {
                            block.Add(scratch.Get(row, dataColumn));
                        }
                    }
                    for (var addedRow = firstAdded; addedRow < firstAdded + added; addedRow++)
                    {
                        Add(block, edits.GetAddedCell(addedRow, dataColumn), CellState.Inserted);
                    }
                }
            }
        }

        // The pending text, null for NULL and "" for DEFAULT; a deleted row keeps the data's value.
        public string? ReadWhole(int row, int column)
        {
            if (column < 0 || column >= ColumnCount)
            {
                return null;
            }
            var dataColumn = arrangement?.DataColumn(column) ?? column;
            var dataRows = data.RowCount;
            if (row >= dataRows)
            {
                return row - dataRows < edits.AddedRows ? Whole(edits.GetAddedCell(row - dataRows, dataColumn)) : null;
            }
            return !edits.IsDeleted(row) && edits.TryGetCell(row, dataColumn, out var pending)
                ? Whole(pending)
                : inner.ReadWhole(row, dataColumn);
        }

        public void Dispose() => inner.Dispose();

        private void FindRuns(int firstColumn, int columns)
        {
            _runs.Clear();
            for (var column = firstColumn; column < firstColumn + columns; column++)
            {
                var dataColumn = arrangement?.DataColumn(column) ?? column;
                if (_runs.Count > 0 && _runs[^1].Data + _runs[^1].Count == dataColumn)
                {
                    _runs[^1] = _runs[^1] with { Count = _runs[^1].Count + 1 };
                }
                else
                {
                    _runs.Add(new Run(dataColumn, 1));
                }
            }
            while (_scratch.Count < _runs.Count)
            {
                _scratch.Add(new CellBlock());
            }
        }

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
        private int Characters(int firstRow, int read, int firstAdded, int added, int maxCharacters)
        {
            var characters = 0;
            for (var index = 0; index < _runs.Count; index++)
            {
                var run = _runs[index];
                var scratch = _scratch[index];
                for (var dataColumn = run.Data; dataColumn < run.Data + run.Count; dataColumn++)
                {
                    for (var row = firstRow; row < firstRow + read; row++)
                    {
                        characters += !edits.IsDeleted(row) && edits.TryGetCell(row, dataColumn, out var pending)
                            ? Typed(pending, maxCharacters)
                            : scratch.Get(row, dataColumn).Text.Length;
                    }
                    for (var addedRow = firstAdded; addedRow < firstAdded + added; addedRow++)
                    {
                        characters += Typed(edits.GetAddedCell(addedRow, dataColumn), maxCharacters);
                    }
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
