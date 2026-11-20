namespace TablePro.DataGrid.Model;

// The rows of a grid that wraps its cells: a row is as tall as the lines of its tallest cell, one line until measured.
public sealed class RowHeights
{
    // The most lines a wrapped cell shows; text past them ends in an ellipsis.
    public const int MaximumLines = 10;

    // Rows per sum, so a row's top is one multiply, one sum read and a walk over at most this many bytes.
    private const int ChunkRows = 256;

    private byte[] _lines;
    private int[] _extra;
    private long[] _before;
    private int _settled;
    private long _extraLines;

    public RowHeights(int count, double pitch, double lineHeight)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(count);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(pitch);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(lineHeight);
        Count = count;
        Pitch = pitch;
        LineHeight = lineHeight;
        _lines = new byte[count];
        var chunks = Chunks(count);
        _extra = new int[chunks];
        _before = new long[chunks + 1];
    }

    public int Count { get; private set; }

    // The height of a row of one line.
    public double Pitch { get; }

    // What each line after the first adds.
    public double LineHeight { get; }

    public double Total => (Count * Pitch) + (_extraLines * LineHeight);

    public bool IsMeasured(int row) => row >= 0 && row < Count && _lines[row] != 0;

    public int LinesOf(int row) => row >= 0 && row < Count && _lines[row] > 1 ? _lines[row] : 1;

    public double HeightOf(int row) => Pitch + ((LinesOf(row) - 1) * LineHeight);

    // Where a row starts; the row past the last starts where the rows end.
    public double Top(int row)
    {
        row = Math.Clamp(row, 0, Count);
        var chunk = row / ChunkRows;
        long extra = Before(chunk);
        for (var at = chunk * ChunkRows; at < row; at++)
        {
            extra += LinesOf(at) - 1;
        }
        return (row * Pitch) + (extra * LineHeight);
    }

    // The row a y falls in, the first above the rows and the last below them.
    public int RowAt(double y)
    {
        if (Count == 0 || !(y > 0))
        {
            return 0;
        }
        var low = 0;
        var high = Chunks(Count) - 1;
        while (low < high)
        {
            var middle = (low + high + 1) / 2;
            if (ChunkTop(middle) <= y)
            {
                low = middle;
            }
            else
            {
                high = middle - 1;
            }
        }
        var top = ChunkTop(low);
        var last = Math.Min(Count, (low + 1) * ChunkRows) - 1;
        for (var row = low * ChunkRows; row < last; row++)
        {
            top += HeightOf(row);
            if (y < top)
            {
                return row;
            }
        }
        return last;
    }

    // Records a measured row and returns how much taller it became, negative when shorter.
    public double Set(int row, int lines)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(row);
        ArgumentOutOfRangeException.ThrowIfGreaterThanOrEqual(row, Count);
        var kept = (byte)Math.Clamp(lines, 1, MaximumLines);
        var change = kept - LinesOf(row);
        _lines[row] = kept;
        if (change == 0)
        {
            return 0;
        }
        var chunk = row / ChunkRows;
        _extra[chunk] += change;
        _extraLines += change;
        // The sums of the chunks after this one are stale until the next read asks for them.
        _settled = Math.Min(_settled, chunk);
        return change * LineHeight;
    }

    // Rows that arrived start at one line, after the rows held.
    public void Grow(int count)
    {
        if (count <= Count)
        {
            return;
        }
        Array.Resize(ref _lines, count);
        var chunks = Chunks(count);
        if (chunks > _extra.Length)
        {
            Array.Resize(ref _extra, chunks);
            Array.Resize(ref _before, chunks + 1);
        }
        Count = count;
    }

    // Every row is one line again, as before any was measured.
    public void Reset()
    {
        Array.Clear(_lines);
        Array.Clear(_extra);
        _settled = 0;
        _extraLines = 0;
    }

    private static int Chunks(int count) => (count + ChunkRows - 1) / ChunkRows;

    private double ChunkTop(int chunk) => ((double)chunk * ChunkRows * Pitch) + (Before(chunk) * LineHeight);

    // The extra lines of every row in the chunks before one, summed forward from the last chunk that changed.
    private long Before(int chunk)
    {
        for (var at = _settled; at < chunk; at++)
        {
            _before[at + 1] = _before[at] + _extra[at];
        }
        _settled = Math.Max(_settled, chunk);
        return _before[chunk];
    }
}
