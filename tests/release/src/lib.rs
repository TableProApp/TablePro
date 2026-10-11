use std::path::PathBuf;
use std::sync::Arc;

use secrecy::SecretString;
use tablepro_core::{ConnectOptions, Connection, DatabaseDriver, Environment, TlsConfig, TlsMode};
use tablepro_policy::{AuditState, DenyApprovalSink, GuardContext, PolicyConfig, PolicyGuard, Principal};
use tablepro_ssh::{SshAuth, SshConfig, SshTunnel};
use tablepro_storage::AuditJournal;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

pub const FIXTURE_ENV: &str = "TABLEPRO_FIXTURE_POSTGRES_RELEASE";

pub fn fixture_enabled() -> bool {
    std::env::var(FIXTURE_ENV).map(|value| value == "1").unwrap_or(false)
}

fn env_or(key: &str, fallback: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| fallback.to_string())
}

fn env_port(key: &str, fallback: u16) -> u16 {
    std::env::var(key)
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(fallback)
}

pub struct Fixture {
    pub proxy_host: String,
    pub proxy_port: u16,
    pub database_hostname: String,
    pub database_port: u16,
    pub database: String,
    pub username: String,
    pub password: String,
    pub ca_cert: PathBuf,
    pub other_ca_cert: PathBuf,
    pub ssh_host: String,
    pub ssh_port: u16,
    pub ssh_username: String,
    pub ssh_key: PathBuf,
    pub toxiproxy: String,
}

impl Fixture {
    /// This crate's test binaries link several TLS stacks, so like the GUI and
    /// the agent daemon they are composition roots and must choose the rustls
    /// provider. See `tablepro_transport::install_crypto_provider`.
    pub fn from_env() -> Self {
        tablepro_transport::install_crypto_provider();
        let materials = std::env::var("TABLEPRO_FIXTURE_MATERIALS")
            .map(PathBuf::from)
            .unwrap_or_else(|_| {
                PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/postgres-release/materials")
            });
        Self {
            proxy_host: env_or("TABLEPRO_FIXTURE_PROXY_HOST", "localhost"),
            proxy_port: env_port("TABLEPRO_FIXTURE_PROXY_PORT", 5433),
            database_hostname: env_or("TABLEPRO_FIXTURE_DB_HOSTNAME", "db.tablepro.test"),
            database_port: env_port("TABLEPRO_FIXTURE_DB_PORT", 5432),
            database: env_or("TABLEPRO_FIXTURE_DB", "tablepro"),
            username: env_or("TABLEPRO_FIXTURE_USER", "tablepro"),
            password: env_or("TABLEPRO_FIXTURE_PASSWORD", "tablepro"),
            ca_cert: materials.join("ca.crt"),
            other_ca_cert: materials.join("other-ca.crt"),
            ssh_host: env_or("TABLEPRO_FIXTURE_SSH_HOST", "127.0.0.1"),
            ssh_port: env_port("TABLEPRO_FIXTURE_SSH_PORT", 2223),
            ssh_username: env_or("TABLEPRO_FIXTURE_SSH_USER", "tunnel"),
            ssh_key: materials.join("client_ed25519_key"),
            toxiproxy: env_or("TABLEPRO_FIXTURE_TOXIPROXY", "127.0.0.1:8474"),
        }
    }

    pub fn direct_options(&self, host: &str, mode: TlsMode, root_cert: Option<PathBuf>) -> ConnectOptions {
        ConnectOptions {
            host: host.to_string(),
            port: self.proxy_port,
            database: self.database.clone(),
            username: self.username.clone(),
            password: SecretString::new(self.password.clone().into()),
            tls: TlsConfig {
                mode,
                root_cert,
                ..Default::default()
            },
            ..Default::default()
        }
    }

    pub fn ssh_config(&self) -> SshConfig {
        SshConfig {
            host: self.ssh_host.clone(),
            port: self.ssh_port,
            username: self.ssh_username.clone(),
            auth: SshAuth::PrivateKey {
                path: self.ssh_key.clone(),
                passphrase: None,
            },
        }
    }

    pub async fn open_tunnel(&self) -> SshTunnel {
        SshTunnel::open(
            self.ssh_config(),
            self.database_hostname.clone(),
            self.database_port,
            tablepro_ssh::UnknownHostKey::Learn,
        )
        .await
        .expect("open ssh tunnel to the fixture database")
    }

