using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Schema;

namespace TablePro.Core.Generation;

/// <summary>A table read for generation: its model, the provider type of each column, and how its unique keys treat NULL.</summary>
public sealed record RowGenerationTarget(ObjectName Table, RowGenerationTable Model, IReadOnlyDictionary<string, Type> ClrTypes, bool NullsAreDistinct);

/// <summary>Reads what the generator needs from a live session: structure, a sample of every parent key, and key maximums.</summary>
public static class RowGenerationLoader
{
    /// <summary>Enough keys to draw from without reading a large referenced table whole.</summary>
    public const int ReferenceSampleLimit = 10_000;

    public static async Task<RowGenerationTarget> LoadAsync(IDatabaseSession session, ObjectName table, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(session);
        var structure = await session.GetStructureAsync(table, cancellationToken);
        var engine = session.Profile.Engine;
        var (columns, groups, requests) = RowGenerationColumnReader.Read(structure, engine);

        var references = new List<ReferenceSource>(requests.Count);
        foreach (var request in requests)
        {
            references.Add(await SampleAsync(session, table, request, cancellationToken));
        }

        var model = new RowGenerationTable(columns)
        {
            UniqueGroups = groups,
            References = references,
            KeyMaximums = await KeyMaximumsAsync(session, table, columns, cancellationToken),
        };

        // One row is enough for the provider to say how it reads each column; an empty table still reports its types.
        var page = await session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [], 0, 1), cancellationToken);
        var types = new Dictionary<string, Type>(StringComparer.OrdinalIgnoreCase);
        foreach (var column in page.Columns)
        {
            types.TryAdd(column.Name, column.ClrType);
        }

        // SQL Server's unique index counts two NULLs as the same key.
        return new RowGenerationTarget(table, model, types, engine != DatabaseEngine.SqlServer);
    }

    // Ordered, so the same referenced rows give the same picks for a seed.
    private static async Task<ReferenceSource> SampleAsync(IDatabaseSession session, ObjectName table, ReferenceRequest request, CancellationToken cancellationToken)
    {
        var parent = string.IsNullOrEmpty(request.ReferencedTable.Schema) ? request.ReferencedTable with { Schema = table.Schema } : request.ReferencedTable;
        var filter = new BrowseFilter([.. request.ReferencedColumns.Select(c => new FilterRule(c, FilterOperator.IsNotNull))]);
        var sort = request.ReferencedColumns.Select(c => new SortColumn(c, false)).ToArray();
        var result = await session.BrowseAsync(new BrowseRequest(parent, filter, sort, 0, ReferenceSampleLimit), cancellationToken);
        var ordinals = request.ReferencedColumns.Select(result.ColumnIndex).ToArray();
        var seen = new HashSet<RowFingerprint>();
        var tuples = new List<object?[]>(result.RowCount);
        if (ordinals.All(o => o >= 0))
        {
            foreach (var row in result.Rows)
            {
                var tuple = new object?[ordinals.Length];
                for (var i = 0; i < ordinals.Length; i++)
                {
                    tuple[i] = row[ordinals[i]];
                }

                if (seen.Add(RowFingerprint.Of(tuple)))
                {
                    tuples.Add(tuple);
                }
            }
        }

        return new ReferenceSource(request.Id, parent.ToString(), request.Columns, tuples);
    }

    // A sequence on a key column starts past the largest value already there.
    private static async Task<Dictionary<string, long>> KeyMaximumsAsync(
        IDatabaseSession session, ObjectName table, IReadOnlyList<RowGenerationColumn> columns, CancellationToken cancellationToken)
    {
        var maximums = new Dictionary<string, long>(StringComparer.Ordinal);
        foreach (var column in columns.Where(c => c.IsUnique && c.Ownership == ServerOwnership.None && c.ValueClass == RowValueClass.Integer))
        {
            var filter = new BrowseFilter([new FilterRule(column.Name, FilterOperator.IsNotNull)]);
            var result = await session.BrowseAsync(new BrowseRequest(table, filter, [new SortColumn(column.Name, true)], 0, 1), cancellationToken);
            var ordinal = result.ColumnIndex(column.Name);
            if (result.RowCount > 0 && ordinal >= 0 && ValueParser.TryParse(RowValueText.Invariant(result[0, ordinal]), typeof(long), out var value) && value is long max)
            {
                maximums[column.Name] = max;
            }
        }

        return maximums;
    }
}

/// <summary>How far an insert got before it failed; every batch before the failing one is committed and stays.</summary>
public sealed class RowGenerationWriteException(int keptRows, Exception inner)
    : InvalidOperationException(inner?.Message, inner)
{
    public int KeptRows { get; } = keptRows;
}

/// <summary>Inserts generated rows through the session's save path, a transaction per batch.</summary>
public static class RowGenerationWriter
{
    public const int BatchSize = 500;

    /// <summary>
    /// Generates and inserts <paramref name="rowCount"/> rows, reporting the running total after each batch. A failure
    /// throws <see cref="RowGenerationWriteException"/> with the rows already kept; cancelling stops between batches
    /// and throws <see cref="OperationCanceledException"/>.
    /// </summary>
    public static async Task<int> InsertAsync(
        IDatabaseSession session,
        RowGenerationTarget target,
        RowGenerationEngine engine,
        int rowCount,
        IProgress<int>? progress,
        CancellationToken cancellationToken,
        int batchSize = BatchSize)
    {
        ArgumentNullException.ThrowIfNull(session);
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(engine);
        var names = engine.ColumnNames;
        var types = names.Select(n => target.ClrTypes.TryGetValue(n, out var type) ? type : null).ToArray();
        var written = 0;
        while (written < rowCount)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var count = Math.Min(Math.Max(1, batchSize), rowCount - written);

            List<RowChange> batch;
            try
            {
                // Generating a batch is CPU work; it leaves the caller's thread, which is the UI thread for the dialog.
                batch = await Task.Run(() => Build(engine, names, types, count), cancellationToken);
                await session.SaveChangesAsync(target.Table, batch, cancellationToken);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
                throw new RowGenerationWriteException(written, ex);
            }

            written += batch.Count;
            progress?.Report(written);
        }

        return written;
    }

    private static List<RowChange> Build(RowGenerationEngine engine, IReadOnlyList<string> names, Type?[] types, int count)
    {
        var rows = engine.NextRows(count);
        var changes = new List<RowChange>(rows.Count);
        foreach (var row in rows)
        {
            var values = new Dictionary<string, object?>(names.Count, StringComparer.Ordinal);
            for (var i = 0; i < names.Count; i++)
            {
                values[names[i]] = RowValueBinder.ToProviderType(row[i], types[i]);
            }

            changes.Add(new RowInsert(values));
        }

        return changes;
    }
}
