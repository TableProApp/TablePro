using System.Collections.Concurrent;
using System.Globalization;

namespace TablePro.Drivers.Redis;

/// <summary>
/// Turns cursor scans (HSCAN, SSCAN) into the grid's offset pages. The cursor where a page ended is kept, so the next
/// page resumes there instead of scanning from the start again; any other offset scans from the start and skips.
/// </summary>
internal sealed class RedisScanPager
{
    private const int MaxPositions = 256;

    private readonly ConcurrentDictionary<(int Database, string Key, string Verb), Position> _positions = new();

    /// <summary>One scan step: the cursor to send, and the next cursor with the flat items the server replied.</summary>
    public delegate Task<(string Cursor, IReadOnlyList<RedisReply> Items)> ScanStep(string cursor, CancellationToken cancellationToken);

    /// <summary>
    /// Up to <paramref name="limit"/> rows starting at <paramref name="offset"/>, each <paramref name="width"/> items
    /// wide (two for a hash's field and value), flattened, and whether the scan holds more.
    /// </summary>
    public async Task<(IReadOnlyList<RedisReply> Items, bool More)> PageAsync(
        int database, string key, string verb, int width, long offset, int limit, ScanStep scan, CancellationToken cancellationToken)
    {
        var id = (database, key, verb);
        var start = _positions.TryGetValue(id, out var saved) && saved.Offset <= offset ? saved : Position.Start;
        var skip = offset - start.Offset;
        var pending = new Queue<RedisReply[]>(start.Pending);
        var cursor = start.Cursor;
        var page = new List<RedisReply>(Math.Min(limit, 1024) * width);
        var rows = 0;
        while (rows < limit)
        {
            if (pending.TryDequeue(out var group))
            {
                if (skip > 0)
                {
                    skip--;
                    continue;
                }

                page.AddRange(group);
                rows++;
                continue;
            }

            if (cursor is null)
            {
                break;
            }

            cancellationToken.ThrowIfCancellationRequested();
            var (next, items) = await scan(cursor, cancellationToken);
            for (var i = 0; i + width <= items.Count; i += width)
            {
                var chunk = new RedisReply[width];
                for (var j = 0; j < width; j++)
                {
                    chunk[j] = items[i + j];
                }

                pending.Enqueue(chunk);
            }

            cursor = next == "0" ? null : next;
        }

        var more = pending.Count > 0 || cursor is not null;
        if (more)
        {
            if (_positions.Count >= MaxPositions)
            {
                _positions.Clear();
            }

            _positions[id] = new Position(offset + rows, cursor, [.. pending]);
        }
        else
        {
            _positions.TryRemove(id, out _);
        }

        return (page, more);
    }

    /// <summary>Forgets saved cursors for a key, after a save changed what it holds.</summary>
    public void Forget(int database, string key)
    {
        foreach (var id in _positions.Keys)
        {
            if (id.Database == database && id.Key == key)
            {
                _positions.TryRemove(id, out _);
            }
        }
    }

    /// <summary>
    /// The smallest stream id after <paramref name="id"/>, for XRANGE to resume past the last entry it returned on
    /// servers older than 6.2, which lack the exclusive <c>(</c> bound.
    /// </summary>
    public static string NextStreamId(string id)
    {
        var dash = id.IndexOf('-', StringComparison.Ordinal);
        if (dash < 0)
        {
            return ulong.TryParse(id, NumberStyles.None, CultureInfo.InvariantCulture, out var ms) ? string.Create(CultureInfo.InvariantCulture, $"{ms}-1") : id;
        }

        var milliseconds = ulong.Parse(id.AsSpan(0, dash), NumberStyles.None, CultureInfo.InvariantCulture);
        var sequence = ulong.Parse(id.AsSpan(dash + 1), NumberStyles.None, CultureInfo.InvariantCulture);
        return sequence == ulong.MaxValue
            ? string.Create(CultureInfo.InvariantCulture, $"{milliseconds + 1}-0")
            : string.Create(CultureInfo.InvariantCulture, $"{milliseconds}-{sequence + 1}");
    }

    private sealed record Position(long Offset, string? Cursor, RedisReply[][] Pending)
    {
        public static readonly Position Start = new(0, "0", []);
    }
}
