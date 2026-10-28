using System.Diagnostics;

namespace TablePro.Core.Compare;

/// <summary>
/// A key-ordered merge join over two row streams. Both sides are read in key order and walked in lockstep, so neither
/// is held in memory and no server-side hash has to agree between two engines.
/// </summary>
/// <remarks>
/// The walk is only right when the client order agrees with the order the server sent rows in, so every row is
/// checked against the one before it: a server whose collation disagrees is reported rather than turned into a
/// delete plus an insert for a row both sides hold. Ported from the macOS app's <c>DataDiffEngine</c>.
/// </remarks>
public sealed class DataDiffEngine
{
    private const int ProgressInterval = 2_000;

    private readonly DataCompareSpec _spec;
    private readonly DataCompareOptions _options;

    public DataDiffEngine(DataCompareSpec spec, DataCompareOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(spec);
        _spec = spec;
        _options = options ?? DataCompareOptions.Default;
    }

    /// <param name="source">Source rows in key order, laid out as <see cref="DataCompareSpec.Columns"/>.</param>
    /// <param name="target">Target rows, the same way.</param>
    /// <param name="progress">Told the running counts every few thousand rows.</param>
    /// <param name="cancellationToken">Stops the walk between rows.</param>
    public async Task<DataDiffResult> CompareAsync(
        IAsyncEnumerable<object?[]> source,
        IAsyncEnumerable<object?[]> target,
        IProgress<DataCompareProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(target);

        var stopwatch = Stopwatch.StartNew();
        var accumulator = new Accumulator(_options.MaxRetainedDifferences);
        await using var left = new Reader(this, source, "source", accumulator, cancellationToken);
        await using var right = new Reader(this, target, "target", accumulator, cancellationToken);

        var sourceRow = await left.NextAsync();
        var targetRow = await right.NextAsync();
        var stoppedAtLimit = false;
        long positions = 0;

        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (sourceRow is null && targetRow is null)
            {
                stoppedAtLimit = left.EndedAtRowLimit || right.EndedAtRowLimit;
                break;
            }

            // One side ending at its limit says nothing about the rest of the other side, so the walk stops there
            // instead of calling every remaining row one-sided.
            if (sourceRow is null && left.EndedAtRowLimit || targetRow is null && right.EndedAtRowLimit)
            {
                stoppedAtLimit = true;
                break;
            }

            var order = sourceRow is null ? 1 : targetRow is null ? -1 : CompareKeys(sourceRow, targetRow);
            if (order == 0)
            {
                accumulator.Add(Matched(sourceRow!, targetRow!));
                sourceRow = await left.NextAsync();
                targetRow = await right.NextAsync();
            }
            else if (order < 0)
            {
                accumulator.Add(new RowDiff(RowDiffKind.OnlyInSource, sourceRow, null, []));
                sourceRow = await left.NextAsync();
            }
            else
            {
                accumulator.Add(new RowDiff(RowDiffKind.OnlyInTarget, null, targetRow, []));
                targetRow = await right.NextAsync();
            }

            if (++positions % ProgressInterval == 0)
            {
                progress?.Report(new DataCompareProgress(left.Count, right.Count, accumulator.DifferenceCount));
            }
        }

