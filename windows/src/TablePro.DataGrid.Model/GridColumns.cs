namespace TablePro.DataGrid.Model;

// Column widths and where each column sits. The grid has two panes: the frozen pane holds the row numbers and the
// first FrozenCount columns and never scrolls sideways; the scrolling pane holds the rest, from x = 0.
public sealed class GridColumns
{
    public const double MinimumWidth = 40;
    public const double MaximumWidth = 4000;

    private double[] _widths;
    private double[] _x;
    private int _frozenCount;
    private double _rowHeaderWidth;

    public GridColumns(int count, double width)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(count);
        _widths = new double[count];
        Array.Fill(_widths, Clamp(width));
        _x = new double[count + 1];
        Update();
    }

    public int Count => _widths.Length;

    public int Version { get; private set; }

    public int FrozenCount
    {
        get => _frozenCount;
        set
        {
            _frozenCount = Math.Clamp(value, 0, Count);
            Update();
        }
    }

    public double RowHeaderWidth
    {
        get => _rowHeaderWidth;
        set
        {
            _rowHeaderWidth = Math.Max(0, value);
            Update();
        }
    }

    public double ScrollWidth => _x[Count] - _x[_frozenCount];

    public double FrozenWidth => _rowHeaderWidth + _x[_frozenCount];

    public bool IsFrozen(int column) => column < _frozenCount;

    public double Width(int column) => _widths[column];

    // Columns before FrozenCount measure from the frozen pane's left edge, past the row numbers; the others from the
    // scrolling pane's.
    public double PaneX(int column) => column < _frozenCount ? _rowHeaderWidth + _x[column] : _x[column] - _x[_frozenCount];

    public void SetWidth(int column, double width)
    {
        _widths[column] = Clamp(width);
        Update();
    }

    public void Reset(int count, double width)
    {
        _widths = new double[count];
        Array.Fill(_widths, Clamp(width));
        _x = new double[count + 1];
        _frozenCount = Math.Min(_frozenCount, count);
        Update();
    }

    // The scrolling column under x, clamped to the pane; FrozenCount when the pane has no column.
    public int ScrollColumnAt(double x)
    {
        if (_frozenCount >= Count)
        {
            return Count;
        }
        var target = x + _x[_frozenCount];
        int low = _frozenCount, high = Count - 1;
        while (low < high)
        {
            var middle = (low + high + 1) / 2;
            if (_x[middle] <= target)
            {
                low = middle;
            }
            else
            {
                high = middle - 1;
            }
        }
        return low;
    }

    // The frozen column under x, or -1 over the row numbers. Clamped to the last frozen column.
    public int FrozenColumnAt(double x)
    {
        if (x < _rowHeaderWidth || _frozenCount == 0)
        {
            return -1;
        }
        var target = x - _rowHeaderWidth;
        for (var column = 0; column < _frozenCount; column++)
        {
            if (target < _x[column + 1])
            {
                return column;
            }
        }
        return _frozenCount - 1;
    }

    // The scrolling columns that meet [left, left + width), as (First, Last); Last < First when none do.
    public (int First, int Last) ScrollRange(double left, double width)
    {
        if (width <= 0 || _frozenCount >= Count)
        {
            return (_frozenCount, _frozenCount - 1);
        }
        return (ScrollColumnAt(Math.Max(0, left)), ScrollColumnAt(Math.Max(0, left + width - 0.5)));
    }

    private static double Clamp(double width) =>
        double.IsFinite(width) ? Math.Clamp(width, MinimumWidth, MaximumWidth) : MinimumWidth;

    private void Update()
    {
        for (var column = 0; column < _widths.Length; column++)
        {
            _x[column + 1] = _x[column] + _widths[column];
        }
        Version++;
    }
}
