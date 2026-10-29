using TablePro.Core.Connections;

namespace TablePro.App.Helpers;

/// <summary>
/// How the connection form names its fields for an engine. Every engine stores the same profile fields; a cloud
/// service's "host" is an account or a region, its "password" an API token, and the labels say so.
/// </summary>
internal sealed record EngineForm
{
    // Initializers rather than parameter defaults, so the labels are read in the UI language when a form is built.
    public string HostLabel { get; init; } = Strings.Get("Connection/HostHeader");

    public string HostPlaceholder { get; init; } = "localhost";

    public string DatabaseLabel { get; init; } = Strings.Get("Connection/DatabaseHeader");

    public string UserLabel { get; init; } = Strings.Get("Connection/UserHeader");

    public string PasswordLabel { get; init; } = Strings.Get("Connection/PasswordHeader");

    public bool ShowPort { get; init; } = true;

    public bool ShowUser { get; init; } = true;

    public string? FileLabel { get; init; }

    public string? OptionsHint { get; init; }

    /// <summary>The sign-in methods the Authentication picker offers; one entry means the picker stays hidden.</summary>
    public IReadOnlyList<SignInMethod> SignInMethods { get; init; } = [SignInMethod.Password];

    /// <summary>The connection methods the Network page offers; file databases get Direct only.</summary>
    public IReadOnlyList<ConnectionTransport> Transports { get; init; } = [ConnectionTransport.Direct];

    /// <summary>What the Kerberos service field means for the engine, or null when it has none.</summary>
    public string? KerberosServiceHeader { get; init; }

    public string? KerberosServicePlaceholder { get; init; }

    /// <summary>PostgreSQL alone can encrypt with GSSAPI instead of TLS.</summary>
    public bool ShowGssEncryption { get; init; }

    public static EngineForm For(DatabaseEngine engine) => Labels(engine) with
    {
        SignInMethods = Core.Connections.SignInMethods.Available(engine),
        Transports = ConnectionTransports.Available(engine),
        KerberosServiceHeader = engine switch
        {
            DatabaseEngine.PostgreSql => Strings.Get("Connection/KerberosServiceHeader"),
            DatabaseEngine.MariaDb => Strings.Get("Connection/KerberosSpnHeader"),
            _ => null,
        },
        KerberosServicePlaceholder = engine switch
        {
            DatabaseEngine.PostgreSql => "postgres",
            DatabaseEngine.MariaDb => Strings.Get("Connection/KerberosSpnPlaceholder"),
            _ => null,
        },
        ShowGssEncryption = engine == DatabaseEngine.PostgreSql,
    };