    pub async fn open_socket_tunnel(&self, socket_name: &str) -> SshTunnel {
        SshTunnel::open_chain_socket(
            &[self.ssh_config()],
            self.database_hostname.clone(),
            self.database_port,
            socket_name,
            tablepro_ssh::UnknownHostKey::Learn,
        )
        .await
        .expect("open a socket-forwarded ssh tunnel to the fixture database")
    }

    pub fn socket_options(
        &self,
        tunnel: &SshTunnel,
        identity_host: &str,
        mode: TlsMode,
        root_cert: Option<PathBuf>,
    ) -> ConnectOptions {
        ConnectOptions {
            host: identity_host.to_string(),
            port: self.database_port,
            database: self.database.clone(),
            username: self.username.clone(),
            password: SecretString::new(self.password.clone().into()),
            tls: TlsConfig {
                mode,
                root_cert,
                ..Default::default()
            },
            service_endpoint: Some((identity_host.to_string(), self.database_port)),
            forwarded_socket_dir: tunnel.socket_dir().map(|dir| dir.to_path_buf()),
            ..Default::default()
        }
    }

    pub fn tunneled_options(&self, tunnel: &SshTunnel, mode: TlsMode, root_cert: Option<PathBuf>) -> ConnectOptions {
        ConnectOptions {
            host: tunnel.local_host().to_string(),
            port: tunnel.local_port(),
            database: self.database.clone(),
            username: self.username.clone(),
            password: SecretString::new(self.password.clone().into()),
            tls: TlsConfig {
                mode,
                root_cert,
                ..Default::default()
            },
            service_endpoint: Some((self.database_hostname.clone(), self.database_port)),
            ..Default::default()
        }
    }

    pub async fn connect_verified(&self) -> Box<dyn Connection> {
        drivers_postgres::PgDriver
            .connect(self.direct_options(&self.proxy_host, TlsMode::VerifyFull, Some(self.ca_cert.clone())))
            .await
            .expect("verified connection to the fixture database")
    }

    pub fn toxiproxy(&self) -> Toxiproxy {
        Toxiproxy {
            address: self.toxiproxy.clone(),
        }
    }
}

pub struct Toxiproxy {
    address: String,
}

impl Toxiproxy {
    pub async fn set_enabled(&self, proxy: &str, enabled: bool) {
        let body = format!("{{\"enabled\":{enabled}}}");
        let request = format!(
            "POST /proxies/{proxy} HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/json\r\n\
             Content-Length: {length}\r\nConnection: close\r\n\r\n{body}",
            host = self.address,
            length = body.len(),
        );
        let mut stream = TcpStream::connect(&self.address).await.expect("connect to toxiproxy");
        stream
            .write_all(request.as_bytes())
            .await
            .expect("send toxiproxy request");
        let mut response = String::new();
        stream
            .read_to_string(&mut response)
            .await
            .expect("read toxiproxy response");
        assert!(
            response.starts_with("HTTP/1.1 200"),
            "toxiproxy rejected the {proxy} update: {response}"
        );
    }
}

pub struct GuardHarness {
    pub guard: PolicyGuard,
    _journal: tempfile::TempDir,
}

pub fn guard(connection: Arc<dyn Connection>, read_only: bool) -> GuardHarness {
    let journal_dir = tempfile::TempDir::new().expect("temporary audit journal directory");
    let journal =
        AuditJournal::open_validated(journal_dir.path().join("audit.jsonl")).expect("open fixture audit journal");
    let context = GuardContext {
        connection_id: uuid::Uuid::new_v4(),
        connection_name: "postgres-release-fixture".into(),
        driver_id: "postgres".into(),
        environment: Environment::Local,
        read_only,
        principal: Principal::Human {
            session: "release-fixture".into(),
        },
        policy: Arc::new(PolicyConfig::default()),
        approval: Arc::new(DenyApprovalSink),
        audit: Arc::new(journal),
        audit_state: Arc::new(AuditState::new()),
    };
    GuardHarness {
        guard: PolicyGuard::new(connection, context),
        _journal: journal_dir,
    }
}
