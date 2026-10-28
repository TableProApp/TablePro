using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Schema;

namespace TablePro.Core.Import;

/// <summary>How many rows an import inserted, and how many records it passed over because they held no mapped field.</summary>
public readonly record struct RowImportResult(long Imported, long Skipped);

/// <summary>Inserts the records of a file into a table, a batch per transaction.</summary>
public static class RowImporter
{
    /// <summary>Rows per save. Each batch is one transaction, so a failure leaves the batches before it in the table.</summary>
    public const int BatchSize = 500;

    public static async Task<RowImportResult> ImportAsync(
        IDatabaseSession session,
        ObjectName table,
        IAsyncEnumerable<IReadOnlyDictionary<string, object?>> records,
        ImportRowBuilder builder,
        IProgress<long>? progress,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(session);
        ArgumentNullException.ThrowIfNull(records);
        ArgumentNullException.ThrowIfNull(builder);
        if (builder.Mapping.Count == 0)
        {
            throw new InvalidOperationException("No field in the file is mapped to a column of this table.");
        }

        long imported = 0, skipped = 0;
        var batch = new List<RowChange>(BatchSize);
        await foreach (var record in records.WithCancellation(cancellationToken))
        {
            var values = builder.Build(record);
            if (values.Count == 0)
            {
                skipped++;
                continue;
            }

            batch.Add(new RowInsert(values));
            if (batch.Count == BatchSize)
            {
                imported += await session.SaveChangesAsync(table, batch, cancellationToken);
                batch.Clear();
                progress?.Report(imported);
            }
        }

        if (batch.Count > 0)
        {
            imported += await session.SaveChangesAsync(table, batch, cancellationToken);
            progress?.Report(imported);
        }

        return new RowImportResult(imported, skipped);
    }
}
