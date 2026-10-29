using System.Globalization;
using System.Text;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Core.Import;

/// <summary>What an import does with a row whose key is already in the table, as the macOS import sheet offers it.</summary>
public enum ImportWriteMode
{
    /// <summary>Every row is inserted; a row whose key exists fails as the database decides.</summary>
    Insert,

    /// <summary>Rows whose key is in the table are updated; the rest are left out.</summary>
    Update,

    /// <summary>Rows whose key is in the table are updated; the rest are inserted.</summary>
    Upsert,

    /// <summary>Only rows whose key is not in the table are inserted.</summary>
    InsertSkippingExisting,
}

public static class ImportWriteModeExtensions
{
    public static bool MatchesExistingRows(this ImportWriteMode mode) => mode != ImportWriteMode.Insert;

    public static bool UpdatesMatchedRows(this ImportWriteMode mode) => mode is ImportWriteMode.Update or ImportWriteMode.Upsert;
}

/// <summary>The columns an import matches rows on: the primary key, or a unique index named by <see cref="IndexName"/>.</summary>
public sealed record ImportMatchKey(string? IndexName, IReadOnlyList<string> Columns)
{
    public bool IsPrimaryKey => IndexName is null;

    public bool Equals(ImportMatchKey? other) =>
        other is not null && IndexName == other.IndexName && Columns.SequenceEqual(other.Columns, StringComparer.Ordinal);

    public override int GetHashCode() => HashCode.Combine(IndexName, Columns.Count);

    /// <summary>
    /// The primary key first, then each unique index over other columns. An index naming a column the table does not
    /// list, which is how an expression index reads, cannot pick out one row by the file's values, so it is left out.
    /// </summary>
    public static IReadOnlyList<ImportMatchKey> Options(IReadOnlyList<ColumnInfo> columns, IReadOnlyList<IndexInfo> indexes)
    {
        ArgumentNullException.ThrowIfNull(columns);
        ArgumentNullException.ThrowIfNull(indexes);
        var exact = columns.Select(c => c.Name).ToHashSet(StringComparer.Ordinal);

        // A spelling two columns share once case is folded names neither: PostgreSQL keeps "ID" and "id" apart.
        var folded = columns.GroupBy(c => c.Name, StringComparer.OrdinalIgnoreCase)
            .Where(g => g.Count() == 1)
            .ToDictionary(g => g.Key, g => g.First().Name, StringComparer.OrdinalIgnoreCase);

        string[]? TableColumns(IReadOnlyList<string> names)
        {
            var resolved = new string[names.Count];
            for (var i = 0; i < resolved.Length; i++)
            {
                if (exact.Contains(names[i]))
                {
                    resolved[i] = names[i];
                }
                else if (folded.GetValueOrDefault(names[i]) is { } column)
                {
                    resolved[i] = column;
                }
                else
                {
                    return null;
                }
            }

            return resolved.Length > 0 ? resolved : null;
        }

        var keys = new List<ImportMatchKey>();
        var flagged = columns.Where(c => c.IsPrimaryKey).Select(c => c.Name).ToArray();
        var primary = indexes.FirstOrDefault(i => i.IsPrimary) is { } index ? TableColumns(index.Columns) : null;
        primary ??= flagged.Length > 0 ? flagged : null;
        if (primary is not null)
        {
            keys.Add(new ImportMatchKey(null, primary));
        }

        foreach (var unique in indexes.Where(i => i.IsUnique && !i.IsPrimary))
        {
            if (TableColumns(unique.Columns) is { } keyColumns && !keys.Any(k => k.Columns.ToHashSet(StringComparer.Ordinal).SetEquals(keyColumns)))
            {
                keys.Add(new ImportMatchKey(unique.Name, keyColumns));
            }
        }

        return keys;
    }
}

/// <summary>How rows are written: the mode, the key it matches on, and the columns an update must leave alone.</summary>
/// <param name="Mode">Insert, or one of the modes that match existing rows.</param>
/// <param name="KeyColumns">The match key's columns; empty for <see cref="ImportWriteMode.Insert"/>.</param>
/// <param name="KeptColumns">Columns an UPDATE never assigns, such as an identity, written only into inserted rows.</param>
public sealed record ImportRowWriting(ImportWriteMode Mode, IReadOnlyList<string> KeyColumns, IReadOnlyCollection<string> KeptColumns)
{
    public static ImportRowWriting Insert { get; } = new(ImportWriteMode.Insert, [], []);
}

/// <summary>Why a mode that matches rows cannot run with the chosen key and mapping.</summary>
public enum ImportRowWritingProblemKind
{
    NoKey,
    UnmappedKeyColumns,
    NothingToUpdate,
}

public sealed record ImportRowWritingProblem(ImportRowWritingProblemKind Kind, IReadOnlyList<string> Columns)
{
    /// <summary>Null when the mode can run: Insert always can; the others need a key whose every column is mapped.</summary>
    public static ImportRowWritingProblem? Of(ImportWriteMode mode, ImportMatchKey? key, IReadOnlyCollection<string> mappedColumns)
    {
        ArgumentNullException.ThrowIfNull(mappedColumns);
        if (!mode.MatchesExistingRows())
        {
            return null;
        }

        if (key is null)
        {
            return new(ImportRowWritingProblemKind.NoKey, []);
        }

        var mapped = mappedColumns.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var missing = key.Columns.Where(c => !mapped.Contains(c)).ToArray();
        if (missing.Length > 0)
        {
            return new(ImportRowWritingProblemKind.UnmappedKeyColumns, missing);
        }

        mapped.ExceptWith(key.Columns);
        return mode.UpdatesMatchedRows() && mapped.Count == 0 ? new(ImportRowWritingProblemKind.NothingToUpdate, []) : null;
    }
}

