using System.Globalization;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Core.Import;

/// <summary>
/// Writes the records of a file into a table, a batch per transaction, or all in one when the table is emptied first.
/// </summary>
public static class RowImporter
{
    /// <summary>
    /// Rows per save. Each batch is one transaction, so a failure leaves the batches before it in the table, unless
    /// <see cref="ImportRowWriting.DeleteExistingRows"/> holds every batch in one.
    /// </summary>
    public const int BatchSize = 500;

    public static Task<RowImportResult> ImportAsync(
        IDatabaseSession session,
        ObjectName table,
        IAsyncEnumerable<IReadOnlyDictionary<string, object?>> records,
        ImportRowBuilder builder,
        IProgress<long>? progress,
        CancellationToken cancellationToken) =>
        ImportAsync(session, table, records, builder, ImportRowWriting.Insert, progress, cancellationToken);

    /// <summary>
    /// Inserts every row, or, for the modes that match existing rows, counts each batch's keys in the table first and
    /// then updates, inserts or leaves each row as the mode says. The engines' own upsert statements are not used, as on
    /// macOS: they refuse a NOT NULL column the file leaves out even when the row exists. Rows go out in file order, so
    /// a new parent row lands before an update that points at it.
    /// </summary>
    /// <remarks>
    /// With <see cref="ImportRowWriting.DeleteExistingRows"/> the table is emptied and refilled in one transaction
    /// (<see cref="ChangeTransactions"/>), so a failure leaves the old rows in place. A session that cannot hold one is
    /// refused rather than left with an empty table and half a file.
    /// </remarks>
    public static async Task<RowImportResult> ImportAsync(
        IDatabaseSession session,
        ObjectName table,
        IAsyncEnumerable<IReadOnlyDictionary<string, object?>> records,
        ImportRowBuilder builder,
        ImportRowWriting writing,
        IProgress<long>? progress,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(session);
        ArgumentNullException.ThrowIfNull(records);
        ArgumentNullException.ThrowIfNull(builder);
        ArgumentNullException.ThrowIfNull(writing);
        if (builder.Mapping.Count == 0)
        {
            throw new InvalidOperationException("No field in the file is mapped to a column of this table.");
        }

        if (writing.DeleteExistingRows)
        {
            return await ReplaceRowsAsync(session, table, records, builder, writing, progress, cancellationToken);
        }

        IImportRowMatcher? matcher = null;
        if (writing.Mode.MatchesExistingRows())
        {
            matcher = session as IImportRowMatcher ?? throw new NotSupportedException("This connection cannot match imported rows against existing ones.");
            if (writing.KeyColumns.Count == 0)
            {
                throw new InvalidOperationException("Choose the key the rows are matched on.");
            }
        }

        return await WriteAsync(new BatchWriter(session.SaveChangesAsync, session.Dialect, matcher, table, writing, progress), records, builder, cancellationToken);
    }

    /// <summary>Whether <paramref name="session"/> can empty a table and import into it in one transaction.</summary>
    public static bool CanDeleteExistingRows(IDatabaseSession session) => ChangeTransactions.For(session) is not null;

    private static async Task<RowImportResult> ReplaceRowsAsync(
        IDatabaseSession session,
        ObjectName table,
        IAsyncEnumerable<IReadOnlyDictionary<string, object?>> records,
        ImportRowBuilder builder,
        ImportRowWriting writing,
        IProgress<long>? progress,
        CancellationToken cancellationToken)
    {
        if (writing.Mode.MatchesExistingRows())
        {
            throw new InvalidOperationException("Delete existing rows first empties the table, so no row would match. Turn it off, or import as Insert.");
        }

        var transactions = ChangeTransactions.For(session)
            ?? throw new NotSupportedException("This connection cannot empty a table and import into it in one transaction, so it cannot delete the existing rows first.");
        await using var transaction = await transactions.BeginChangesAsync(cancellationToken);
        await transaction.DeleteAllRowsAsync(table, cancellationToken);
        var result = await WriteAsync(new BatchWriter(transaction.SaveChangesAsync, session.Dialect, null, table, writing, progress), records, builder, cancellationToken);
        await transaction.CommitAsync(cancellationToken);
        return result;
    }

