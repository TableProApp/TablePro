namespace TablePro.Storage.Library.History;

public enum DiffKind
{
    Unchanged,
    Added,
    Removed,
    Changed,
}

/// <summary>One row of a side-by-side diff: the older line, the newer line, or both.</summary>
public sealed record DiffPair(string? Before, string? After, DiffKind Kind);

public enum UnifiedLineKind
{
    Context,
    Added,
    Removed,
}

/// <summary>One row of a unified diff with the line numbers it has on each side.</summary>
public sealed record UnifiedDiffLine(int? BeforeLineNumber, int? AfterLineNumber, string Text, UnifiedLineKind Kind);

/// <summary>
/// A line diff by Myers' algorithm, the one Swift's <c>difference(from:)</c> runs for the macOS app, paired into rows
/// the same way: a removed line and an added line at the same step are one changed row.
/// </summary>
public static class LineDiff
{
    // The trace keeps one frontier per edit, so memory grows with the square of this. Past it the differing middle
    // is shown as replaced, which is still a correct diff, only not the shortest.
    private const int MaxEditDistance = 1024;

    /// <summary>Splits text into lines, folding CRLF and CR, and keeping blank lines because they are real differences in a file.</summary>
    public static string[] Lines(string content) =>
        content.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n').Split('\n');

    public static IReadOnlyList<DiffPair> Split(IReadOnlyList<string> before, IReadOnlyList<string> after)
    {
        var (removed, inserted) = EditScript(before, after);
        var pairs = new List<DiffPair>(Math.Max(before.Count, after.Count));
        int b = 0, a = 0;
        while (b < before.Count || a < after.Count)
        {
            var isRemoved = b < before.Count && removed[b];
            var isInserted = a < after.Count && inserted[a];
            if (isRemoved && isInserted)
            {
                pairs.Add(new DiffPair(before[b++], after[a++], DiffKind.Changed));
            }
            else if (isRemoved)
            {
                pairs.Add(new DiffPair(before[b++], null, DiffKind.Removed));
            }
            else if (isInserted)
            {
                pairs.Add(new DiffPair(null, after[a++], DiffKind.Added));
            }
            else if (b < before.Count && a < after.Count)
            {
                pairs.Add(new DiffPair(before[b++], after[a++], DiffKind.Unchanged));
            }
            else
            {
                break;
            }
        }

        return pairs;
    }

    /// <summary>Unified rows from already computed pairs, so a view that offers both layouts diffs once.</summary>
    public static IReadOnlyList<UnifiedDiffLine> Unified(IReadOnlyList<DiffPair> pairs)
    {
        var lines = new List<UnifiedDiffLine>(pairs.Count);
        int before = 1, after = 1;
        foreach (var pair in pairs)
        {
            switch (pair.Kind)
            {
                case DiffKind.Unchanged:
                    lines.Add(new UnifiedDiffLine(before++, after++, pair.Before ?? string.Empty, UnifiedLineKind.Context));
                    break;
                case DiffKind.Removed:
                    lines.Add(new UnifiedDiffLine(before++, null, pair.Before ?? string.Empty, UnifiedLineKind.Removed));
                    break;
                case DiffKind.Added:
                    lines.Add(new UnifiedDiffLine(null, after++, pair.After ?? string.Empty, UnifiedLineKind.Added));
                    break;
                default:
                    lines.Add(new UnifiedDiffLine(before++, null, pair.Before ?? string.Empty, UnifiedLineKind.Removed));
                    lines.Add(new UnifiedDiffLine(null, after++, pair.After ?? string.Empty, UnifiedLineKind.Added));
                    break;
            }
        }

        return lines;
    }

    /// <summary>Which lines of each side the shortest edit script removes and inserts.</summary>
    private static (bool[] Removed, bool[] Inserted) EditScript(IReadOnlyList<string> before, IReadOnlyList<string> after)
    {
        var removed = new bool[before.Count];
        var inserted = new bool[after.Count];

        // Lines compared as integers: one dictionary lookup per line instead of a string compare per step.
        var ids = new Dictionary<string, int>(StringComparer.Ordinal);
        var x = before.Select(l => Id(ids, l)).ToArray();
        var y = after.Select(l => Id(ids, l)).ToArray();

        var start = 0;
        while (start < x.Length && start < y.Length && x[start] == y[start])
        {
            start++;
        }

        int endX = x.Length, endY = y.Length;
        while (endX > start && endY > start && x[endX - 1] == y[endY - 1])
        {
            endX--;
            endY--;
        }

        var n = endX - start;
        var m = endY - start;
        if (n == 0 || m == 0 || !Myers(x, y, start, n, m, removed, inserted))
        {
            Array.Fill(removed, true, start, n);
            Array.Fill(inserted, true, start, m);
        }

        return (removed, inserted);
    }

    private static int Id(Dictionary<string, int> ids, string line)
    {
        if (!ids.TryGetValue(line, out var id))
        {
            id = ids.Count;
            ids[line] = id;
        }

        return id;
    }

    private static bool Myers(int[] x, int[] y, int offset, int n, int m, bool[] removed, bool[] inserted)
    {
        var max = Math.Min(n + m, MaxEditDistance);
        var v = new int[(2 * max) + 2];
        var trace = new List<int[]>();
        for (var d = 0; d <= max; d++)
        {
            trace.Add((int[])v.Clone());
            for (var k = -d; k <= d; k += 2)
            {
                int px;
                if (k == -d || (k != d && v[max + k - 1] < v[max + k + 1]))
                {
                    px = v[max + k + 1];
                }
                else
                {
                    px = v[max + k - 1] + 1;
                }

                var py = px - k;
                while (px < n && py < m && x[offset + px] == y[offset + py])
                {
                    px++;
                    py++;
                }

                v[max + k] = px;
                if (px >= n && py >= m)
                {
                    Backtrack(trace, max, n, m, d, offset, removed, inserted);
                    return true;
                }
            }
        }

        return false;
    }

    private static void Backtrack(List<int[]> trace, int max, int n, int m, int depth, int offset, bool[] removed, bool[] inserted)
    {
        int px = n, py = m;
        for (var d = depth; d > 0; d--)
        {
            var v = trace[d];
            var k = px - py;
            var previousK = k == -d || (k != d && v[max + k - 1] < v[max + k + 1]) ? k + 1 : k - 1;
            var previousX = v[max + previousK];
            var previousY = previousX - previousK;
            while (px > previousX && py > previousY)
            {
                px--;
                py--;
            }

            if (px == previousX)
            {
                inserted[offset + previousY] = true;
            }
            else
            {
                removed[offset + previousX] = true;
            }

            px = previousX;
            py = previousY;
        }
    }
}

/// <summary>How two versions compare.</summary>
public abstract record VersionComparison
{
    public const int MaximumLineCount = 5000;

    public static VersionComparison Compare(string baseline, string current)
    {
        if (string.Equals(baseline, current, StringComparison.Ordinal))
        {
            return new IdenticalVersions();
        }

        var before = LineDiff.Lines(baseline);
        var after = LineDiff.Lines(current);
        if (before.AsSpan().SequenceEqual(after))
        {
            return new IdenticalVersions();
        }

        return before.Length > MaximumLineCount || after.Length > MaximumLineCount
            ? new TooLargeToCompare()
            : new DifferingVersions(LineDiff.Split(before, after));
    }
}

public sealed record IdenticalVersions : VersionComparison;

public sealed record DifferingVersions(IReadOnlyList<DiffPair> Pairs) : VersionComparison;

public sealed record TooLargeToCompare : VersionComparison;
