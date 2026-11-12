using System.Diagnostics;

namespace TablePro.DataGrid.Model;

// A full cache refills its least recently used block, so scrolling allocates nothing once it is full.
public sealed class CellCache : IDisposable
{
    // Small enough that a block of long text stays off the large object heap, whose allocations start gen2 GCs.
    public const int TileRows = 32;
    public const int TileColumns = 8;

    private readonly IGridReader _reader;
    private readonly int _capacity;
    private readonly Dictionary<long, CellBlock> _blocks;
    private long _clock;
    private CellBlock? _last;

    public CellCache(IGridReader reader, int capacity = 256)
    {
        _reader = reader;
        _capacity = Math.Max(4, capacity);
        _blocks = new Dictionary<long, CellBlock>(_capacity);
    }

    public long BlocksFetched { get; private set; }

    public double FetchMilliseconds { get; private set; }

    public int BlockCount => _blocks.Count;

    // The span in the result stays valid until the next Get, which may refill its block.
    public CellText Get(int row, int column, int maxCharacters)
    {
        var block = _last is not null && _last.Covers(row, column) && _last.MaxCharacters >= maxCharacters
            ? _last
            : Load(row, column, maxCharacters);
        block.LastUse = ++_clock;
        _last = block;
        return block.Get(row, column);
    }

    public string? ReadWhole(int row, int column) => _reader.ReadWhole(row, column);

    public void Clear()
    {
        _blocks.Clear();
        _last = null;
    }

    // Rows arrived: blocks that stopped short of a full tile are fetched again when next read.
    public void RowsChanged()
    {
        List<long>? partial = null;
        foreach (var (key, block) in _blocks)
        {
            if (block.RowCount < TileRows)
            {
                (partial ??= []).Add(key);
            }
        }
        if (partial is null)
        {
            return;
        }
        foreach (var key in partial)
        {
            _blocks.Remove(key);
        }
        _last = null;
    }

    public void Dispose() => _reader.Dispose();

    private CellBlock Load(int row, int column, int maxCharacters)
    {
        var tileRow = row / TileRows;
        var tileColumn = column / TileColumns;
        var key = ((long)tileRow << 24) | (uint)tileColumn;
        if (_blocks.TryGetValue(key, out var block) && block.MaxCharacters >= maxCharacters)
        {
            block.LastUse = ++_clock;
            return block;
        }
        if (block is null)
        {
            block = _blocks.Count >= _capacity ? Evict() : new CellBlock();
            _blocks[key] = block;
        }
        var started = Stopwatch.GetTimestamp();
        _reader.Read(tileRow * TileRows, TileRows, tileColumn * TileColumns, TileColumns, maxCharacters, block);
        FetchMilliseconds += Stopwatch.GetElapsedTime(started).TotalMilliseconds;
        BlocksFetched++;
        block.LastUse = ++_clock;
        return block;
    }

    private CellBlock Evict()
    {
        var oldestKey = 0L;
        CellBlock? oldest = null;
        foreach (var (key, block) in _blocks)
        {
            if (oldest is null || block.LastUse < oldest.LastUse)
            {
                oldest = block;
                oldestKey = key;
            }
        }
        _blocks.Remove(oldestKey);
        if (ReferenceEquals(_last, oldest))
        {
            _last = null;
        }
        return oldest!;
    }
}
