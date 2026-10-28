using System.Collections.Frozen;

namespace TablePro.Core.Connections;

/// <summary>What the app knows about an engine before any connection exists.</summary>
public sealed record EngineDescriptor(
    DatabaseEngine Engine,
    string DisplayName,
    int DefaultPort,
    bool IsFileBased,
    bool HasSchemas,
    string DefaultUser,
    string FileExtensions)
{
    private static readonly FrozenDictionary<DatabaseEngine, EngineDescriptor> All = new EngineDescriptor[]
    {
        new(DatabaseEngine.PostgreSql, "PostgreSQL", 5432, false, true, "postgres", ""),
        new(DatabaseEngine.MySql, "MySQL", 3306, false, false, "root", ""),
        new(DatabaseEngine.MariaDb, "MariaDB", 3306, false, false, "root", ""),
        new(DatabaseEngine.SqlServer, "SQL Server", 1433, false, true, "sa", ""),
        new(DatabaseEngine.Sqlite, "SQLite", 0, true, false, "", ".sqlite;.sqlite3;.db;.db3") { Family = EngineFamily.Files },
        new(DatabaseEngine.DuckDb, "DuckDB", 0, true, true, "", ".duckdb;.ddb") { Family = EngineFamily.Files },
        new(DatabaseEngine.Redis, "Redis", 6379, false, true, "", "") { Family = EngineFamily.KeyValue, DataModel = DataModel.KeyValue, QueryLanguage = "Redis CLI", UsernameRequired = false },
        new(DatabaseEngine.MongoDb, "MongoDB", 27017, false, true, "", "") { Family = EngineFamily.Document, DataModel = DataModel.Document, QueryLanguage = "MQL", UsernameRequired = false },
        new(DatabaseEngine.ClickHouse, "ClickHouse", 8123, false, true, "default", "") { Family = EngineFamily.Analytical, TlsDefaultPort = 8443 },
        new(DatabaseEngine.Oracle, "Oracle", 1521, false, true, "system", "") { QueryLanguage = "SQL and PL/SQL" },
        new(DatabaseEngine.Cassandra, "Cassandra", 9042, false, true, "cassandra", "") { Family = EngineFamily.WideColumn, DataModel = DataModel.WideColumn, QueryLanguage = "CQL", UsernameRequired = false },
        new(DatabaseEngine.ScyllaDb, "ScyllaDB", 9042, false, true, "cassandra", "") { Family = EngineFamily.WideColumn, DataModel = DataModel.WideColumn, QueryLanguage = "CQL", UsernameRequired = false },
        new(DatabaseEngine.CockroachDb, "CockroachDB", 26257, false, true, "root", ""),
        new(DatabaseEngine.Redshift, "Amazon Redshift", 5439, false, true, "awsuser", "") { Family = EngineFamily.Analytical },
        new(DatabaseEngine.TiDb, "TiDB", 4000, false, false, "root", ""),
        new(DatabaseEngine.OceanBase, "OceanBase", 2881, false, false, "root", ""),
        new(DatabaseEngine.Databend, "Databend", 3307, false, false, "root", "") { Family = EngineFamily.Analytical },
        new(DatabaseEngine.PGlite, "PGlite", 5432, false, true, "postgres", ""),
        new(DatabaseEngine.LibSql, "libSQL", 8080, false, false, "", ".db;.sqlite;.libsql") { Family = EngineFamily.Cloud, UsernameRequired = false },
        new(DatabaseEngine.Turso, "Turso", 443, false, false, "", "") { Family = EngineFamily.Cloud, UsernameRequired = false },
        new(DatabaseEngine.Snowflake, "Snowflake", 443, false, true, "", "") { Family = EngineFamily.Analytical },
        new(DatabaseEngine.BigQuery, "Google BigQuery", 443, false, true, "", "") { Family = EngineFamily.Analytical, QueryLanguage = "GoogleSQL", UsernameRequired = false },
        new(DatabaseEngine.Trino, "Trino", 8080, false, true, "trino", "") { Family = EngineFamily.Analytical },
        new(DatabaseEngine.Spanner, "Google Cloud Spanner", 443, false, true, "", "") { QueryLanguage = "GoogleSQL", UsernameRequired = false },
        new(DatabaseEngine.Teradata, "Teradata", 1025, false, true, "dbc", "") { Family = EngineFamily.Analytical },
        new(DatabaseEngine.DynamoDb, "Amazon DynamoDB", 443, false, false, "", "") { Family = EngineFamily.KeyValue, DataModel = DataModel.KeyValue, QueryLanguage = "PartiQL", UsernameRequired = false },
        new(DatabaseEngine.Elasticsearch, "Elasticsearch", 9200, false, false, "elastic", "") { Family = EngineFamily.Search, DataModel = DataModel.Search, QueryLanguage = "Query DSL", UsernameRequired = false },
        new(DatabaseEngine.Typesense, "Typesense", 8108, false, false, "", "") { Family = EngineFamily.Search, DataModel = DataModel.Search, QueryLanguage = "Typesense API", UsernameRequired = false },
        new(DatabaseEngine.Weaviate, "Weaviate", 8080, false, false, "", "") { Family = EngineFamily.Search, DataModel = DataModel.Search, QueryLanguage = "GraphQL", UsernameRequired = false },
        new(DatabaseEngine.Kafka, "Apache Kafka", 9092, false, false, "", "") { Family = EngineFamily.Streaming, DataModel = DataModel.Streaming, QueryLanguage = "KafkaQL", UsernameRequired = false },
        new(DatabaseEngine.Etcd, "etcd", 2379, false, false, "", "") { Family = EngineFamily.Coordination, DataModel = DataModel.KeyValue, QueryLanguage = "etcdctl", UsernameRequired = false },
        new(DatabaseEngine.SurrealDb, "SurrealDB", 8000, false, true, "root", "") { Family = EngineFamily.Document, DataModel = DataModel.Document, QueryLanguage = "SurrealQL" },
        new(DatabaseEngine.CloudflareD1, "Cloudflare D1", 443, false, false, "", "") { Family = EngineFamily.Cloud, UsernameRequired = false },
        new(DatabaseEngine.CloudflareR2Sql, "Cloudflare R2 SQL", 443, false, true, "", "") { Family = EngineFamily.Cloud, UsernameRequired = false, IsReadOnly = true },
        new(DatabaseEngine.Dameng, "Dameng DM8", 5236, false, true, "SYSDBA", ""),
        new(DatabaseEngine.SapHana, "SAP HANA", 30015, false, true, "SYSTEM", ""),
        new(DatabaseEngine.Beancount, "Beancount", 0, true, false, "", ".beancount;.bean") { Family = EngineFamily.Files, UsernameRequired = false, IsReadOnly = true },
    }.ToFrozenDictionary(d => d.Engine);

    public EngineFamily Family { get; init; } = EngineFamily.Relational;

    public DataModel DataModel { get; init; } = DataModel.Relational;

    public string QueryLanguage { get; init; } = "SQL";

    /// <summary>The port a server listens on for TLS when it differs from <see cref="DefaultPort"/>, as ClickHouse's HTTPS on 8443.</summary>
    public int? TlsDefaultPort { get; init; }

    /// <summary>Engines TablePro only reads, such as a ledger file or R2 SQL over Iceberg, whatever the Safe Mode level.</summary>
    public bool IsReadOnly { get; init; }

    /// <summary>Engines that accept a connection without a login leave the user field optional in the form.</summary>
    public bool UsernameRequired { get; init; } = true;

    public bool IsSql => DataModel is DataModel.Relational or DataModel.WideColumn || Engine is DatabaseEngine.DynamoDb;

    public static IEnumerable<EngineDescriptor> Engines => All.Values.OrderBy(d => d.Family).ThenBy(d => d.Engine);

    public static EngineDescriptor For(DatabaseEngine engine) => All[engine];
}
