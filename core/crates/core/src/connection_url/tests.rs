use std::path::PathBuf;

use secrecy::ExposeSecret;

use super::*;
use crate::TlsMode;

fn read(url: &str) -> ConnectionUrl {
    match parse(url) {
        Ok(parsed) => parsed,
        Err(error) => panic!("{url}: {error}"),
    }
}

fn password(parsed: &ConnectionUrl) -> Option<&str> {
    parsed.password.as_ref().map(ExposeSecret::expose_secret)
}

fn mode(url: &str) -> Option<TlsMode> {
    read(url).tls.mode
}

fn refused(url: &str) -> ConnectionUrlError {
    match parse(url) {
        Ok(parsed) => panic!("{url} parsed as {parsed:?}"),
        Err(error) => error,
    }
}

#[test]
fn a_postgres_url_gives_every_field_decoded() {
    let parsed = read("postgresql://app%40corp:p%40ss@db.example.com:6543/shop%20db?sslmode=verify-full");

    assert_eq!(parsed.driver_id, "postgres");
    assert_eq!(parsed.host, "db.example.com");
    assert_eq!(parsed.port, Some(6543));
    assert_eq!(parsed.username, "app@corp");
    assert_eq!(password(&parsed), Some("p@ss"));
    assert_eq!(parsed.database, "shop db");
    assert_eq!(parsed.tls.mode, Some(TlsMode::VerifyFull));
}

#[test]
fn provider_urls_fill_the_login_and_their_tls() {
    let supabase = read("postgresql://postgres.abcdefgh:s3cret@aws-1-eu-west-2.pooler.supabase.com:6543/postgres");
    assert_eq!(supabase.username, "postgres.abcdefgh");
    assert_eq!(supabase.port, Some(6543));
    assert_eq!(supabase.tls, UrlTls::default());

    let neon = read(
        "postgresql://alex:AbC123dEf@ep-cool-darkness-a1b2c3d4-pooler.us-east-2.aws.neon.tech/dbname?sslmode=require&channel_binding=require",
    );
    assert_eq!(neon.port, None);
    assert_eq!(neon.database, "dbname");
    assert_eq!(
        neon.tls.mode,
        Some(TlsMode::VerifyFull),
        "channel_binding=require asks for no password to a server in the middle"
    );
    assert_eq!(
        mode("postgresql://db/x?sslmode=require&channel_binding=prefer"),
        Some(TlsMode::Require)
    );

    let heroku =
        read("postgres://u1:pw@ec2-1-2-3-4.compute-1.amazonaws.com:5432/d9?sslmode=verify-full&sslrootcert=system");
    assert_eq!(heroku.tls.mode, Some(TlsMode::VerifyFull));

    let atlas = read("mongodb+srv://ada:pw@cluster0.abcde.mongodb.net/?retryWrites=true&w=majority&appName=Cluster0");
    assert!(atlas.options.dns_seed_list);
    assert_eq!(atlas.tls.mode, Some(TlsMode::VerifyFull));

    let upstash = read("rediss://default:token@eu1-cool-cat-12345.upstash.io:6379");
    assert_eq!(upstash.username, "default");
    assert_eq!(upstash.tls.mode, Some(TlsMode::VerifyFull));

    let planetscale = read("mysql://user:pscale_pw_x@aws.connect.psdb.cloud/app?sslaccept=strict");
    assert_eq!(planetscale.tls.mode, Some(TlsMode::VerifyFull));

    let aiven = read("mysql://avnadmin:pw@demo-mysql.aivencloud.com:13039/defaultdb?ssl-mode=REQUIRED");
    assert_eq!(aiven.tls.mode, Some(TlsMode::Require));
}

#[test]
fn a_password_keeps_unescaped_at_signs_and_hashes_and_a_database_its_at_sign() {
    let parsed = read("postgresql://app:p@ss#w0rd@db.example.com/shop?sslmode=disable");

    assert_eq!(password(&parsed), Some("p@ss#w0rd"));
    assert_eq!(parsed.host, "db.example.com");
    assert_eq!(parsed.database, "shop");
    let archive = read("postgresql://alice:secret@db.example.com/team@archive");
    assert_eq!(
        (archive.host.as_str(), archive.database.as_str()),
        ("db.example.com", "team@archive")
    );
    assert_eq!(password(&archive), Some("secret"));
    assert_eq!(parsed.tls.mode, Some(TlsMode::Disable));
    let no_userinfo = read("postgresql://db.example.com/team@archive?user=ada&password=secret");
    assert_eq!(no_userinfo.host, "db.example.com");
    assert_eq!(
        (no_userinfo.username.as_str(), no_userinfo.database.as_str()),
        ("ada", "team@archive")
    );
    let relayed = read("postgresql://ada:pre@relay.example/tail@db.example/shop");
    assert_eq!(relayed.host, "relay.example", "a path's @ moved the destination");
}

