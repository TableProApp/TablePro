using TablePro.Interop;

namespace TablePro.App.Model;

// Each cell's kind as the core typed it, read a window at a time with one character of text per cell.
public sealed class ResultSetKinds : ICellKinds, IDisposable
{
    private const int RowsPerRead = 512;

    private readonly ResultCursor _cursor;
    private readonly int _columns;
    private ValueKind?[] _kinds = [];
    private int _first = -1;
    private int _rows;

    public ResultSetKinds(ResultSet set, int columns)
    {
        ArgumentNullException.ThrowIfNull(set);
        ArgumentOutOfRangeException.ThrowIfNegative(columns);
        _columns = columns;
        _cursor = set.OpenCursor();
    }

    public ValueKind? Kind(int row, int column)
    {
        if (row < 0 || column < 0 || column >= _columns)
        {
            return null;
        }

        if (row < _first || row >= _first + _rows)
        {
            Load(row);
        }

        return row - _first < _rows ? _kinds[((row - _first) * _columns) + column] : null;
    }

    public void Dispose() => _cursor.Dispose();

    private void Load(int row)
    {
        var window = _cursor.Fetch(row, RowsPerRead, 0, _columns, 1);
        _first = row;
        _rows = window.RowCount;
        if (_kinds.Length < _rows * _columns)
        {
            _kinds = new ValueKind?[RowsPerRead * _columns];
        }

        Array.Clear(_kinds);
        for (var read = 0; read < _rows; read++)
        {
            for (var column = 0; column < window.ColumnCount && column < _columns; column++)
            {
                _kinds[(read * _columns) + column] = window.GetKind(read, column);
            }
        }
    }
}
