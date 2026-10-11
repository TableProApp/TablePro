//! Fixture harness for the driver TLS tier. Each network driver is connected
//! to a real server holding a privately issued certificate, so its mapping of
//! the shared TLS modes is proven rather than read.

use std::path::PathBuf;

use secrecy::SecretString;
use tablepro_core::{ConnectOptions, DriverError, TlsConfig, TlsMode};
use tablepro_ssh::{SshAuth, SshConfig, SshTunnel, UnknownHostKey};

/// A negative identity test must fail for certificate verification, not because
/// the fixture is down or credentials are wrong. Exercise a verified control first.
pub async fn assert_endpoint_identity_rejected(driver: &dyn tablepro_core::DatabaseDriver, options: ConnectOptions) {
    let mut rejected = options.clone();
    rejected.host = "127.0.0.1".into();
    assert_certificate_rejected(driver, options, rejected).await;
}

pub async fn assert_certificate_rejected(
    driver: &dyn tablepro_core::DatabaseDriver,
    accepted: ConnectOptions,
    rejected: ConnectOptions,
) {
    let connection = driver.connect(accepted).await.expect("verified control connection");
    connection.ping().await.expect("control ping");
    connection.close().await.expect("close control");
    let error = match driver.connect(rejected).await {
        Ok(_) => panic!("invalid certificate configuration was accepted"),
        Err(error) => error,
    };
    let detail = error.to_string().to_ascii_lowercase();
    assert!(
        matches!(&error, DriverError::Tls(_))
            || detail.contains("invalid peer certificate")
            || detail.contains("certificate verify failed"),
        "expected TLS verification rejection: {error}"
    );
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

pub struct DriverTlsFixture {
    pub host: String,
    pub mongo_port: u16,
    pub mongo_plaintext_port: u16,
    pub redis_port: u16,
    pub redis_plaintext_port: u16,
    pub mysql_port: u16,
    pub mysql_plaintext_port: u16,
    pub mysql_mtls_port: u16,
    pub postgres_port: u16,
    pub clickhouse_port: u16,
    pub clickhouse_plaintext_port: u16,
    pub mssql_port: u16,
    pub mssql_plaintext_port: u16,
    pub ssh_host: String,
    pub ssh_port: u16,
    pub ssh_key: PathBuf,
    pub database: String,
    pub username: String,
    pub password: String,
    pub ca_cert: PathBuf,
    pub other_ca_cert: PathBuf,
    pub client_cert: PathBuf,
    pub client_key: PathBuf,
    pub rotated_client_cert: PathBuf,
    pub rotated_client_key: PathBuf,
    pub wrong_client_cert: PathBuf,
    pub wrong_client_key: PathBuf,
}

impl DriverTlsFixture {
    /// Every test binary here links several drivers, so it is a composition
    /// root and has to choose the rustls provider exactly as the application
    /// does. See `tablepro_transport::install_crypto_provider`.
    pub fn from_env() -> Self {
        tablepro_transport::install_crypto_provider();
        let materials = std::env::var("TABLEPRO_DRIVER_TLS_MATERIALS")
            .map(PathBuf::from)
            .unwrap_or_else(|_| {
                PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/driver-tls/materials")
            });
        Self {
            host: env_or("TABLEPRO_DRIVER_TLS_HOST", "localhost"),
            mongo_port: env_port("TABLEPRO_DRIVER_TLS_MONGO_PORT", 27018),
            mongo_plaintext_port: env_port("TABLEPRO_DRIVER_TLS_MONGO_PLAINTEXT_PORT", 27019),
            redis_port: env_port("TABLEPRO_DRIVER_TLS_REDIS_PORT", 6380),
            redis_plaintext_port: env_port("TABLEPRO_DRIVER_TLS_REDIS_PLAINTEXT_PORT", 6381),
            mysql_port: env_port("TABLEPRO_DRIVER_TLS_MYSQL_PORT", 3307),
            mysql_plaintext_port: env_port("TABLEPRO_DRIVER_TLS_MYSQL_PLAINTEXT_PORT", 3308),
            mysql_mtls_port: env_port("TABLEPRO_DRIVER_TLS_MYSQL_MTLS_PORT", 3309),
            postgres_port: env_port("TABLEPRO_DRIVER_TLS_POSTGRES_PORT", 5436),
            clickhouse_port: env_port("TABLEPRO_DRIVER_TLS_CLICKHOUSE_PORT", 8444),
            clickhouse_plaintext_port: env_port("TABLEPRO_DRIVER_TLS_CLICKHOUSE_PLAINTEXT_PORT", 8445),
            mssql_port: env_port("TABLEPRO_DRIVER_TLS_MSSQL_PORT", 1434),
            mssql_plaintext_port: env_port("TABLEPRO_DRIVER_TLS_MSSQL_PLAINTEXT_PORT", 1435),
            ssh_host: env_or("TABLEPRO_DRIVER_TLS_SSH_HOST", "127.0.0.1"),
            ssh_port: env_port("TABLEPRO_DRIVER_TLS_SSH_PORT", 2224),
            ssh_key: materials.join("ssh_client"),
            database: env_or("TABLEPRO_DRIVER_TLS_DB", "tablepro"),
            username: env_or("TABLEPRO_DRIVER_TLS_USER", "tablepro"),
            password: env_or("TABLEPRO_DRIVER_TLS_PASSWORD", "tablepro"),
            ca_cert: materials.join("ca.crt"),
            other_ca_cert: materials.join("other-ca.crt"),
            client_cert: materials.join("client.crt"),
            client_key: materials.join("client.key"),
            rotated_client_cert: materials.join("rotated-client.crt"),
            rotated_client_key: materials.join("rotated-client.key"),
            wrong_client_cert: materials.join("wrong-client.crt"),
            wrong_client_key: materials.join("wrong-client.key"),
        }
    }

    pub fn options(&self, port: u16, mode: TlsMode, root_cert: Option<PathBuf>) -> ConnectOptions {
        ConnectOptions {
            host: self.host.clone(),
            port,
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

    pub fn mongo(&self, mode: TlsMode, root_cert: Option<PathBuf>) -> ConnectOptions {
        self.options(self.mongo_port, mode, root_cert)
    }

    pub fn mongo_plaintext(&self) -> ConnectOptions {
        self.options(self.mongo_plaintext_port, TlsMode::Disabled, None)
    }

    /// Redis takes its database as a numeric index and authenticates with a
    /// password only, so the shared options are narrowed here.
    pub fn redis(&self, mode: TlsMode, root_cert: Option<PathBuf>) -> ConnectOptions {
        let mut options = self.options(self.redis_port, mode, root_cert);
        options.database = "0".into();
        options.username = String::new();
        options
    }

    pub fn redis_plaintext(&self) -> ConnectOptions {
        let mut options = self.options(self.redis_plaintext_port, TlsMode::Disabled, None);
        options.database = "0".into();
        options.username = String::new();
        options
    }

    pub fn mysql(&self, mode: TlsMode, root_cert: Option<PathBuf>) -> ConnectOptions {
        self.options(self.mysql_port, mode, root_cert)
    }

    pub fn postgres(&self, mode: TlsMode, root_cert: Option<PathBuf>) -> ConnectOptions {
        self.options(self.postgres_port, mode, root_cert)
    }

    pub fn mysql_mtls(
        &self,
        mode: TlsMode,
        client_cert: Option<PathBuf>,
        client_key: Option<PathBuf>,
    ) -> ConnectOptions {
        let mut options = self.options(self.mysql_mtls_port, mode, Some(self.ca_cert.clone()));
        options.username = "tablepro_mtls".into();
        options.tls.client_cert = client_cert;
        options.tls.client_key = client_key;
        options
    }

    pub fn mysql_mtls_ssh(
        &self,
        identity_host: &str,
        tunnel: &SshTunnel,
        mode: TlsMode,
        client_cert: Option<PathBuf>,
        client_key: Option<PathBuf>,
    ) -> ConnectOptions {
        let mut options = self.options(3306, mode, Some(self.ca_cert.clone()));
        options.username = "tablepro_mtls".into();
        options.host = identity_host.to_string();
        options.service_endpoint = Some((identity_host.to_string(), 3306));
        options.forwarded_socket_dir = Some(
            tunnel
                .socket_dir()
                .expect("the MySQL mTLS tunnel uses a Unix socket")
                .to_path_buf(),
        );
        options.tls.client_cert = client_cert;
        options.tls.client_key = client_key;
        options
    }

    pub async fn open_mysql_ssh_tunnel(&self) -> SshTunnel {
        SshTunnel::open_chain_socket(
            &[self.ssh_config()],
            "mysql-ssh.tablepro.test".into(),
            3306,
            "mysqld.sock",
            UnknownHostKey::Learn,
        )
        .await
        .expect("open SSH socket forward to the unpublished MySQL fixture")
    }

    pub async fn open_mysql_mtls_ssh_tunnel(&self) -> SshTunnel {
        SshTunnel::open_chain_socket(
            &[self.ssh_config()],
            "mysql-mtls-ssh.tablepro.test".into(),
            3306,
            "mysqld.sock",
            UnknownHostKey::Learn,
        )
        .await
        .expect("open SSH socket forward to the unpublished mTLS MySQL fixture")
    }

    pub async fn open_mssql_ssh_tunnel(&self) -> SshTunnel {
        SshTunnel::open(
            self.ssh_config(),
            "mssql-ssh.tablepro.test".into(),
            1433,
            UnknownHostKey::Learn,
        )
        .await
        .expect("open SSH TCP forward to the unpublished SQL Server fixture")
    }

    fn ssh_config(&self) -> SshConfig {
        SshConfig {
            host: self.ssh_host.clone(),
            port: self.ssh_port,
            username: "tunnel".into(),
            auth: SshAuth::PrivateKey {
                path: self.ssh_key.clone(),
                passphrase: None,
            },
        }
    }

    pub fn mysql_ssh(
        &self,
        identity_host: &str,
        tunnel: &SshTunnel,
        mode: TlsMode,
        root_cert: Option<PathBuf>,
    ) -> ConnectOptions {
        let mut options = self.options(3306, mode, root_cert);
        options.host = identity_host.to_string();
        options.service_endpoint = Some((identity_host.to_string(), 3306));
        options.forwarded_socket_dir = Some(
            tunnel
                .socket_dir()
                .expect("the MySQL tunnel uses a Unix socket")
                .to_path_buf(),
        );
        options
    }

    pub fn mssql_ssh(
        &self,
        identity_host: &str,
        tunnel: &SshTunnel,
        mode: TlsMode,
        root_cert: Option<PathBuf>,
    ) -> ConnectOptions {
        let mut options = self.options(1433, mode, root_cert);
        options.host = tunnel.local_host().to_string();
        options.port = tunnel.local_port();
        options.service_endpoint = Some((identity_host.to_string(), 1433));
        options
    }

    pub fn clickhouse(&self, mode: TlsMode, root_cert: Option<PathBuf>) -> ConnectOptions {
        self.options(self.clickhouse_port, mode, root_cert)
    }

    pub fn mysql_plaintext(&self) -> ConnectOptions {
        self.options(self.mysql_plaintext_port, TlsMode::Disabled, None)
    }

    pub fn clickhouse_plaintext(&self) -> ConnectOptions {
        self.options(self.clickhouse_plaintext_port, TlsMode::Disabled, None)
    }

    pub fn mssql(&self, mode: TlsMode, root_cert: Option<PathBuf>) -> ConnectOptions {
        self.options(self.mssql_port, mode, root_cert)
    }

    pub fn mssql_plaintext(&self) -> ConnectOptions {
        self.options(self.mssql_plaintext_port, TlsMode::Disabled, None)
    }
}

#[cfg(test)]
mod tests {
    use super::{DriverTlsFixture, TlsMode};

    #[test]
    fn postgres_options_use_fixture_port_and_system_roots() {
        let fixture = DriverTlsFixture::from_env();
        let options = fixture.postgres(TlsMode::VerifyFull, None);

        assert_eq!(options.port, fixture.postgres_port);
        assert_eq!(options.tls.mode, TlsMode::VerifyFull);
        assert_eq!(options.tls.root_cert, None);
    }
}
