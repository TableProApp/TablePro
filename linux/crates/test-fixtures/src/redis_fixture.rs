use std::time::Duration;

use testcontainers::core::IntoContainerPort;
use testcontainers::{ContainerAsync, ContainerRequest, GenericImage, ImageExt};
use tokio::time::Instant;

use crate::container_file::with_files;
use crate::container_start::start_container;
use crate::{
    ContainerFile, ExecOutput, FixtureCredentials, FixtureError, PkiFile, RedisVersion, ServerVersion, TestNetwork,
    TestPki,
};

const PORT: u16 = RedisFixture::PORT;
const CERTIFICATE_PORT: u16 = RedisFixture::CERTIFICATE_PORT;
const PASSWORD_USER: &str = "tablepro";
const CONFIG_DIR: &str = "/etc/tablepro";
const SERVICE: &str = "redis";
const READY_TIMEOUT: Duration = Duration::from_secs(60);
const READY_RETRY: Duration = Duration::from_millis(250);

/// How the fixture's server takes connections.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Listening {
    Plain,
    /// TLS only on `PORT`, where a client certificate is optional, and
    /// on `CERTIFICATE_PORT`, a second server that requires one.
    Tls,
}

/// A Redis server with a password on its default user and an ACL user,
/// `tablepro`, with the same password.
pub struct RedisFixture {
    container: ContainerAsync<GenericImage>,
    pki: TestPki,
    password: String,
    host: String,
    port: u16,
    certificate_port: Option<u16>,
    network_alias: Option<String>,
    version: RedisVersion,
}

impl RedisFixture {
    pub const PORT: u16 = 6379;
    pub const CERTIFICATE_PORT: u16 = 6380;
    pub const NETWORK_ROLE: &'static str = "redis";

    pub async fn start() -> Result<Self, FixtureError> {
        Self::launch(None, Listening::Plain).await
    }

    pub async fn start_in(network: &TestNetwork) -> Result<Self, FixtureError> {
        Self::launch(Some(network), Listening::Plain).await
    }

    /// A server that takes only TLS, with a second one beside it that
    /// takes only clients that present a certificate the CA issued.
    pub async fn start_tls() -> Result<Self, FixtureError> {
        Self::launch(None, Listening::Tls).await
    }

    async fn launch(network: Option<&TestNetwork>, listening: Listening) -> Result<Self, FixtureError> {
        let pki = TestPki::generate()?;
        let password = FixtureCredentials::generate_password();
        let version = RedisVersion::selected()?;
        let mut request: ContainerRequest<GenericImage> = version
            .image()
            .generic()
            .with_exposed_port(PORT.tcp())
            .with_exposed_port(CERTIFICATE_PORT.tcp())
            .with_cmd(["sh".to_owned(), "-c".to_owned(), start_command(listening)]);
        let network_alias = network.map(|network| network.container_name(Self::NETWORK_ROLE));
        if let (Some(network), Some(alias)) = (network, &network_alias) {
            request = request.with_network(network.name()).with_container_name(alias);
        }
        let container = start_container(with_files(request, Self::files(&pki, &password)?)).await?;
        let host = container.get_host().await?.to_string();
        let port = container.get_host_port_ipv4(PORT).await?;
        let certificate_port = match listening {
            Listening::Plain => None,
            Listening::Tls => Some(container.get_host_port_ipv4(CERTIFICATE_PORT).await?),
        };
        let fixture = Self {
            container,
            pki,
            password,
            host,
            port,
            certificate_port,
            network_alias,
            version,
        };
        fixture.wait_ready(listening).await?;
        Ok(fixture)
    }

    /// The servers' configurations and the PKI they read. Every file is
    /// written whatever the fixture listens on, so one list serves both.
    pub fn files(pki: &TestPki, password: &str) -> Result<Vec<ContainerFile>, FixtureError> {
        let users = format!("requirepass {password}\nuser {PASSWORD_USER} on >{password} ~* &* +@all\n");
        let tls = format!(
            "tls-cert-file {CONFIG_DIR}/server.pem\n\
             tls-key-file {CONFIG_DIR}/server.key\n\
             tls-ca-cert-file {CONFIG_DIR}/ca.pem\n"
        );
        let plain = format!("bind * -::*\nprotected-mode no\nport {PORT}\n{users}");
        let tls_only = format!("bind * -::*\nport 0\ntls-port {PORT}\ntls-auth-clients optional\n{tls}{users}");
        let certificate_only =
            format!("bind * -::*\nport 0\ntls-port {CERTIFICATE_PORT}\ntls-auth-clients yes\n{tls}dir /tmp\n");
        Ok(vec![
            ContainerFile::readable(format!("{CONFIG_DIR}/plain.conf"), plain),
            ContainerFile::readable(format!("{CONFIG_DIR}/tls.conf"), tls_only),
            ContainerFile::readable(format!("{CONFIG_DIR}/certificate.conf"), certificate_only),
            ContainerFile::readable(format!("{CONFIG_DIR}/ca.pem"), pki.read(PkiFile::Ca)?),
            ContainerFile::readable(
                format!("{CONFIG_DIR}/server.pem"),
                pki.read(PkiFile::ServerCertificate)?,
            ),
            ContainerFile::readable(format!("{CONFIG_DIR}/server.key"), pki.read(PkiFile::ServerKey)?),
            ContainerFile::readable(
                format!("{CONFIG_DIR}/client.pem"),
                pki.read(PkiFile::ClientCertificate)?,
            ),
            ContainerFile::readable(format!("{CONFIG_DIR}/client.key"), pki.read(PkiFile::ClientKey)?),
        ])
    }

