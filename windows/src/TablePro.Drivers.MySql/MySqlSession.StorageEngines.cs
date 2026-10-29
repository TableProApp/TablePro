using System.Globalization;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Schema;

namespace TablePro.Drivers.MySql;

/// <summary>Each table's storage engine, which decides whether a sync's ROLLBACK reaches it.</summary>
public sealed partial class MySqlSession : IStorageEngineProvider
{
    /// <summary>Names per catalog query: a schema-wide sync takes a few round trips, and no statement grows without bound.</summary>
    internal const int StorageEngineNamesPerQuery = 500;

    private static readonly IReadOnlyDictionary<ObjectName, string> NoStorageEngines = new Dictionary<ObjectName, string>();

    public Task<IReadOnlyDictionary<ObjectName, string>> GetStorageEnginesAsync(IReadOnlyCollection<ObjectName> tables, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(tables);

        // TiDB, OceanBase and Databend fill ENGINE with names of their own that say nothing about ROLLBACK, so only
        // MySQL and MariaDB are asked, as on macOS.
        if (Profile.Engine is not (DatabaseEngine.MySql or DatabaseEngine.MariaDb) || tables.Count == 0)
        {
            return Task.FromResult(NoStorageEngines);
        }

        return WithConnectionAsync<IReadOnlyDictionary<ObjectName, string>>(
            async (connection, ct) =>
            {
                var engines = new Dictionary<ObjectName, string>();
                foreach (var database in tables.Distinct().GroupBy(t => string.IsNullOrEmpty(t.Schema) ? null : t.Schema))
                {
                    foreach (var chunk in database.Chunk(StorageEngineNamesPerQuery))
                    {
                        var (sql, parameters) = StorageEngineQuery(database.Key, chunk);
                        var rows = await QueryAsync(connection, sql, static r => (r.GetString(0), NullableString(r, 1)), ct, parameters);
                        MatchStorageEngines(chunk, rows, engines);
                    }
                }

                return engines;
            },
            cancellationToken);
    }

    /// <summary>The catalog query for <paramref name="tables"/> in one database (null for the connection's own), every name bound.</summary>
    internal static (string Sql, (string Name, object? Value)[] Parameters) StorageEngineQuery(string? database, IReadOnlyList<ObjectName> tables)
    {
        ArgumentNullException.ThrowIfNull(tables);
        var parameters = new (string, object?)[tables.Count + 1];
        parameters[0] = ("@schema", database);
        for (var i = 0; i < tables.Count; i++)
        {
            parameters[i + 1] = ("@t" + i.ToString(CultureInfo.InvariantCulture), tables[i].Name);
        }

        return (MySqlCatalog.StorageEngines(tables.Count), parameters);
    }

    /// <summary>
    /// Keys each catalog row by the name as asked. The catalog answers with the stored spelling, which differs from
    /// the asked one only where table names ignore case (lower_case_table_names 1 or 2), so an exact match wins and a
    /// case-folded one fills in after it.
    /// </summary>
    internal static void MatchStorageEngines(IReadOnlyList<ObjectName> asked, IReadOnlyList<(string Name, string? Engine)> rows, Dictionary<ObjectName, string> engines)
    {
        ArgumentNullException.ThrowIfNull(asked);
        ArgumentNullException.ThrowIfNull(rows);
        ArgumentNullException.ThrowIfNull(engines);
        var exact = asked.ToLookup(t => t.Name, StringComparer.Ordinal);
        var folded = asked.ToLookup(t => t.Name, StringComparer.OrdinalIgnoreCase);
        foreach (var (name, engine) in rows)
        {
            if (!string.IsNullOrEmpty(engine))
            {
                foreach (var table in exact[name])
                {
                    engines[table] = engine;
                }
            }
        }

        foreach (var (name, engine) in rows)
        {
            if (!string.IsNullOrEmpty(engine))
            {
                foreach (var table in folded[name])
                {
                    engines.TryAdd(table, engine);
                }
            }
        }
    }
}