    private static EngineForm Labels(DatabaseEngine engine) => engine switch
    {
        DatabaseEngine.Redis => new() { DatabaseLabel = Strings.Get("Connection/DatabaseIndexHeader"), UserLabel = Strings.Get("Connection/AclUserHeader"), OptionsHint = "syncTimeout=10000\nname=tablepro" },
        DatabaseEngine.MongoDb => new() { UserLabel = Strings.Get("Connection/UserOptionalHeader"), OptionsHint = "authSource=admin\nsrv=true\nreplicaSet=rs0" },
        DatabaseEngine.Oracle or DatabaseEngine.Dameng => new() { DatabaseLabel = Strings.Get("Connection/ServiceNameHeader"), OptionsHint = "sid=ORCL\ndbaPrivilege=SYSDBA" },
        DatabaseEngine.Cassandra or DatabaseEngine.ScyllaDb => new() { DatabaseLabel = Strings.Get("Connection/KeyspaceHeader"), UserLabel = Strings.Get("Connection/UserOptionalHeader"), OptionsHint = "localDatacenter=datacenter1\ncontactPoints=10.0.0.1,10.0.0.2\nconsistency=LOCAL_QUORUM" },
        DatabaseEngine.Snowflake => new() { HostLabel = Strings.Get("Connection/AccountHeader"), HostPlaceholder = "xy12345.eu-central-1", ShowPort = false, FileLabel = Strings.Get("Connection/SnowflakeKeyFileHeader"), OptionsHint = "warehouse=COMPUTE_WH\nrole=ANALYST\nauthenticator=externalbrowser" },
        DatabaseEngine.BigQuery => new() { HostLabel = Strings.Get("Connection/ProjectHeader"), HostPlaceholder = "my-gcp-project", ShowPort = false, ShowUser = false, PasswordLabel = Strings.Get("Connection/PasswordUnusedHeader"), FileLabel = Strings.Get("Connection/BigQueryKeyFileHeader"), OptionsHint = "maxBytesBilled=10000000000\nlocation=EU" },
        DatabaseEngine.Spanner => new() { HostLabel = Strings.Get("Connection/DatabasePathHeader"), HostPlaceholder = "projects/p/instances/i/databases/d", ShowPort = false, ShowUser = false, FileLabel = Strings.Get("Connection/ServiceAccountJsonHeader"), OptionsHint = "emulatorHost=localhost:9010" },
        DatabaseEngine.Trino => new() { DatabaseLabel = Strings.Get("Connection/CatalogHeader"), OptionsHint = "catalog=hive\nschema=default" },
        DatabaseEngine.DynamoDb => new() { HostLabel = Strings.Get("Connection/RegionHeader"), HostPlaceholder = "us-east-1", ShowPort = false, UserLabel = Strings.Get("Connection/AccessKeyIdOptionalHeader"), PasswordLabel = Strings.Get("Connection/SecretAccessKeyHeader"), OptionsHint = "profile=default\nendpoint=http://localhost:8000\nsessionToken=" },
        DatabaseEngine.Elasticsearch => new() { UserLabel = Strings.Get("Connection/UserOptionalHeader"), PasswordLabel = Strings.Get("Connection/PasswordOrApiKeyHeader"), OptionsHint = "auth=apikey\ncloudId=" },
        DatabaseEngine.Typesense or DatabaseEngine.Weaviate => new() { ShowUser = false, PasswordLabel = Strings.Get("Connection/ApiKeyHeader") },
        DatabaseEngine.Kafka => new() { HostLabel = Strings.Get("Connection/BootstrapServerHeader"), HostPlaceholder = "broker1:9092", UserLabel = Strings.Get("Connection/SaslUserHeader"), PasswordLabel = Strings.Get("Connection/SaslPasswordHeader"), OptionsHint = "saslMechanism=SCRAM-SHA-512\nbootstrapServers=b1:9092,b2:9092" },
        DatabaseEngine.Etcd => new() { UserLabel = Strings.Get("Connection/UserOptionalHeader"), OptionsHint = "prefix=/" },
        DatabaseEngine.SurrealDb => new() { DatabaseLabel = Strings.Get("Connection/NamespaceDatabaseHeader"), OptionsHint = "namespace=test" },
        DatabaseEngine.CloudflareD1 or DatabaseEngine.CloudflareR2Sql => new() { HostLabel = Strings.Get("Connection/AccountIdHeader"), HostPlaceholder = "0123456789abcdef", ShowPort = false, ShowUser = false, DatabaseLabel = Strings.Get("Connection/DatabaseIdHeader"), PasswordLabel = Strings.Get("Connection/ApiTokenHeader") },
        DatabaseEngine.LibSql or DatabaseEngine.Turso => new() { HostLabel = Strings.Get("Connection/UrlHeader"), HostPlaceholder = "libsql://my-db-me.turso.io", ShowPort = engine == DatabaseEngine.LibSql, ShowUser = false, PasswordLabel = Strings.Get("Connection/AuthTokenHeader") },
        DatabaseEngine.Teradata => new() { DatabaseLabel = Strings.Get("Connection/DefaultDatabaseHeader"), OptionsHint = "logmech=LDAP\nSession Mode=ANSI" },
        DatabaseEngine.Beancount => new() { OptionsHint = "backend=python\npython=py\nrledger=C:\\Tools\\rledger.exe\nbeancountRunLedgerPlugins=true" },
        DatabaseEngine.ClickHouse => new() { OptionsHint = "set_max_execution_time=60" },
        _ => new(),
    };
}