    pub fn host(&self) -> &str {
        &self.host
    }

    /// The port of the plain server, or of the TLS-only one.
    pub fn port(&self) -> u16 {
        self.port
    }

    /// The port of the server that requires a client certificate, which a
    /// TLS fixture has.
    pub fn certificate_port(&self) -> Option<u16> {
        self.certificate_port
    }

    pub fn network_alias(&self) -> Option<&str> {
        self.network_alias.as_deref()
    }

    pub fn version(&self) -> RedisVersion {
        self.version
    }

    pub fn pki(&self) -> &TestPki {
        &self.pki
    }

    /// The ACL user, which may run every command.
    pub fn password_credentials(&self) -> FixtureCredentials {
        FixtureCredentials::new(PASSWORD_USER, &self.password)
    }

    /// The default user, which a password alone logs in as.
    pub fn default_user_credentials(&self) -> FixtureCredentials {
        FixtureCredentials::new("", &self.password)
    }

    pub fn container(&self) -> &ContainerAsync<GenericImage> {
        &self.container
    }

    pub async fn exec(&self, command: &[&str]) -> Result<ExecOutput, FixtureError> {
        ExecOutput::run(&self.container, command).await
    }

    /// Run one command with redis-cli inside the container, as the ACL
    /// user, on the plain or TLS-only server.
    pub async fn cli(&self, arguments: &[&str]) -> Result<ExecOutput, FixtureError> {
        let mut command = vec![
            "redis-cli",
            "-p",
            "6379",
            "--user",
            PASSWORD_USER,
            "--pass",
            &self.password,
            "--no-auth-warning",
        ];
        let ca = format!("{CONFIG_DIR}/ca.pem");
        if self.certificate_port.is_some() {
            command.extend(["--tls", "--cacert", &ca]);
        }
        command.extend_from_slice(arguments);
        self.exec(&command).await
    }

    /// Each server says it is ready on the container's output; the TLS
    /// fixture runs two.
    async fn wait_ready(&self, listening: Listening) -> Result<(), FixtureError> {
        let servers = match listening {
            Listening::Plain => 1,
            Listening::Tls => 2,
        };
        let deadline = Instant::now() + READY_TIMEOUT;
        loop {
            let output = self.container.stdout_to_vec().await.unwrap_or_default();
            if ready_servers(&output) >= servers {
                return Ok(());
            }
            if !self.container.is_running().await? {
                return Err(self.not_ready("the container exited").await);
            }
            if Instant::now() >= deadline {
                return Err(self.not_ready("no server said it was ready").await);
            }
            tokio::time::sleep(READY_RETRY).await;
        }
    }

    async fn not_ready(&self, reason: &str) -> FixtureError {
        let stdout = self.container.stdout_to_vec().await.unwrap_or_default();
        let stderr = self.container.stderr_to_vec().await.unwrap_or_default();
        FixtureError::ContainerNotReady {
            service: SERVICE,
            reason: reason.to_owned(),
            last_reply: String::new(),
            state: String::new(),
            logs: format!(
                "stdout:\n{}\nstderr:\n{}",
                String::from_utf8_lossy(&stdout),
                String::from_utf8_lossy(&stderr)
            ),
        }
    }
}

/// The container's command: the plain server, or the TLS-only one with
/// the certificate-only server beside it, both writing to its output.
fn start_command(listening: Listening) -> String {
    match listening {
        Listening::Plain => format!("exec redis-server {CONFIG_DIR}/plain.conf"),
        Listening::Tls => {
            format!("redis-server {CONFIG_DIR}/certificate.conf & exec redis-server {CONFIG_DIR}/tls.conf")
        }
    }
}

/// How many servers said they take connections.
fn ready_servers(output: &[u8]) -> usize {
    let marker: &[u8] = b"Ready to accept connections";
    output.windows(marker.len()).filter(|window| *window == marker).count()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(files: &[ContainerFile], name: &str) -> String {
        let target = format!("{CONFIG_DIR}/{name}");
        let found = files.iter().find(|file| file.target() == target).unwrap();
        String::from_utf8_lossy(found.contents()).into_owned()
    }

    #[test]
    fn each_server_listens_where_its_mode_says() {
        let pki = TestPki::generate().unwrap();
        let files = RedisFixture::files(&pki, "secret").unwrap();

        assert!(file(&files, "plain.conf").contains("port 6379\n"));
        let tls = file(&files, "tls.conf");
        assert!(
            tls.contains("port 0\ntls-port 6379\ntls-auth-clients optional\n"),
            "{tls}"
        );
        let certificate = file(&files, "certificate.conf");
        assert!(
            certificate.contains("tls-port 6380\ntls-auth-clients yes\n"),
            "{certificate}"
        );
        assert!(!certificate.contains("requirepass"), "the certificate is the login");
        for name in ["plain.conf", "tls.conf"] {
            assert!(file(&files, name).contains("user tablepro on >secret ~* &* +@all\n"));
        }
    }

    #[test]
    fn the_tls_fixture_starts_both_servers() {
        assert_eq!(
            start_command(Listening::Tls),
            "redis-server /etc/tablepro/certificate.conf & exec redis-server /etc/tablepro/tls.conf"
        );
        assert_eq!(
            start_command(Listening::Plain),
            "exec redis-server /etc/tablepro/plain.conf"
        );
    }

    #[test]
    fn each_ready_server_is_counted() {
        let output = b"1:M * Ready to accept connections tcp\n7:M * Ready to accept connections tls\n";

        assert_eq!(ready_servers(output), 2);
        assert_eq!(ready_servers(b"starting"), 0);
    }
}
