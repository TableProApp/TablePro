using TablePro.Core.Connections;

namespace TablePro.App.Helpers;

/// <summary>
/// How the connection form names its fields for an engine. Every engine stores the same profile fields; a cloud
/// service's "host" is an account or a region, its "password" an API token, and the labels say so.
/// </summary>
internal sealed record EngineForm(
    string HostLabel = "Host",
    string HostPlaceholder = "localhost",
    string DatabaseLabel = "Database",
    string UserLabel = "User",
    string PasswordLabel = "Password",
    bool ShowPort = true,
    bool ShowUser = true,
    string? FileLabel = null,
    string? OptionsHint = null)
{
    public static EngineForm For(DatabaseEngine engine) => engine switch
    {
        DatabaseEngine.Redis => new(DatabaseLabel: "Database index", UserLabel: "ACL user (optional)", OptionsHint: "syncTimeout=10000\nname=tablepro"),
        DatabaseEngine.MongoDb => new(DatabaseLabel: "Database", UserLabel: "User (optional)", OptionsHint: "authSource=admin\nsrv=true\nreplicaSet=rs0"),
        DatabaseEngine.Oracle or DatabaseEngine.Dameng => new(DatabaseLabel: "Service name", OptionsHint: "sid=ORCL\ndbaPrivilege=SYSDBA"),
        DatabaseEngine.Cassandra or DatabaseEngine.ScyllaDb => new(DatabaseLabel: "Keyspace", UserLabel: "User (optional)", OptionsHint: "localDatacenter=datacenter1\ncontactPoints=10.0.0.1,10.0.0.2\nconsistency=LOCAL_QUORUM"),
        DatabaseEngine.Snowflake => new("Account", "xy12345.eu-central-1", ShowPort: false, FileLabel: "Private key file (key-pair sign-in)", OptionsHint: "warehouse=COMPUTE_WH\nrole=ANALYST\nauthenticator=externalbrowser"),
        DatabaseEngine.BigQuery => new("Project", "my-gcp-project", ShowPort: false, ShowUser: false, PasswordLabel: "Password (unused)", FileLabel: "Service account JSON (empty uses gcloud sign-in)", OptionsHint: "maxBytesBilled=10000000000\nlocation=EU"),
        DatabaseEngine.Spanner => new("Database path", "projects/p/instances/i/databases/d", ShowPort: false, ShowUser: false, FileLabel: "Service account JSON", OptionsHint: "emulatorHost=localhost:9010"),
        DatabaseEngine.Trino => new(DatabaseLabel: "Catalog", OptionsHint: "catalog=hive\nschema=default"),
        DatabaseEngine.DynamoDb => new("Region", "us-east-1", ShowPort: false, UserLabel: "Access key ID (optional)", PasswordLabel: "Secret access key", OptionsHint: "profile=default\nendpoint=http://localhost:8000\nsessionToken="),
        DatabaseEngine.Elasticsearch => new(UserLabel: "User (optional)", PasswordLabel: "Password or API key", OptionsHint: "auth=apikey\ncloudId="),
        DatabaseEngine.Typesense or DatabaseEngine.Weaviate => new(ShowUser: false, PasswordLabel: "API key"),
        DatabaseEngine.Kafka => new("Bootstrap server", "broker1:9092", UserLabel: "SASL user (optional)", PasswordLabel: "SASL password", OptionsHint: "saslMechanism=SCRAM-SHA-512\nbootstrapServers=b1:9092,b2:9092"),
        DatabaseEngine.Etcd => new(UserLabel: "User (optional)", OptionsHint: "prefix=/"),
        DatabaseEngine.SurrealDb => new(DatabaseLabel: "Namespace/database", OptionsHint: "namespace=test"),
        DatabaseEngine.CloudflareD1 or DatabaseEngine.CloudflareR2Sql => new("Account ID", "0123456789abcdef", ShowPort: false, ShowUser: false, DatabaseLabel: "Database ID or name", PasswordLabel: "API token"),
        DatabaseEngine.LibSql or DatabaseEngine.Turso => new("URL", "libsql://my-db-me.turso.io", ShowPort: engine == DatabaseEngine.LibSql, ShowUser: false, PasswordLabel: "Auth token"),
        DatabaseEngine.Teradata => new(DatabaseLabel: "Default database", OptionsHint: "logmech=LDAP\nSession Mode=ANSI"),
        DatabaseEngine.Beancount => new(OptionsHint: "backend=python\npython=py\nrledger=C:\\Tools\\rledger.exe\nbeancountRunLedgerPlugins=true"),
        DatabaseEngine.ClickHouse => new(OptionsHint: "set_max_execution_time=60"),
        _ => new(),
    };
}
