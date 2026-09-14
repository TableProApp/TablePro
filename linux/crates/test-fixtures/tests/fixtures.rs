use std::error::Error;
use std::path::Path;
use std::sync::Arc;

use rustls::RootCertStore;
use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, ServerName};
use tablepro_test_fixtures::{
    ClickHouseFixture, ExecOutput, FixtureCredentials, HbaMode, HostKeyRevocation, MssqlFixture, MysqlFixture,
    MysqlFlavour, OpenSshFixture, PgBouncerFixture, PkiFile, PoolMode, PostgresFixture, ScriptedAskpass,
    SshAuthVariant, SshKeyPair, TestPki,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
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
#[ignore = "requires docker"]
async fn generated_pki_matches_the_files_the_fixtures_copy() -> TestResult {
    let pki = TestPki::generate()?;

    for file in PkiFile::ALL {
        assert!(!pki.read(file)?.is_empty(), "{}", file.file_name());
    }
    Ok(())
}
