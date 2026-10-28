namespace TablePro.Drivers.ClickHouse;

/// <summary>
/// Catalog SQL over the <c>system</c> tables. Names are bound as <c>{db:String}</c> and <c>{table:String}</c> and the
/// database is always named, because a session reads other databases than the one it connected to.
/// </summary>
internal static class ClickHouseCatalog
{
    public const string Databases = """
        SELECT name FROM system.databases
        WHERE name NOT IN ('INFORMATION_SCHEMA', 'information_schema')
        ORDER BY name
        """;

    // Inner tables of materialized views are named '.inner...' and belong to their view.
    public const string Objects = """
        SELECT name, engine, total_rows, comment
        FROM system.tables
        WHERE database = {db:String} AND NOT is_temporary AND name NOT LIKE '.%'
        ORDER BY name
        """;

    public const string Columns = """
        SELECT name, type, default_kind, default_expression, comment, is_in_primary_key, is_in_sorting_key
        FROM system.columns
        WHERE database = {db:String} AND table = {table:String}
        ORDER BY position
        """;

    public const string Indexes = """
        SELECT 'PRIMARY' AS name, 'sorting key' AS type, sorting_key AS expr, 1 AS is_primary
        FROM system.tables
        WHERE database = {db:String} AND name = {table:String} AND sorting_key != ''
        UNION ALL
        SELECT name, type, expr, 0 AS is_primary
        FROM system.data_skipping_indices
        WHERE database = {db:String} AND table = {table:String}
        """;

    // ClickHouse has no constraint catalog; the checks are read out of create_table_query.
    public const string TableDetails = """
        SELECT engine, partition_key, sorting_key, primary_key, sampling_key, comment, create_table_query
        FROM system.tables
        WHERE database = {db:String} AND name = {table:String}
        """;

    // A partition is the set of active parts that share a partition id; partition holds the key's value as text.
    public const string Partitions = """
        SELECT partition_id, any(partition), sum(rows), sum(bytes_on_disk)
        FROM system.parts
        WHERE database = {db:String} AND table = {table:String} AND active
        GROUP BY partition_id
        ORDER BY partition_id
        """;

    /// <summary>Columns a mutation may not assign.</summary>
    public const string KeyColumns = """
        SELECT name FROM system.columns
        WHERE database = {db:String} AND table = {table:String}
          AND (is_in_sorting_key OR is_in_primary_key OR is_in_partition_key)
        """;

    public const string Activity = """
        SELECT query_id, user, toString(address) AS address, round(elapsed, 1) AS elapsed_s, read_rows,
               formatReadableSize(memory_usage) AS memory, query
        FROM system.processes
        ORDER BY elapsed DESC
        """;

    public const string Kill = "KILL QUERY WHERE query_id = {id:String} ASYNC";

    public const string Variables = """
        SELECT 'setting' AS kind, name, value, description FROM system.settings
        UNION ALL
        SELECT 'metric' AS kind, metric AS name, toString(value) AS value, description FROM system.metrics
        ORDER BY kind DESC, name
        """;

    public const string Users = """
        SELECT name, storage, toString(auth_type) AS auth_type, toString(host_ip) AS host_ip,
               toString(host_names) AS host_names, toString(default_roles_list) AS default_roles
        FROM system.users
        ORDER BY name
        """;
}
