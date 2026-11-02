use std::error::Error;
use std::path::Path;
use std::sync::Arc;

use rustls::RootCertStore;
use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, ServerName};
use std::process::Stdio;

use tablepro_test_fixtures::{
    CassandraFixture, CassandraFlavour, CassandraTls, ClickHouseFixture, ExecOutput, FixtureCredentials, HbaMode,
    HostKeyRevocation, MssqlFixture, MysqlFixture, MysqlFlavour, MysqlOptions, OpenSshFixture, OpenSshOptions,
    OpenSshVersion, PgBouncerFixture, PkiFile, PoolMode, PostgresFixture, PostgresVersion, ScriptedAskpass,
    ServerVersion, SshAgent, SshAuthVariant, SshKeyPair, TestNetwork, TestPki,
};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio_rustls::TlsConnector;

type TestResult = Result<(), Box<dyn Error>>;

const PG_SSL_REQUEST: [u8; 8] = [0, 0, 0, 8, 0x04, 0xd2, 0x16, 0x2f];
const VERIFIED_NAME: &str = "localhost";

fn connector(ca: &Path) -> Result<TlsConnector, Box<dyn Error>> {
    let mut roots = RootCertStore::empty();
    for certificate in CertificateDer::pem_file_iter(ca)? {
        roots.add(certificate?)?;
    }
    let config = rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::aws_lc_rs::default_provider()))
        .with_safe_default_protocol_versions()?
        .with_root_certificates(roots)
        .with_no_client_auth();
    Ok(TlsConnector::from(Arc::new(config)))
}

async fn served_leaf(
    pki: &TestPki,
    host: &str,
    port: u16,
    sslrequest: bool,
) -> Result<CertificateDer<'static>, Box<dyn Error>> {
    let mut stream = TcpStream::connect((host, port)).await?;
    if sslrequest {
        stream.write_all(&PG_SSL_REQUEST).await?;
        let mut reply = [0_u8; 1];
        stream.read_exact(&mut reply).await?;
        if reply != *b"S" {
            return Err(format!("server refused TLS with {:?}", reply[0] as char).into());
        }
    }
    let name = ServerName::try_from(VERIFIED_NAME)?.to_owned();
    let tls = connector(&pki.path(PkiFile::Ca))?.connect(name, stream).await?;
    let (_, connection) = tls.get_ref();
    let leaf = connection
        .peer_certificates()
        .and_then(<[CertificateDer<'_>]>::first)
        .ok_or("no peer certificates")?;
    Ok(leaf.clone().into_owned())
}

fn server_certificate(pki: &TestPki) -> Result<CertificateDer<'static>, Box<dyn Error>> {
    Ok(CertificateDer::from_pem_file(pki.path(PkiFile::ServerCertificate))?)
}

fn psql_url(credentials: &FixtureCredentials, database: &str, ssl_mode: &str) -> String {
    format!(
        "host={VERIFIED_NAME} user={} dbname={database} sslmode={ssl_mode} sslrootcert={}/ca.pem",
        credentials.username,
        PostgresFixture::TLS_DIR,
    )
}

async fn psql(
    fixture: &PostgresFixture,
    credentials: &FixtureCredentials,
    ssl_mode: &str,
) -> Result<ExecOutput, Box<dyn Error>> {
    let url = psql_url(credentials, fixture.database(), ssl_mode);
    let script = format!(
        "PGPASSWORD='{}' psql '{url}' -tAc 'SELECT 1'",
        credentials.password.replace('\'', "'\\''")
    );
    Ok(fixture.exec(&["sh", "-c", &script]).await?)
}

#[derive(Clone, Copy)]
enum ClientTls {
    Disabled,
    Required,
    VerifyCa,
}