#[test]
fn plus_is_a_plus_and_bad_utf8_is_refused() {
    assert_eq!(password(&read("postgresql://u:a+b@db/x")), Some("a+b"));
    assert_eq!(refused("postgresql://u:%FF@db/x"), ConnectionUrlError::Invalid);
}

#[test]
fn libpq_modes_map_and_prefer_leaves_the_default() {
    assert_eq!(mode("postgresql://db/x?sslmode=disable"), Some(TlsMode::Disable));
    assert_eq!(mode("postgresql://db/x?sslmode=prefer"), None);
    assert_eq!(mode("postgresql://db/x?sslmode=allow"), None);
    assert_eq!(mode("postgresql://db/x?sslmode=require"), Some(TlsMode::Require));
    assert_eq!(mode("postgresql://db/x?SSLMODE=VERIFY_CA"), Some(TlsMode::VerifyFull));
    assert_eq!(mode("postgresql://db/x?tlsmode=2"), Some(TlsMode::Require));
    assert_eq!(mode("postgresql://db/x?tlsmode=0"), Some(TlsMode::Disable));
    assert_eq!(mode("postgresql://db/x"), None);
    assert_eq!(
        mode("postgresql://db/x?sslmode=require&ssl=false"),
        Some(TlsMode::Require)
    );
}

// A path from the root as an absolute one on this platform: Windows needs a drive.
fn absolute(path: &str) -> String {
    match cfg!(windows) {
        true => format!("C:{path}"),
        false => path.to_owned(),
    }
}

#[test]
fn a_root_certificate_makes_require_verify_and_must_be_absolute() {
    let ca = absolute("/etc/ssl/rds.pem");
    let parsed = read(&format!(
        "postgresql://db.example.com/x?sslmode=require&sslrootcert={ca}"
    ));
    let tls = parsed.tls;
    assert_eq!(tls.mode, Some(TlsMode::VerifyFull));
    assert_eq!(tls.ca_file, Some(PathBuf::from(&ca)));

    assert_eq!(
        refused("postgresql://db.example.com/x?sslrootcert=rds.pem"),
        ConnectionUrlError::RelativePath
    );
    let (certificate, key) = (absolute("/etc/c.pem"), absolute("/etc/c.key"));
    let identity = read(&format!(
        "postgresql://db/x?sslmode=verify-full&sslcert={certificate}&sslkey={key}"
    ))
    .tls
    .client_identity;
    assert_eq!(identity.map(|identity| identity.key), Some(PathBuf::from(&key)));
    let unstated = read(&format!("postgresql://db/x?sslcert={certificate}&sslkey={key}")).tls;
    assert_eq!(unstated.mode, None);
    assert!(unstated.client_identity.is_some(), "the certificate files were dropped");
}

#[test]
fn a_postgres_socket_is_a_folder_given_as_the_host() {
    let parameter = read("postgresql://ada@localhost:5433/shop?host=/var/run/postgresql");
    assert_eq!(parameter.host, "/var/run/postgresql");
    assert_eq!(parameter.port, Some(5433));
    assert_eq!(parameter.username, "ada");

    let encoded = read("postgresql://%2Ftmp:5433/shop");
    assert_eq!((encoded.host.as_str(), encoded.port), ("/tmp", Some(5433)));

    let empty_host = read("postgresql://ada@/shop?host=%2Ftmp&port=5434");
    assert_eq!((empty_host.host.as_str(), empty_host.port), ("/tmp", Some(5434)));

    assert_eq!(read("postgresql:///shop?host=::1").host, "::1");
    assert_eq!(read("postgresql:///shop?host=[::1]&port=6000").port, Some(6000));

    let socket_file = read("postgresql:///shop?host=/run/postgresql/.s.PGSQL.5435");
    assert_eq!(
        (socket_file.host.as_str(), socket_file.port),
        ("/run/postgresql", Some(5435))
    );

    let default_socket = read("postgresql:///shop");
    assert_eq!(default_socket.host, "");
    assert_eq!(default_socket.database, "shop");
}

