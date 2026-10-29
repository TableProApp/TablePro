namespace TablePro.Core.Connections;

/// <summary>
/// The two letters a connection shows in its tile on the welcome window, one pair per engine. Every engine has its
/// own, so no connection is drawn with a placeholder.
/// </summary>
public static class EngineBadge
{
    public static string For(DatabaseEngine engine) => engine switch
    {
        DatabaseEngine.PostgreSql => "Pg",
        DatabaseEngine.MySql => "My",
        DatabaseEngine.MariaDb => "Ma",
        DatabaseEngine.SqlServer => "Ms",
        DatabaseEngine.Sqlite => "Sl",
        DatabaseEngine.DuckDb => "Dk",
        DatabaseEngine.Redis => "Rd",
        DatabaseEngine.MongoDb => "Mg",
        DatabaseEngine.ClickHouse => "Ch",
        DatabaseEngine.Oracle => "Or",
        DatabaseEngine.Cassandra => "Ca",
        DatabaseEngine.ScyllaDb => "Sc",
        DatabaseEngine.CockroachDb => "Cr",
        DatabaseEngine.Redshift => "Rs",
        DatabaseEngine.TiDb => "Ti",
        DatabaseEngine.OceanBase => "Ob",
        DatabaseEngine.Databend => "Db",
        DatabaseEngine.PGlite => "Pl",
        DatabaseEngine.LibSql => "Ls",
        DatabaseEngine.Turso => "Tu",
        DatabaseEngine.Snowflake => "Sf",
        DatabaseEngine.BigQuery => "Bq",
        DatabaseEngine.Trino => "Tr",
        DatabaseEngine.Spanner => "Sp",
        DatabaseEngine.Teradata => "Td",
        DatabaseEngine.DynamoDb => "Dy",
        DatabaseEngine.Elasticsearch => "Es",
        DatabaseEngine.Typesense => "Ts",
        DatabaseEngine.Weaviate => "Wv",
        DatabaseEngine.Kafka => "Kf",
        DatabaseEngine.Etcd => "Et",
        DatabaseEngine.SurrealDb => "Su",
        DatabaseEngine.CloudflareD1 => "D1",
        DatabaseEngine.CloudflareR2Sql => "R2",
        DatabaseEngine.Dameng => "Dm",
        DatabaseEngine.SapHana => "Hn",
        DatabaseEngine.Beancount => "Bc",
        _ => engine.ToString()[..Math.Min(2, engine.ToString().Length)],
    };
}