fn tls_arguments(flavour: MysqlFlavour, tls: ClientTls) -> &'static str {
    match (flavour, tls) {
        (MysqlFlavour::Mysql, ClientTls::Disabled) => "--ssl-mode=DISABLED",
        (MysqlFlavour::Mysql, ClientTls::Required) => "--ssl-mode=REQUIRED",
        (MysqlFlavour::Mysql, ClientTls::VerifyCa) => "--ssl-mode=VERIFY_CA",
        (MysqlFlavour::Mariadb, ClientTls::Disabled) => "--skip-ssl",
        (MysqlFlavour::Mariadb, ClientTls::Required) => "--ssl",
        (MysqlFlavour::Mariadb, ClientTls::VerifyCa) => "--ssl --ssl-verify-server-cert",
    }
}

async fn mysql_client(
    fixture: &MysqlFixture,
    credentials: &FixtureCredentials,
    tls_mode: ClientTls,
    client_certificate: bool,
) -> Result<ExecOutput, Box<dyn Error>> {
    let tls = MysqlFixture::TLS_DIR;
    let identity = if client_certificate {
        format!(" --ssl-cert={tls}/client.pem --ssl-key={tls}/client.key")
    } else {
        String::new()
    };
    let script = format!(
        "{} --protocol=TCP -h {VERIFIED_NAME} -u '{}' -p'{}' {} --ssl-ca={tls}/ca.pem{identity} -N -e 'SELECT 1'",
        fixture.flavour().client_program(),
        credentials.username,
        credentials.password,
        tls_arguments(fixture.flavour(), tls_mode),
    );
    Ok(fixture.exec(&["sh", "-c", &script]).await?)
}

async fn ssh_exit_code(arguments: &[&str]) -> Result<Option<i32>, Box<dyn Error>> {
    let status = tokio::process::Command::new("ssh").args(arguments).status().await?;
    Ok(status.code())
}

async fn ssh_password_login(
    fixture: &OpenSshFixture,
    askpass: &ScriptedAskpass,
    options: &[String],
) -> Result<Option<i32>, Box<dyn Error>> {
    let credentials = fixture.password_credentials();
    let mut command = tokio::process::Command::new("ssh");
    command.args(["-p", &fixture.port().to_string()]);
    for option in options {
        command.arg("-o").arg(option);
    }
    let status = command
        .args(["-o", "NumberOfPasswordPrompts=1"])
        .arg(format!("{}@{}", credentials.username, fixture.host()))
        .arg("true")
        .env("SSH_ASKPASS", askpass.path())
        .env("SSH_ASKPASS_REQUIRE", "force")
        .env(ScriptedAskpass::ANSWER_VARIABLE, &credentials.password)
        .status()
        .await?;
    Ok(status.code())
}