    private static async Task<RowImportResult> WriteAsync(
        BatchWriter writer,
        IAsyncEnumerable<IReadOnlyDictionary<string, object?>> records,
        ImportRowBuilder builder,
        CancellationToken cancellationToken)
    {
        long skipped = 0;
        await foreach (var record in records.WithCancellation(cancellationToken))
        {
            var values = builder.Build(record);
            if (values.Count == 0)
            {
                skipped++;
                continue;
            }

            await writer.AddAsync(values, cancellationToken);
        }

        await writer.FlushAsync(cancellationToken);
        return writer.Result with { Skipped = skipped };
    }

    /// <summary>
    /// Folds a key more than a collation or a numeric comparison does, so two keys the database might take as one never
    /// share a batch. A NULL matches no row, so a key holding one is not tracked at all.
    /// </summary>
    internal static string? FoldedKey(IReadOnlyList<object?> key)
    {
        var parts = new string[key.Count];
        for (var i = 0; i < key.Count; i++)
        {
            switch (key[i])
            {
                case null or DBNull:
                    return null;
                case byte[] bytes:
                    parts[i] = "b:" + Convert.ToBase64String(bytes);
                    break;
                case string text:
                    parts[i] = FoldText(text);
                    break;
                case bool flag:
                    parts[i] = flag ? "n:1" : "n:0";
                    break;
                case IConvertible number when number.GetTypeCode() is >= TypeCode.SByte and <= TypeCode.Decimal:
                    parts[i] = FoldNumber(number.ToDouble(CultureInfo.InvariantCulture));
                    break;
                case IFormattable formattable:
                    parts[i] = "t:" + formattable.ToString(null, CultureInfo.InvariantCulture);
                    break;
                default:
                    parts[i] = "t:" + key[i];
                    break;
            }
        }

        return string.Join('\x1F', parts);
    }

    // A text key that reads as a number folds as that number: a REAL column holds "0.1" and 0.1 as one value.
    private static string FoldText(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Any(char.IsAsciiDigit) && double.TryParse(trimmed, NumberStyles.Float, CultureInfo.InvariantCulture, out var number))
        {
            return FoldNumber(number);
        }

