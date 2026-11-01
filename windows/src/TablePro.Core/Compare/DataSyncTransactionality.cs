using System.Collections.Frozen;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Localization;
using TablePro.Core.Schema;

namespace TablePro.Core.Compare;

/// <summary>A table whose storage engine ignores ROLLBACK, such as a MyISAM table, with the engine the catalog named.</summary>
public readonly record struct NonTransactionalTable(ObjectName Table, string StorageEngine);

/// <summary>
/// Which writes a failed sync can take back. A whole engine can lack transactions, and on MySQL and MariaDB a single
/// table can, through its storage engine; either way the batches or rows before the failure stay.
/// </summary>
public static class DataSyncTransactionality
{
    // The engines MySQL and MariaDB ship, or have shipped, that take part in a transaction; the macOS app keeps the
    // same list. Every other engine (MyISAM, Aria, MEMORY, ARCHIVE, CSV, MERGE...) ignores ROLLBACK.
    private static readonly FrozenSet<string> TransactionalStorageEngines =
        new[] { "InnoDB", "XtraDB", "NDB", "ndbcluster", "TokuDB", "RocksDB" }.ToFrozenSet(StringComparer.OrdinalIgnoreCase);

    public static bool CanRollBack(DatabaseEngine engine) => engine switch
    {
        DatabaseEngine.ClickHouse or DatabaseEngine.Cassandra or DatabaseEngine.ScyllaDb or DatabaseEngine.BigQuery
            or DatabaseEngine.Redis or DatabaseEngine.MongoDb or DatabaseEngine.DynamoDb or DatabaseEngine.Elasticsearch
            or DatabaseEngine.Typesense or DatabaseEngine.Weaviate or DatabaseEngine.Kafka or DatabaseEngine.Etcd
            or DatabaseEngine.Trino or DatabaseEngine.Databend or DatabaseEngine.CloudflareD1 => false,
        _ => true,
    };

    /// <summary>
    /// Whether a table on <paramref name="storageEngine"/> takes a write back. An unknown engine counts as able to,
    /// so only a table the catalog names on a non-transactional engine is flagged.
    /// </summary>
    public static bool CanRollBack(string? storageEngine) =>
        string.IsNullOrWhiteSpace(storageEngine) || TransactionalStorageEngines.Contains(storageEngine.Trim());

    /// <summary>
    /// The tables among <paramref name="tables"/> that cannot roll back, in the order given. Empty for a session whose
    /// tables do not choose a storage engine, without a round trip.
    /// </summary>
    public static async Task<IReadOnlyList<NonTransactionalTable>> NonTransactionalTablesAsync(
        IDatabaseSession session, IEnumerable<ObjectName> tables, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(session);
        ArgumentNullException.ThrowIfNull(tables);
        if (session is not IStorageEngineProvider provider)
        {
            return [];
        }

        var distinct = tables.Distinct().ToArray();
        if (distinct.Length == 0)
        {
            return [];
        }

        var engines = await provider.GetStorageEnginesAsync(distinct, cancellationToken);
        var flagged = new List<NonTransactionalTable>();
        foreach (var table in distinct)
        {
            if (engines.TryGetValue(table, out var engine) && !CanRollBack(engine))
            {
                flagged.Add(new NonTransactionalTable(table, engine));
            }
        }

        return flagged;
    }

    /// <summary>The review sheet's note naming each table that cannot roll back and its engine, or null when there is none.</summary>
    public static string? ReviewNote(IReadOnlyList<NonTransactionalTable> tables)
    {
        ArgumentNullException.ThrowIfNull(tables);
        return tables.Count == 0
            ? null
            : CoreStrings.Plural("Compare/NonTransactionalTables", tables.Count, string.Join(", ", tables.Select(t => $"{t.Table} ({t.StorageEngine})")));
    }

    /// <summary>
    /// What a failed run that was rolled back still left behind: the tables among <paramref name="tables"/> it wrote
    /// to, which kept those rows. Null when it wrote to none of them, so the rollback was whole.
    /// </summary>
    public static string? RollbackLeftWritesNote(IReadOnlyList<NonTransactionalTable> tables, IReadOnlyCollection<ObjectName> written)
    {
        ArgumentNullException.ThrowIfNull(tables);
        ArgumentNullException.ThrowIfNull(written);
        var kept = tables.Where(t => written.Contains(t.Table)).Select(t => t.Table.ToString()).ToArray();
        return kept.Length == 0 ? null : CoreStrings.Format("Compare/RollbackLeftWrites", string.Join(", ", kept));
    }
}