async fn mssql_connects(fixture: &MssqlFixture, ca: PkiFile) -> Result<bool, Box<dyn Error>> {
    use tokio_util::compat::TokioAsyncWriteCompatExt;

    let credentials = fixture.password_credentials();
    let mut config = tiberius::Config::new();
    config.host(VERIFIED_NAME);
    config.port(fixture.port());
    config.authentication(tiberius::AuthMethod::sql_server(
        &credentials.username,
        &credentials.password,
    ));
    config.trust_cert_ca(fixture.pki().path(ca).display().to_string());
    let stream = TcpStream::connect((fixture.host(), fixture.port())).await?;
    stream.set_nodelay(true)?;
    Ok(tiberius::Client::connect(config, stream.compat_write()).await.is_ok())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn postgres_tls_fixture_completes_a_verified_handshake_after_sslrequest() -> TestResult {
    let fixture = PostgresFixture::start(HbaMode::HostSslOnly).await?;

    let leaf = served_leaf(fixture.pki(), fixture.host(), fixture.port(), true).await?;

    assert_eq!(leaf, server_certificate(fixture.pki())?);
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn postgres_password_role_needs_tls() -> TestResult {
    let fixture = PostgresFixture::start(HbaMode::HostSslOnly).await?;
    let credentials = fixture.password_credentials();

    let required = psql(&fixture, &credentials, "require").await?;
    let disabled = psql(&fixture, &credentials, "disable").await?;

    assert!(required.succeeded(), "{}", required.stderr_text());
    assert_eq!(required.stdout_text().trim(), "1");
    assert!(!disabled.succeeded());
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn postgres_certificate_role_needs_the_client_certificate() -> TestResult {
    let fixture = PostgresFixture::start(HbaMode::ClientCertificate).await?;
    let credentials = fixture.certificate_credentials().ok_or("no certificate principal")?;
    let tls = PostgresFixture::TLS_DIR;
    let url = psql_url(&credentials, fixture.database(), "verify-ca");

    let install = format!("install -m 0600 {tls}/client.key /tmp/client.key");
    let with_identity = fixture
        .exec(&[
            "sh",
            "-c",
            &format!("{install} && psql '{url} sslcert={tls}/client.pem sslkey=/tmp/client.key' -tAc 'SELECT 1'"),
        ])
        .await?;
    let without_identity = fixture
        .exec(&["sh", "-c", &format!("psql '{url}' -tAc 'SELECT 1'")])
        .await?;

    assert!(with_identity.succeeded(), "{}", with_identity.stderr_text());
    assert_eq!(with_identity.stdout_text().trim(), "1");
    assert!(!without_identity.succeeded());
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_password_user_needs_tls() -> TestResult {
    let fixture = MysqlFixture::start(MysqlFlavour::Mysql).await?;
    let credentials = fixture.password_credentials();

    let required = mysql_client(&fixture, &credentials, ClientTls::Required, false).await?;
    let disabled = mysql_client(&fixture, &credentials, ClientTls::Disabled, false).await?;

    assert!(required.succeeded(), "{}", required.stderr_text());
    assert_eq!(required.stdout_text().trim(), "1");
    assert!(!disabled.succeeded());
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_x509_user_needs_the_client_certificate() -> TestResult {
    let fixture = MysqlFixture::start(MysqlFlavour::Mysql).await?;
    let credentials = fixture.certificate_credentials();

    let with_identity = mysql_client(&fixture, &credentials, ClientTls::VerifyCa, true).await?;
    let without_identity = mysql_client(&fixture, &credentials, ClientTls::VerifyCa, false).await?;

    assert!(with_identity.succeeded(), "{}", with_identity.stderr_text());
    assert_eq!(with_identity.stdout_text().trim(), "1");
    assert!(!without_identity.succeeded());
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mariadb_x509_user_needs_the_client_certificate() -> TestResult {
    let fixture = MysqlFixture::start(MysqlFlavour::Mariadb).await?;
    let credentials = fixture.certificate_credentials();

    let with_identity = mysql_client(&fixture, &credentials, ClientTls::VerifyCa, true).await?;
    let without_identity = mysql_client(&fixture, &credentials, ClientTls::VerifyCa, false).await?;

    assert!(with_identity.succeeded(), "{}", with_identity.stderr_text());
    assert_eq!(with_identity.stdout_text().trim(), "1");
    assert!(!without_identity.succeeded());
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mssql_tls_fixture_serves_the_generated_certificate() -> TestResult {
    let fixture = MssqlFixture::start().await?;

    let trusted = mssql_connects(&fixture, PkiFile::Ca).await?;
    let unrelated = mssql_connects(&fixture, PkiFile::UnrelatedCa).await?;

    assert!(trusted);
    assert!(!unrelated);
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn clickhouse_https_fixture_serves_the_generated_certificate() -> TestResult {
    let fixture = ClickHouseFixture::start().await?;

    let leaf = served_leaf(fixture.pki(), fixture.host(), fixture.https_port(), false).await?;

    assert_eq!(leaf, server_certificate(fixture.pki())?);
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn clickhouse_fixture_starts_the_server_once_with_the_database() -> TestResult {
    let fixture = ClickHouseFixture::start().await?;
    let log = "/var/log/clickhouse-server/clickhouse-server.log";
    let query = "SELECT name FROM system.databases WHERE name = 'tablepro'";

    let starts = fixture.exec(&["grep", "-c", "Starting ClickHouse", log]).await?;
    let databases = fixture.exec(&["clickhouse-client", "--query", query]).await?;

    assert_eq!(starts.stdout_text().trim(), "1", "{}", starts.stderr_text());
    assert_eq!(
        databases.stdout_text().trim(),
        "tablepro",
        "{}",
        databases.stderr_text()
    );
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn cassandra_fixture_runs_the_requested_release_with_its_roles_and_keyspace() -> TestResult {
    for flavour in CassandraFlavour::ALL {
        let fixture = CassandraFixture::start(flavour).await?;
        let version = match flavour {
            CassandraFlavour::Cassandra => "SELECT release_version FROM system.local",
            CassandraFlavour::Scylla => "SELECT version FROM system.versions WHERE key = 'local'",
        };

        let reported = fixture.cql(version).await?.stdout_text();
        let roles = fixture.cql("LIST ROLES").await?.stdout_text();
        let keyspace = fixture
            .cql("SELECT keyspace_name FROM system_schema.keyspaces WHERE keyspace_name = 'tablepro'")
            .await?
            .stdout_text();

        let (major, minor) = fixture.server_version();
        assert!(
            reported.contains(&format!(" {major}.{minor}.")),
            "{flavour:?}: {reported}"
        );
        for role in ["tablepro", "tablepro_limited", TestPki::CLIENT_COMMON_NAME] {
            assert!(roles.contains(role), "{flavour:?}: {roles}");
        }
        assert!(keyspace.contains("tablepro"), "{flavour:?}: {keyspace}");
        assert!(fixture.cql("SELECT nothing FROM nowhere").await.is_err());
    }
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn cassandra_tls_fixture_serves_the_generated_certificate() -> TestResult {
    for flavour in CassandraFlavour::ALL {
        let fixture = CassandraFixture::start_with(flavour, CassandraTls::Required, None).await?;

        let leaf = served_leaf(fixture.pki(), fixture.host(), fixture.port(), false).await?;

        assert_eq!(leaf, server_certificate(fixture.pki())?, "{flavour:?}");
    }
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn pgbouncer_fixture_runs_select_1_through_the_upstream() -> TestResult {
    let fixture = PgBouncerFixture::start(PoolMode::Transaction).await?;
    let upstream = fixture.upstream();
    let credentials = upstream.password_credentials();
    let script = format!(
        "PGPASSWORD='{}' psql 'host={} port=5432 user={} dbname={} sslmode=disable' -tAc 'SELECT 1'",
        credentials.password,
        fixture.network_alias(),
        credentials.username,
        upstream.database(),
    );

    let output = upstream.exec(&["sh", "-c", &script]).await?;

    assert!(output.succeeded(), "{}", output.stderr_text());
    assert_eq!(output.stdout_text().trim(), "1");
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn openssh_fixture_enables_tcp_forwarding() -> TestResult {
    let key = SshKeyPair::generate("tablepro-test").await?;
    let fixture = OpenSshFixture::start(SshAuthVariant::PublicKey(key)).await?;

    let output = fixture
        .exec(&["sshd.pam", "-T", "-f", OpenSshFixture::SSHD_CONFIG])
        .await?;

    assert!(output.succeeded(), "{}", output.stderr_text());
    assert!(output.stdout_text().contains("allowtcpforwarding yes"));
    Ok(())
}

async fn first_line(host: &str, port: u16) -> Result<String, Box<dyn Error>> {
    let mut reader = BufReader::new(TcpStream::connect((host, port)).await?);
    let mut line = String::new();
    reader.read_line(&mut line).await?;
    Ok(line.trim_end().to_owned())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn openssh_fixture_runs_the_requested_release() -> TestResult {
    for &version in OpenSshVersion::ALL {
        let options = OpenSshOptions::default().with_version(version);
        let fixture = OpenSshFixture::start_with(SshAuthVariant::Password, options, None).await?;

        let banner = first_line(fixture.host(), fixture.port()).await?;

        assert!(
            banner.starts_with(&version.banner_prefix()),
            "{version:?} sent {banner}"
        );
        assert_eq!(fixture.version(), version);
    }
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn openssh_options_reach_sshd() -> TestResult {
    let options = OpenSshOptions::selected()?
        .with_kex_algorithms(OpenSshOptions::POST_QUANTUM_KEX)
        .with_max_auth_tries(3)
        .with_pubkey_accepted_algorithms("rsa-sha2-256");
    let fixture = OpenSshFixture::start_with(SshAuthVariant::Password, options, None).await?;

    let output = fixture
        .exec(&["sshd.pam", "-T", "-f", OpenSshFixture::SSHD_CONFIG])
        .await?;

    assert!(output.succeeded(), "{}", output.stderr_text());
    let effective = output.stdout_text();
    for expected in [
        "kexalgorithms mlkem768x25519-sha256,sntrup761x25519-sha512",
        "maxauthtries 3",
        "pubkeyacceptedalgorithms rsa-sha2-256",
        "persourcepenalties no",
    ] {
        assert!(
            effective.lines().any(|line| line == expected),
            "no {expected} in\n{effective}"
        );
    }
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn max_auth_tries_fixture_disconnects_an_agent_with_too_many_keys() -> TestResult {
    let agent = SshAgent::start().await?;
    let mut offered = Vec::new();
    for index in 1..=4 {
        let decoy = SshKeyPair::generate(&format!("tablepro-decoy-{index}")).await?;
        agent.add(&decoy).await?;
        offered.push(decoy.public_key().to_owned());
    }
    let key = SshKeyPair::generate("tablepro-authorized").await?;
    agent.add(&key).await?;
    offered.push(key.public_key().to_owned());
    assert_eq!(
        agent.identities().await?,
        offered,
        "the agent lists its keys out of order"
    );
    let options = OpenSshOptions::selected()?.with_max_auth_tries(3);
    let fixture = OpenSshFixture::start_with(SshAuthVariant::PublicKey(key), options, None).await?;

    let output = tokio::process::Command::new("ssh")
        .args(["-F", "none", "-p", &fixture.port().to_string(), "-o"])
        .arg(format!("IdentityAgent={}", agent.socket().display()))
        .args([
            "-o",
            "IdentitiesOnly=no",
            "-o",
            "PreferredAuthentications=publickey",
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
        ])
        .arg(format!(
            "{}@{}",
            fixture.password_credentials().username,
            fixture.host()
        ))
        .arg("true")
        .stdin(Stdio::null())
        .output()
        .await?;

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(output.status.code(), Some(255), "{stderr}");
    assert!(stderr.contains("Too many authentication failures"), "{stderr}");
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn keyboard_interactive_fixture_accepts_only_keyboard_interactive() -> TestResult {
    let fixture = OpenSshFixture::start(SshAuthVariant::KeyboardInteractive).await?;
    let askpass = ScriptedAskpass::new()?;
    let options = |methods: &str| {
        [
            "StrictHostKeyChecking=no".to_owned(),
            "UserKnownHostsFile=/dev/null".to_owned(),
            format!("PreferredAuthentications={methods}"),
        ]
    };

    let keyboard_interactive = ssh_password_login(&fixture, &askpass, &options("keyboard-interactive")).await?;
    let password = ssh_password_login(&fixture, &askpass, &options("password")).await?;

    assert_eq!(keyboard_interactive, Some(0));
    assert_eq!(password, Some(255));
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn host_certificate_fixture_is_trusted_through_cert_authority() -> TestResult {
    let certificate = OpenSshFixture::start(SshAuthVariant::HostCertificate).await?;
    let known_hosts = tempfile::tempdir()?;
    let known_hosts_file = known_hosts.path().join("known_hosts");
    let certificate_authority = certificate.host_certificate().ok_or("no host certificate")?;
    std::fs::write(
        &known_hosts_file,
        certificate_authority.known_hosts_line(certificate.host(), certificate.port()),
    )?;
    let askpass = ScriptedAskpass::new()?;
    let options = [
        "StrictHostKeyChecking=yes".to_owned(),
        format!("UserKnownHostsFile={}", known_hosts_file.display()),
        "PreferredAuthentications=password".to_owned(),
    ];

    let accepted = ssh_password_login(&certificate, &askpass, &options).await?;

    assert_eq!(accepted, Some(0));
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn revoked_host_key_is_refused_by_ssh() -> TestResult {
    let fixture = OpenSshFixture::start(SshAuthVariant::Password).await?;
    let dir = tempfile::tempdir()?;
    let revocation = HostKeyRevocation::revoke_host_key(&fixture, dir.path()).await?;

    let query = tokio::process::Command::new("ssh-keygen")
        .args([
            "-Q".as_ref(),
            "-f".as_ref(),
            revocation.krl().as_os_str(),
            revocation.host_public_key().as_os_str(),
        ] as [&std::ffi::OsStr; 4])
        .output()
        .await?;
    let port = fixture.port().to_string();
    let destination = format!("{}@{}", fixture.password_credentials().username, fixture.host());
    let refused = ssh_exit_code(&[
        "-p",
        &port,
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "BatchMode=yes",
        "-o",
        &format!("RevokedHostKeys={}", revocation.krl().display()),
        &destination,
        "true",
    ])
    .await?;

    assert!(String::from_utf8_lossy(&query.stdout).contains("REVOKED"));
    assert_eq!(refused, Some(255));
    Ok(())
}

#[tokio::test]
async fn generated_pki_matches_the_files_the_fixtures_copy() -> TestResult {
    let pki = TestPki::generate()?;

    for file in PkiFile::ALL {
        assert!(!pki.read(file)?.is_empty(), "{}", file.file_name());
    }
    Ok(())
}

/// Open a direct-tcpip channel through the server to `target` with
/// `ssh -W`, write `request` into it and return what comes back.
async fn through_ssh(
    fixture: &OpenSshFixture,
    key: &SshKeyPair,
    target: &str,
    request: &[u8],
) -> Result<Vec<u8>, Box<dyn Error>> {
    let credentials = fixture.password_credentials();
    let mut child = tokio::process::Command::new("ssh")
        .args(["-p", &fixture.port().to_string(), "-i"])
        .arg(key.private_key())
        .args([
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-W",
            target,
        ])
        .arg(format!("{}@{}", credentials.username, fixture.host()))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let mut stdin = child.stdin.take().ok_or("no stdin")?;
    stdin.write_all(request).await?;
    let mut stdout = child.stdout.take().ok_or("no stdout")?;
    let mut reply = vec![0_u8; 64];
    let read = tokio::time::timeout(std::time::Duration::from_secs(30), stdout.read(&mut reply)).await??;
    reply.truncate(read);
    drop(stdin);
    child.kill().await?;
    Ok(reply)
}

#[tokio::test]
#[ignore = "requires docker"]
async fn postgres_fixture_runs_the_requested_major() -> TestResult {
    for &version in PostgresVersion::ALL {
        let fixture = PostgresFixture::start_version(version, HbaMode::Password).await?;
        let output = fixture
            .exec(&[
                "psql",
                "-U",
                "tablepro",
                "-d",
                "tablepro",
                "-tAc",
                "SHOW server_version_num",
            ])
            .await?;

        assert!(output.succeeded(), "{}", output.stderr_text());
        assert!(
            output.stdout_text().trim().starts_with(&version.major().to_string()),
            "{version:?} reported {}",
            output.stdout_text()
        );
        assert_eq!(fixture.version(), version);
    }
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn postgres_restartable_fixture_comes_back_on_its_port_with_its_data() -> TestResult {
    let fixture = PostgresFixture::start_restartable(HbaMode::Password).await?;
    let port = fixture.port();
    let psql = |sql: &'static str| ["psql", "-U", "tablepro", "-d", "tablepro", "-tAc", sql];
    let created = fixture
        .exec(&psql("CREATE TABLE kept (n integer); INSERT INTO kept VALUES (7)"))
        .await?;
    assert!(created.succeeded(), "{}", created.stderr_text());

    fixture.stop().await?;
    assert!(!fixture.container().is_running().await?);
    fixture.start_again().await?;

    let read = fixture.exec(&psql("SELECT n FROM kept")).await?;
    assert_eq!(read.stdout_text().trim(), "7", "{}", read.stderr_text());
    assert_eq!(fixture.container().get_host_port_ipv4(5432).await?, port);
    TcpStream::connect((fixture.host(), port)).await?;
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn openssh_fixture_on_a_network_forwards_to_postgres_by_alias() -> TestResult {
    let network = TestNetwork::new();
    let database = PostgresFixture::start_in(HbaMode::Password, &network).await?;
    let key = SshKeyPair::generate("tablepro-network-test").await?;
    let fixture = OpenSshFixture::start_in(SshAuthVariant::PublicKey(key), &network).await?;
    let SshAuthVariant::PublicKey(key) = fixture.variant() else {
        return Err("the fixture lost its key".into());
    };
    let alias = database.network_alias().ok_or("no alias")?;

    let reply = through_ssh(&fixture, key, &format!("{alias}:5432"), &PG_SSL_REQUEST).await?;

    assert_eq!(reply, b"N", "the image's default server answers SSLRequest with N");
    assert!(
        fixture
            .network_alias()
            .is_some_and(|own| own.starts_with(network.name()))
    );
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn clickhouse_fixture_on_a_network_answers_by_alias() -> TestResult {
    let network = TestNetwork::new();
    let clickhouse = ClickHouseFixture::start_in(&network).await?;
    let key = SshKeyPair::generate("tablepro-network-test").await?;
    let fixture = OpenSshFixture::start_in(SshAuthVariant::PublicKey(key), &network).await?;
    let SshAuthVariant::PublicKey(key) = fixture.variant() else {
        return Err("the fixture lost its key".into());
    };
    let alias = clickhouse.network_alias().ok_or("no alias")?;
    let target = format!("{alias}:{}", ClickHouseFixture::HTTP_PORT);

    let reply = through_ssh(&fixture, key, &target, b"GET /ping HTTP/1.0\r\n\r\n").await?;

    assert!(String::from_utf8_lossy(&reply).starts_with("HTTP/1.0 200"), "{reply:?}");
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn mysql_options_set_root_plaintext_and_server_globals() -> TestResult {
    let options = MysqlOptions::new(MysqlFlavour::Mysql)
        .allowing_plaintext()
        .with_server_argument("--sql-mode=NO_BACKSLASH_ESCAPES");
    let fixture = MysqlFixture::start_with(options, None).await?;
    let script = |credentials: FixtureCredentials, sql: &str| {
        format!(
            "mysql --protocol=TCP -h 127.0.0.1 -u '{}' -p'{}' --ssl-mode=DISABLED --get-server-public-key -N -e '{sql}'",
            credentials.username, credentials.password,
        )
    };

    let global = script(fixture.root_credentials(), "SELECT @@GLOBAL.sql_mode");
    let global = fixture.exec(&["sh", "-c", &global]).await?;
    let plaintext = script(fixture.password_credentials(), "SELECT 1");
    let plaintext = fixture.exec(&["sh", "-c", &plaintext]).await?;

    assert!(global.succeeded(), "{}", global.stderr_text());
    assert_eq!(global.stdout_text().trim(), "NO_BACKSLASH_ESCAPES");
    assert!(plaintext.succeeded(), "{}", plaintext.stderr_text());
    Ok(())
}