        var sortKey = CultureInfo.InvariantCulture.CompareInfo.GetSortKey(
            trimmed,
            CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace | CompareOptions.IgnoreWidth | CompareOptions.IgnoreKanaType);
        return "t:" + Convert.ToBase64String(sortKey.KeyData);
    }

    private static string FoldNumber(double value) => "n:" + (value == 0 ? 0d : value).ToString("R", CultureInfo.InvariantCulture);

    private sealed class BatchWriter(
        Func<ObjectName, IReadOnlyList<RowChange>, CancellationToken, Task<int>> save,
        SqlDialect dialect,
        IImportRowMatcher? matcher,
        ObjectName table,
        ImportRowWriting writing,
        IProgress<long>? progress)
    {
        private readonly List<IReadOnlyDictionary<string, object?>> _batch = new(BatchSize);
        private readonly HashSet<string> _keysInBatch = new(StringComparer.Ordinal);
        private readonly HashSet<string> _kept = new([.. writing.KeyColumns, .. writing.KeptColumns], StringComparer.OrdinalIgnoreCase);

        public RowImportResult Result { get; private set; } = new(writing.Mode, 0, 0, 0, 0, 0);

        public async Task AddAsync(IReadOnlyDictionary<string, object?> values, CancellationToken cancellationToken)
        {
            if (matcher is not null)
            {
                // A repeated key has to see the write of its first occurrence, so the batch ends before it.
                if (FoldedKey(KeyOf(values)) is { } folded && !_keysInBatch.Add(folded))
                {
                    await FlushAsync(cancellationToken);
                    _keysInBatch.Add(folded);
                }
            }

            _batch.Add(values);
            if (_batch.Count == BatchSize)
            {
                await FlushAsync(cancellationToken);
            }
        }

        public async Task FlushAsync(CancellationToken cancellationToken)
        {
            if (_batch.Count == 0)
            {
                return;
            }

            if (matcher is null)
            {
                var inserted = await save(table, [.. _batch.Select(v => new RowInsert(v))], cancellationToken);
                Result = Result with { Inserted = Result.Inserted + inserted };
            }
            else
            {
                await WriteMatchingAsync(matcher, cancellationToken);
            }

            _batch.Clear();
            _keysInBatch.Clear();
            progress?.Report(Result.Imported);
        }

        private async Task WriteMatchingAsync(IImportRowMatcher rowMatcher, CancellationToken cancellationToken)
        {
            var keys = _batch.Select(KeyOf).ToArray();
            var counts = new List<long>(keys.Length);
            var perStatement = ImportKeyMatchSql.KeysPerStatement(dialect, writing.KeyColumns.Count);
            for (var start = 0; start < keys.Length; start += perStatement)
            {
                var chunk = keys[start..Math.Min(start + perStatement, keys.Length)];
                counts.AddRange(await rowMatcher.CountKeyMatchesAsync(table, writing.KeyColumns, chunk, cancellationToken));
            }

            for (var i = 0; i < keys.Length; i++)
            {
                if (counts[i] > 1)
                {
                    throw new InvalidOperationException(string.Create(
                        CultureInfo.InvariantCulture,
                        $"The key {Describe(keys[i])} matched {counts[i]} rows, so the row was not written."));
                }
            }

            long inserted = 0, updated = 0, unmatched = 0, existing = 0;
            var changes = new List<RowChange>(_batch.Count);
            for (var i = 0; i < _batch.Count; i++)
            {
                var values = _batch[i];
                if (counts[i] == 0)
                {
                    if (writing.Mode == ImportWriteMode.Update)
                    {
                        unmatched++;
                    }
                    else
                    {
                        changes.Add(new RowInsert(values));
                        inserted++;
                    }

                    continue;
                }

                // A column the engine never lets an UPDATE assign keeps its value, and is written only into an inserted row.
                var assignments = writing.Mode.UpdatesMatchedRows()
                    ? values.Where(p => !_kept.Contains(p.Key)).ToDictionary(StringComparer.Ordinal)
                    : null;
                if (assignments is not { Count: > 0 })
                {
                    existing++;
                    continue;
                }

                var key = new Dictionary<string, object?>(StringComparer.Ordinal);
                for (var k = 0; k < writing.KeyColumns.Count; k++)
                {
                    key[writing.KeyColumns[k]] = keys[i][k];
                }

                changes.Add(new RowUpdate(key, assignments));
                updated++;
            }

            if (changes.Count > 0)
            {
                await save(table, changes, cancellationToken);
            }

            Result = Result with
            {
                Inserted = Result.Inserted + inserted,
                Updated = Result.Updated + updated,
                Unmatched = Result.Unmatched + unmatched,
                Existing = Result.Existing + existing,
            };
        }

        private IReadOnlyList<object?> KeyOf(IReadOnlyDictionary<string, object?> values)
        {
            var key = new object?[writing.KeyColumns.Count];
            for (var i = 0; i < key.Length; i++)
            {
                var column = writing.KeyColumns[i];
                if (values.TryGetValue(column, out var value))
                {
                    key[i] = value;
                    continue;
                }

                var match = values.FirstOrDefault(p => string.Equals(p.Key, column, StringComparison.OrdinalIgnoreCase));
                key[i] = match.Key is not null
                    ? match.Value
                    : throw new InvalidOperationException($"This row has no value for the key column {column}, so it cannot be matched.");
            }

            return key;
        }

        private string Describe(IReadOnlyList<object?> key) =>
            string.Join(", ", writing.KeyColumns.Select((column, i) => $"{column} = {(key[i] is null ? "NULL" : Convert.ToString(key[i], CultureInfo.InvariantCulture))}"));
    }
}