        progress?.Report(new DataCompareProgress(left.Count, right.Count, accumulator.DifferenceCount));
        return new DataDiffResult
        {
            Spec = _spec,
            OnlyInSourceCount = accumulator.OnlyInSource,
            OnlyInTargetCount = accumulator.OnlyInTarget,
            ChangedCount = accumulator.Changed,
            IdenticalCount = accumulator.Identical,
            SourceRows = left.Count,
            TargetRows = right.Count,
            SkippedNullKeyCount = accumulator.SkippedNullKeys,
            StoppedAtRowLimit = stoppedAtLimit,
            IsTruncated = accumulator.IsTruncated,
            Elapsed = stopwatch.Elapsed,
            Differences = accumulator.Differences,
        };
    }

    internal int CompareKeys(object?[] left, object?[] right)
    {
        foreach (var index in _spec.KeyIndexes)
        {
            var order = CompareValues.CompareKeys(left[index], right[index], _options.KeysIgnoreCase);
            if (order != 0)
            {
                return order;
            }
        }

        return 0;
    }

    private RowDiff Matched(object?[] source, object?[] target)
    {
        List<int>? changed = null;
        for (var i = 0; i < _spec.Columns.Count; i++)
        {
            // Key columns matched under the key order; under a case-insensitive key 'A' and 'a' still differ as values.
            var equal = _spec.IsKeyColumn(i)
                ? Equals(source[i], target[i]) || CompareValues.CompareKeys(source[i], target[i], ignoreCase: false) == 0
                : CompareValues.AreEqual(source[i], target[i], _options);
            if (!equal)
            {
                (changed ??= []).Add(i);
            }
        }

        return changed is null
            ? new RowDiff(RowDiffKind.Identical, source, target, [])
            : new RowDiff(RowDiffKind.Changed, source, target, [.. changed]);
    }

    private static bool HasNullKey(object?[] row, ReadOnlySpan<int> keys)
    {
        foreach (var index in keys)
        {
            if (row[index] is null or DBNull)
            {
                return true;
            }
        }

        return false;
    }

    private sealed class Accumulator(int limit)
    {
        private readonly List<RowDiff> _differences = [];

        public long OnlyInSource { get; private set; }

        public long OnlyInTarget { get; private set; }

        public long Changed { get; private set; }

        public long Identical { get; private set; }

        public long SkippedNullKeys { get; set; }

        public bool IsTruncated { get; private set; }

        public long DifferenceCount => OnlyInSource + OnlyInTarget + Changed;

        public IReadOnlyList<RowDiff> Differences => _differences;

        public void Add(RowDiff diff)
        {
            switch (diff.Kind)
            {
                case RowDiffKind.Identical:
                    Identical++;
                    return;
                case RowDiffKind.OnlyInSource:
                    OnlyInSource++;
                    break;
                case RowDiffKind.OnlyInTarget:
                    OnlyInTarget++;
                    break;
                default:
                    Changed++;
                    break;
            }

            if (_differences.Count < limit)
            {
                _differences.Add(diff);
            }
            else
            {
                IsTruncated = true;
            }
        }
    }

    /// <summary>One side's stream, checked for order and duplicates as it is read, and cut at the row limit.</summary>
    private sealed class Reader(DataDiffEngine engine, IAsyncEnumerable<object?[]> rows, string side, Accumulator accumulator, CancellationToken cancellationToken)
        : IAsyncDisposable
    {
        private readonly IAsyncEnumerator<object?[]> _rows = rows.GetAsyncEnumerator(cancellationToken);
        private object?[]? _previous;
        private bool _probedPastLimit;

        public long Count { get; private set; }

        /// <summary>The limit stopped this side while the stream still had a row, which is read and never used.</summary>
        public bool EndedAtRowLimit { get; private set; }

        public async ValueTask<object?[]?> NextAsync()
        {
            var limit = engine._options.RowLimit;
            while (true)
            {
                if (limit is { } max && Count >= max)
                {
                    // One row past the limit tells a table that ends exactly there from one the limit cut short.
                    if (!_probedPastLimit)
                    {
                        _probedPastLimit = true;
                        EndedAtRowLimit = await _rows.MoveNextAsync();
                    }

                    return null;
                }

                if (!await _rows.MoveNextAsync())
                {
                    return null;
                }

                var row = _rows.Current;
                if (row.Length < engine._spec.Columns.Count)
                {
                    throw new CompareException($"The {side} returned {row.Length} columns where {engine._spec.Columns.Count} were expected.");
                }

                Count++;
                if (HasNullKey(row, engine._spec.KeyIndexes))
                {
                    accumulator.SkippedNullKeys++;
                    continue;
                }

                CheckOrder(row);
                _previous = row;
                return row;
            }
        }

        public ValueTask DisposeAsync() => _rows.DisposeAsync();

        private void CheckOrder(object?[] row)
        {
            if (_previous is null)
            {
                return;
            }

            var order = engine.CompareKeys(_previous, row);
            if (order < 0)
            {
                return;
            }

            var key = engine._spec.DescribeKey(row);
            throw order == 0
                ? new CompareException($"Key {key} matches more than one row in the {side}. Choose key columns that identify a single row.")
                : new CompareException($"The {side} sorted rows differently than the comparison expects, near key {key}. Pick a numeric key, or one whose collation sorts by byte value{(engine._options.KeysIgnoreCase ? string.Empty : ", or turn on case-insensitive keys")}.");
        }
    }
}
