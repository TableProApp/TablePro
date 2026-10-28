using System.Runtime.CompilerServices;
using TablePro.Core.Browse;
using TablePro.Core.Drivers;
using TablePro.Core.Schema;

namespace TablePro.Core.Compare;

/// <summary>
/// Reads one side of a comparison from a session in key order, one chunk per round trip, so only a chunk of rows is
/// held at a time however large the table is.
/// </summary>
/// <remarks>
/// Paging goes through <see cref="IDatabaseSession.BrowseAsync"/>, the one read every engine implements, sorted on
/// the key. A keyset seek (<c>WHERE key &gt; last</c>) would be cheaper on the server, but the browse filter binds
/// its values as text, which PostgreSQL refuses to compare with an integer column.
/// </remarks>
public static class SessionRowSource
{
    /// <summary>The source side of <paramref name="spec"/>.</summary>
    public static IAsyncEnumerable<object?[]> Source(IDatabaseSession session, DataCompareSpec spec, DataCompareOptions options, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(spec);
        ArgumentNullException.ThrowIfNull(options);
        return ReadAsync(session, spec.SourceTable, spec.SourceColumnNames, spec.SourceKeyColumns, spec.SourceFilter, options.ChunkSize, ReadLimit(options), cancellationToken);
    }

    /// <summary>The target side of <paramref name="spec"/>.</summary>
    public static IAsyncEnumerable<object?[]> Target(IDatabaseSession session, DataCompareSpec spec, DataCompareOptions options, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(spec);
        ArgumentNullException.ThrowIfNull(options);
        return ReadAsync(session, spec.TargetTable, spec.TargetColumnNames, spec.TargetKeyColumns, spec.TargetFilter, options.ChunkSize, ReadLimit(options), cancellationToken);
    }

    /// <summary>
    /// Rows of <paramref name="table"/> projected onto <paramref name="columns"/>, ordered by <paramref name="keyColumns"/>,
    /// stopping after <paramref name="maxRows"/> rows or at the end when it is null.
    /// </summary>
    public static async IAsyncEnumerable<object?[]> ReadAsync(
        IDatabaseSession session,
        ObjectName table,
        IReadOnlyList<string> columns,
        IReadOnlyList<string> keyColumns,
        BrowseFilter filter,
        int chunkSize,
        long? maxRows,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(session);
        ArgumentNullException.ThrowIfNull(columns);
        ArgumentNullException.ThrowIfNull(keyColumns);
        ArgumentOutOfRangeException.ThrowIfLessThan(chunkSize, 1);

        var sort = keyColumns.Select(k => new SortColumn(k, Descending: false)).ToArray();
        long read = 0;
        var offset = 0;
        while (maxRows is not { } limit || read < limit)
        {
            var take = maxRows is { } max ? (int)Math.Min(chunkSize, max - read) : chunkSize;
            var page = await session.BrowseAsync(new BrowseRequest(table, filter, sort, offset, take), cancellationToken);
            // Some drivers report no columns for an empty page, so a page with no rows is not checked for them.
            var map = page.RowCount == 0 ? null : Map(page.Columns, columns, table);
            foreach (var row in page.Rows)
            {
                yield return map is null ? row : Project(row, map);
            }

            read += page.RowCount;
            if (page.RowCount < take)
            {
                yield break;
            }

            offset = checked(offset + page.RowCount);
        }
    }

    // The engine looks one row past the limit to tell a cut-short table from one that ends there.
    private static long? ReadLimit(DataCompareOptions options) => options.RowLimit is { } limit ? limit + 1 : null;

    /// <summary>Where each wanted column sits in the page, or null when the page is already in that order.</summary>
    private static int[]? Map(IReadOnlyList<Results.ResultColumn> available, IReadOnlyList<string> wanted, ObjectName table)
    {
        var map = new int[wanted.Count];
        var identity = available.Count == wanted.Count;
        for (var i = 0; i < wanted.Count; i++)
        {
            var index = -1;
            for (var j = 0; j < available.Count; j++)
            {
                if (string.Equals(available[j].Name, wanted[i], StringComparison.OrdinalIgnoreCase))
                {
                    index = j;
                    break;
                }
            }

            if (index < 0)
            {
                throw new CompareException($"{table} has no column {wanted[i]} any more. Compare again to read its current columns.");
            }

            map[i] = index;
            identity &= index == i;
        }

        return identity ? null : map;
    }

    private static object?[] Project(object?[] row, int[] map)
    {
        var projected = new object?[map.Length];
        for (var i = 0; i < map.Length; i++)
        {
            projected[i] = row[map[i]];
        }

        return projected;
    }
}
