namespace TablePro.Core.Connections;

/// <summary>
/// Every engine TablePro knows, as tablepro.app/databases lists them. The value is stored in connections.json, so new
/// members go at the end. Whether this build can open one is the driver registry's answer, not this enum's.
/// </summary>
public enum DatabaseEngine
{
    PostgreSql,
    MySql,
    MariaDb,
    SqlServer,
    Sqlite,
    DuckDb,
    Redis,
    MongoDb,
    ClickHouse,
    Oracle,
    Cassandra,
    ScyllaDb,
    CockroachDb,
    Redshift,
    TiDb,
    OceanBase,
    Databend,
    PGlite,
    LibSql,
    Turso,
    Snowflake,
    BigQuery,
    Trino,
    Spanner,
    Teradata,
    DynamoDb,
    Elasticsearch,
    Typesense,
    Weaviate,
    Kafka,
    Etcd,
    SurrealDb,
    CloudflareD1,
    CloudflareR2Sql,
    Dameng,
    SapHana,
    Beancount,
}

/// <summary>What an engine holds, which decides how the sidebar lists it and which views open.</summary>
public enum DataModel
{
    /// <summary>Schemas of tables and views, queried with SQL.</summary>
    Relational,

    /// <summary>Databases of keys, each a typed value, read and written with commands.</summary>
    KeyValue,

    /// <summary>Databases of collections of documents, queried in the engine's own language.</summary>
    Document,

    /// <summary>Keyspaces of tables partitioned across a cluster, queried with CQL.</summary>
    WideColumn,

    /// <summary>Indexes of documents searched through a request console.</summary>
    Search,

    /// <summary>Topics of messages.</summary>
    Streaming,
}

/// <summary>The families tablepro.app groups engines into, used to group the connection form's engine list.</summary>
public enum EngineFamily
{
    Relational,
    Analytical,
    Cloud,
    Document,
    KeyValue,
    WideColumn,
    Search,
    Streaming,
    Coordination,
    Files,
}