#[test]
fn a_mysql_socket_is_read_only_for_this_machine() {
    let local = read("mysql://root@localhost/shop?socket=%2Frun%2Fmysqld%2Fmysqld.sock");
    assert_eq!(local.host, "/run/mysqld/mysqld.sock");

    let parenthesised = read("mariadb://root@/shop?socket=(/tmp/mysql.sock)");
    assert_eq!(parenthesised.driver_id, "mysql");
    assert_eq!(parenthesised.host, "/tmp/mysql.sock");

    let remote = read("mysql://root@127.0.0.1/shop?unix_socket=/tmp/mysql.sock");
    assert_eq!(remote.host, "127.0.0.1");

    assert_eq!(read("mysql://root@/shop").host, "");
    assert_eq!(
        refused("mysql://root@localhost/shop?socket=mysql.sock"),
        ConnectionUrlError::RelativePath
    );
}

#[test]
fn mysql_tls_spellings_and_the_x_protocol_port() {
    assert_eq!(mode("mysql://h/db?ssl-mode=DISABLED"), Some(TlsMode::Disable));
    assert_eq!(mode("mysql://h/db?ssl-mode=PREFERRED"), None);
    assert_eq!(mode("mysql://h/db?ssl-mode=VERIFY_IDENTITY"), Some(TlsMode::VerifyFull));
    assert_eq!(
        mode("mysql://h/db?ssl=%7B%22rejectUnauthorized%22%3Atrue%7D"),
        Some(TlsMode::VerifyFull)
    );
    assert_eq!(
        mode(r#"mysql://h/db?ssl={"rejectUnauthorized":false}"#),
        Some(TlsMode::Require)
    );
    assert_eq!(
        mode(r#"mysql://h/db?ssl={"rejectUnauthorized":true,"verifyIdentity":false}"#),
        Some(TlsMode::VerifyFull)
    );
    assert_eq!(mode("mysql://h/db?useSSL=true"), Some(TlsMode::Require));
    assert_eq!(
        mode("mysql://h/db?useSSL=true&verifyServerCertificate=true"),
        Some(TlsMode::VerifyFull)
    );
    assert_eq!(read("mysqlx://u:p@h:33060/db").port, None);
    assert_eq!(read("mysqlx://u:p@h:13040/db").port, Some(13040));
}

#[test]
fn sql_server_reads_urls_and_jdbc_properties() {
    assert_eq!(
        mode("sqlserver://db.example.com/sales?encrypt=strict"),
        Some(TlsMode::Strict)
    );
    assert_eq!(
        mode("sqlserver://db.example.com/sales?encrypt=true"),
        Some(TlsMode::VerifyFull)
    );

    let azure = read(
        "jdbc:sqlserver://srv.database.windows.net:1433;database=demo;user=ada@srv;password={p;ss};encrypt=true;trustServerCertificate=false;hostNameInCertificate=*.database.windows.net;loginTimeout=30;",
    );
    assert_eq!(azure.driver_id, "mssql");
    assert_eq!(azure.host, "srv.database.windows.net");
    assert_eq!(azure.port, Some(1433));
    assert_eq!(azure.database, "demo");
    assert_eq!(azure.username, "ada@srv");
    assert_eq!(password(&azure), Some("p;ss"));
    assert_eq!(azure.tls.mode, Some(TlsMode::VerifyFull));

    let trusting = read("jdbc:sqlserver://db:1433;databaseName=s;encrypt=true;trustServerCertificate=true");
    assert_eq!(trusting.database, "s");
    assert_eq!(trusting.tls.mode, Some(TlsMode::Require));
    assert_eq!(mode("jdbc:sqlserver://db;encrypt=false"), Some(TlsMode::Disable));
    assert_eq!(mode("sqlserver://db/s"), Some(TlsMode::VerifyFull));
    assert_eq!(
        mode("sqlserver://localhost/s?trustServerCertificate=true"),
        Some(TlsMode::Require)
    );
    let semicolon = read("mssql://sa:p;ss@db.example.com/app");
    assert_eq!(
        (semicolon.host.as_str(), password(&semicolon)),
        ("db.example.com", Some("p;ss"))
    );
    let named = read("sqlserver://db.example.com/s?encrypt=true&hostNameInCertificate=sql.internal");
    assert_eq!(named.tls.server_name.as_deref(), Some("sql.internal"));
    assert_eq!(
        refused("jdbc:sqlserver://db\\SQLEXPRESS;database=s"),
        ConnectionUrlError::InstanceName
    );
    assert_eq!(
        refused("jdbc:sqlserver://db;instanceName=SQLEXPRESS"),
        ConnectionUrlError::InstanceName
    );
    let instance = read("jdbc:sqlserver://db\\SQLEXPRESS:1434;database=s");
    assert_eq!((instance.host.as_str(), instance.port), ("db", Some(1434)));

    let literal = read("jdbc:sqlserver://db:1433;user=ada;password=a#b?c%41;encrypt=strict");
    assert_eq!(password(&literal), Some("a#b?c%41"));
    assert_eq!(literal.tls.mode, Some(TlsMode::Strict));
    let quoted = read("jdbc:sqlserver://db:1433;password={a?b;c}}d};encrypt=false");
    assert_eq!(password(&quoted), Some("a?b;c}d"));
    assert_eq!(quoted.tls.mode, Some(TlsMode::Disable));
}

#[test]
fn mongodb_lists_a_replica_set() {
    let parsed = read(
        "mongodb://ada:pw@mongo1.example.com:27017,mongo2.example.com:27018,[::1]/shop?replicaSet=rs0&authSource=admin&tls=true",
    );

    assert_eq!(parsed.driver_id, "mongodb");
    assert_eq!(parsed.host, "mongo1.example.com");
    assert_eq!(parsed.port, Some(27017));
    assert_eq!(parsed.database, "shop");
    assert_eq!(parsed.options.more_hosts, ["mongo2.example.com:27018", "[::1]"]);
    assert_eq!(parsed.options.replica_set.as_deref(), Some("rs0"));
    assert_eq!(parsed.options.auth_database.as_deref(), Some("admin"));
    assert!(!parsed.options.dns_seed_list);
    assert_eq!(parsed.tls.mode, Some(TlsMode::VerifyFull));
}

#[test]
fn mongodb_srv_names_one_host_and_turns_tls_on_unless_told_not_to() {
    assert_eq!(
        refused("mongodb+srv://u:p@cluster0.example.net:27017/"),
        ConnectionUrlError::SeedListHost
    );
    assert_eq!(
        refused("mongodb+srv://u:p@a.example.net,b.example.net/"),
        ConnectionUrlError::SeedListHost
    );
    assert_eq!(
        mode("mongodb+srv://u:p@cluster0.example.net/?tls=false"),
        Some(TlsMode::Disable)
    );
    assert_eq!(
        mode("mongodb://h/db?tls=true&tlsAllowInvalidCertificates=true"),
        Some(TlsMode::Require)
    );
    assert_eq!(
        mode("mongodb://h/db?tls=true&tlsAllowInvalidHostnames=true"),
        Some(TlsMode::VerifyFull),
        "a name check alone off turned the whole certificate check off"
    );
    assert_eq!(
        refused("mongodb://u:p@h/db?authMechanism=MONGODB-X509"),
        ConnectionUrlError::AuthMechanism {
            mechanism: "MONGODB-X509".to_owned()
        }
    );
    assert_eq!(read("mongodb://h/db?authMechanism=SCRAM-SHA-256&user=x").username, "");
    assert_eq!(refused("mongodb://h1,/db"), ConnectionUrlError::NoHost);
    let direct = read("mongodb://ada:pw@nodeA/shop?replicaSet=rs0&directConnection=true");
    assert_eq!(
        direct.options.replica_set, None,
        "a direct connection discovered the set"
    );
    assert_eq!(
        refused("mongodb://nodeA,nodeB/shop?directConnection=true"),
        ConnectionUrlError::DirectConnection
    );
    assert_eq!(
        refused("mongodb://secondary/shop?directConnection=false"),
        ConnectionUrlError::DirectConnection
    );
    assert_eq!(
        read("mongodb://nodeA/shop?directConnection=false&replicaSet=rs0")
            .options
            .replica_set
            .as_deref(),
        Some("rs0")
    );
}

#[test]
fn redis_paths_are_database_numbers() {
    assert_eq!(read("redis://:pw@cache.example.com:6379/2").database, "2");
    assert_eq!(read("redis://cache.example.com/db3").database, "3");
    assert_eq!(read("redis://cache.example.com").database, "");
    assert_eq!(
        refused("redis://cache.example.com/cache"),
        ConnectionUrlError::DatabaseNumber
    );
    assert_eq!(read("redis://[::1]:6380/2").host, "::1");
    assert_eq!(mode("valkeys://default:pw@h:6380"), Some(TlsMode::VerifyFull));
    assert_eq!(mode("rediss://h:6380#insecure"), Some(TlsMode::Require));
    assert_eq!(mode("redis://h:6379"), None);
}

#[test]
fn clickhouse_native_ports_become_the_http_ones() {
    let secure = read("clickhouse://default:pw@abc.eu-west-1.aws.clickhouse.cloud:9440/logs?secure");
    assert_eq!(secure.port, Some(8443));
    assert_eq!(secure.tls.mode, Some(TlsMode::VerifyFull));

    let cloud = read("ch://default@abc.eu-west-1.aws.clickhouse.cloud");
    assert_eq!(cloud.driver_id, "clickhouse");
    assert_eq!(cloud.port, Some(8443));
    assert_eq!(cloud.tls.mode, Some(TlsMode::VerifyFull));

    let flagged = read("clickhouse://default@ch.example.com/logs?secure=true");
    assert_eq!(flagged.port, Some(8443));
    assert_eq!(flagged.tls.mode, Some(TlsMode::VerifyFull));

    let plain = read("clickhouse://localhost:9000/default");
    assert_eq!(plain.port, Some(8123));
    assert_eq!(plain.tls, UrlTls::default());
}

#[test]
fn cassandra_and_scylla_take_a_keyspace() {
    for scheme in ["cassandra", "cql", "scylla", "scylladb"] {
        let parsed = read(&format!("{scheme}://u:p@node1.example.com:9042/orders"));
        assert_eq!(parsed.driver_id, "cassandra");
        assert_eq!(parsed.database, "orders");
    }
    assert_eq!(
        refused("cassandra://n1:9042,n2:9042/ks"),
        ConnectionUrlError::SeveralHosts
    );
}

#[test]
fn a_file_url_keeps_a_windows_drive_and_a_unix_path() {
    assert_eq!(read("sqlite:///C:/data/app.db").database, "C:/data/app.db");
    assert_eq!(read("sqlite:///home/ada/app.db").database, "/home/ada/app.db");
    assert_eq!(read("sqlite:/home/ada/app.db").database, "/home/ada/app.db");
    assert_eq!(read("sqlite://localhost/home/ada/app.db").database, "/home/ada/app.db");
    assert_eq!(read("sqlite://app.db").database, "app.db");
    let duck = read("duckdb:///tmp/a%20b.duckdb?access_mode=read_only");
    assert_eq!(duck.driver_id, "duckdb");
    assert_eq!(duck.database, "/tmp/a b.duckdb");
}

#[test]
fn a_jdbc_prefix_and_login_parameters_are_read() {
    let parsed = read("jdbc:postgresql://db.example.com/app?user=analyst&password=pw");
    assert_eq!(parsed.driver_id, "postgres");
    assert_eq!(parsed.username, "analyst");
    assert_eq!(password(&parsed), Some("pw"));

    let kept = read("postgresql://ada:mine@db.example.com/app?user=analyst&password=pw");
    assert_eq!(kept.username, "ada");
    assert_eq!(password(&kept), Some("mine"));
}

#[test]
fn an_unknown_scheme_a_non_url_and_a_missing_host_are_refused_by_code() {
    assert_eq!(refused("ftp://example.com").code(), "url.unknown_scheme");
    assert_eq!(refused("not a url").code(), "url.invalid");
    assert_eq!(refused("Server=tcp:db,1433;Initial Catalog=x").code(), "url.invalid");
    assert_eq!(refused("mongodb:///db").code(), "url.no_host");
    assert_eq!(refused("postgresql://db:http/x").code(), "url.invalid_port");
    assert_eq!(refused("postgresql://h1,h2/x").code(), "url.several_hosts");
    assert_eq!(refused("postgresql:///x?host=h1,h2").code(), "url.several_hosts");
}