/// <summary>What an import did, counted per row as it lands, so a row the database refused is in none of them.</summary>
/// <param name="Mode">The mode the counts belong to.</param>
/// <param name="Inserted">Rows inserted.</param>
/// <param name="Updated">Rows whose key matched and whose mapped columns were written.</param>
/// <param name="Unmatched">Rows Update left out because their key matched no row.</param>
/// <param name="Existing">Rows whose key matched and that were left as they were: Insert, Skip Existing, or nothing to assign.</param>
/// <param name="Skipped">Records that held no mapped field.</param>
public readonly record struct RowImportResult(ImportWriteMode Mode, long Inserted, long Updated, long Unmatched, long Existing, long Skipped)
{
    /// <summary>Rows written to the table, inserted or updated.</summary>
    public long Imported => Inserted + Updated;

    public long Matched => Updated + Existing;
}

/// <summary>
/// A session that can count the rows matching many keys in one round trip, which the modes that match existing rows
/// need before they decide between an insert and an update.
/// </summary>
public interface IImportRowMatcher
{
    /// <summary>For each key, how many rows of <paramref name="table"/> hold those values in <paramref name="keyColumns"/>.</summary>
    Task<IReadOnlyList<long>> CountKeyMatchesAsync(ObjectName table, IReadOnlyList<string> keyColumns, IReadOnlyList<IReadOnlyList<object?>> keys, CancellationToken cancellationToken);
}

/// <summary>The probe that counts matches for a run of keys, with every value bound.</summary>
public static class ImportKeyMatchSql
{
    /// <summary>Keys per probe, as on macOS: enough to save round trips, few enough that the statement stays small.</summary>
    public const int KeysPerProbe = 100;

    /// <summary>
    /// One <c>SELECT position, COUNT(*) ... WHERE key = value</c> per key, joined with <c>UNION ALL</c>, so the answer
    /// says which key each count belongs to whatever order the server returns them in. A NULL key value matches no row,
    /// as <c>= NULL</c> never does.
    /// </summary>
    public static SqlCommandSpec Build(SqlDialect dialect, ObjectName table, IReadOnlyList<string> keyColumns, IReadOnlyList<IReadOnlyList<object?>> keys)
    {
        ArgumentNullException.ThrowIfNull(dialect);
        ArgumentNullException.ThrowIfNull(keyColumns);
        ArgumentNullException.ThrowIfNull(keys);
        if (keyColumns.Count == 0 || keys.Count == 0 || keys.Any(k => k.Count != keyColumns.Count))
        {
            throw new ArgumentException("Every key needs one value per key column.", nameof(keys));
        }

        var qualified = dialect.Qualify(table);
        var quoted = keyColumns.Select(dialect.QuoteIdentifier).ToArray();
        var parameters = new List<KeyValuePair<string, object?>>(keys.Count * keyColumns.Count);
        var sql = new StringBuilder();
        for (var position = 0; position < keys.Count; position++)
        {
            if (position > 0)
            {
                sql.Append(" UNION ALL ");
            }

            sql.Append("SELECT ").Append(position.ToString(CultureInfo.InvariantCulture)).Append(", COUNT(*) FROM ").Append(qualified).Append(" WHERE ");
            for (var i = 0; i < quoted.Length; i++)
            {
                if (i > 0)
                {
                    sql.Append(" AND ");
                }

                var name = dialect.ParameterName(parameters.Count);
                parameters.Add(new(name, keys[position][i]));
                sql.Append(quoted[i]).Append(" = ").Append(name);
            }
        }

        return new SqlCommandSpec(sql.ToString(), parameters);
    }

    /// <summary>How many keys fit one probe under the engine's limit on bound parameters.</summary>
    public static int KeysPerStatement(SqlDialect dialect, int keyWidth)
    {
        ArgumentNullException.ThrowIfNull(dialect);
        var limit = dialect switch
        {
            SqlServerDialect => 2_100,
            SqliteDialect => 32_766,
            _ => 65_535,
        };
        return Math.Max(1, Math.Min(KeysPerProbe, limit / Math.Max(1, keyWidth)));
    }

    /// <summary>Reads the probe's rows of position and count back into key order.</summary>
    /// <exception cref="InvalidOperationException">A key's count is missing, so which rows exist is unknown.</exception>
    public static IReadOnlyList<long> ReadCounts(IEnumerable<(object? Position, object? Count)> rows, int expected)
    {
        ArgumentNullException.ThrowIfNull(rows);
        var counts = new long?[expected];
        foreach (var (position, count) in rows)
        {
            if (Integer(position) is { } index && index >= 0 && index < expected && Integer(count) is { } value)
            {
                counts[index] = value;
            }
        }

        return counts.All(c => c.HasValue)
            ? counts.Select(c => c!.Value).ToArray()
            : throw new InvalidOperationException("Could not read which rows are already in the table.");
    }

    private static long? Integer(object? value) => value switch
    {
        null or DBNull => null,
        IConvertible convertible => convertible.ToInt64(CultureInfo.InvariantCulture),
        _ => long.TryParse(value.ToString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed) ? parsed : null,
    };
}
