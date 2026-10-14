use std::time::Duration;

use testcontainers::core::IntoContainerPort;
use testcontainers::runners::AsyncRunner;
use testcontainers::{ContainerAsync, ContainerRequest, GenericImage, ImageExt};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::time::Instant;

use crate::container_file::with_files;
use crate::{ContainerFile, ExecOutput, FixtureCredentials, FixtureError, FixtureImage, PkiFile, TestNetwork, TestPki};

const HTTP_PORT: u16 = ClickHouseFixture::HTTP_PORT;
const HTTPS_PORT: u16 = ClickHouseFixture::HTTPS_PORT;
const PASSWORD_USER: &str = "tablepro";
const DATABASE: &str = "tablepro";
const READY_TIMEOUT: Duration = Duration::from_secs(60);
// A connection that is accepted and never answered must not use up the deadline.
const READY_ATTEMPT: Duration = Duration::from_secs(5);
const READY_RETRY: Duration = Duration::from_millis(250);

pub struct ClickHouseFixture {
    container: ContainerAsync<GenericImage>,
    pki: TestPki,
    password: String,
    host: String,
    http_port: u16,
    https_port: u16,
    network_alias: Option<String>,
}

impl ClickHouseFixture {
    pub const TLS_DIR: &'static str = "/etc/clickhouse-server/tls";
    pub const NETWORK_ROLE: &'static str = "clickhouse";
    pub const HTTP_PORT: u16 = 8123;
    pub const HTTPS_PORT: u16 = 8443;

    pub async fn start() -> Result<Self, FixtureError> {
        Self::launch(None).await
    }

    pub async fn start_in(network: &TestNetwork) -> Result<Self, FixtureError> {
        Self::launch(Some(network)).await
    }

    // No CLICKHOUSE_DB: the image would start, stop and restart the server
    // to create it. One HTTP CREATE DATABASE is both that and the readiness check.
    async fn launch(network: Option<&TestNetwork>) -> Result<Self, FixtureError> {
        let pki = TestPki::generate()?;
        let password = FixtureCredentials::generate_password();
        let mut request: ContainerRequest<GenericImage> = FixtureImage::CLICKHOUSE
            .generic()
            .with_exposed_port(HTTP_PORT.tcp())
            .with_exposed_port(HTTPS_PORT.tcp())
            .into();
        let network_alias = network.map(|network| network.container_name(Self::NETWORK_ROLE));
        if let (Some(network), Some(alias)) = (network, &network_alias) {
            request = request.with_network(network.name()).with_container_name(alias);
        }
        let container = with_files(request, Self::files(&pki, &password)?).start().await?;
        let host = container.get_host().await?.to_string();
        let http_port = container.get_host_port_ipv4(HTTP_PORT).await?;
        let https_port = container.get_host_port_ipv4(HTTPS_PORT).await?;
        let fixture = Self {
            container,
            pki,
            password,
            host,
            http_port,
            https_port,
            network_alias,
        };
        fixture.create_database().await?;
        Ok(fixture)
    }

    pub fn files(pki: &TestPki, password: &str) -> Result<Vec<ContainerFile>, FixtureError> {
        let tls = Self::TLS_DIR;
        let client = TestPki::CLIENT_COMMON_NAME;
        let server = format!(
            "<clickhouse>\n\
             <https_port>{HTTPS_PORT}</https_port>\n\
             <openSSL><server>\n\
             <certificateFile>{tls}/server.pem</certificateFile>\n\
             <privateKeyFile>{tls}/server.key</privateKeyFile>\n\
             <caConfig>{tls}/ca.pem</caConfig>\n\
             <verificationMode>relaxed</verificationMode>\n\
             <loadDefaultCAFile>false</loadDefaultCAFile>\n\
             </server></openSSL>\n\
             </clickhouse>\n"
        );
        let users = format!(
            "<clickhouse><users>\n\
             <{PASSWORD_USER}>\n\
             <password>{password}</password>\n\
             <networks><ip>::/0</ip></networks>\n\
             <profile>default</profile><quota>default</quota>\n\
             </{PASSWORD_USER}>\n\
             <{client}>\n\
             <ssl_certificates><common_name>{client}</common_name></ssl_certificates>\n\
             <networks><ip>::/0</ip></networks>\n\
             <profile>default</profile><quota>default</quota>\n\
             </{client}>\n\
             </users></clickhouse>\n"
        );
        Ok(vec![
            ContainerFile::readable("/etc/clickhouse-server/config.d/tls.xml", server),
            ContainerFile::readable("/etc/clickhouse-server/users.d/tablepro.xml", users),
            ContainerFile::readable(format!("{tls}/ca.pem"), pki.read(PkiFile::Ca)?),
            ContainerFile::readable(format!("{tls}/server.pem"), pki.read(PkiFile::ServerCertificate)?),
            ContainerFile::readable(format!("{tls}/server.key"), pki.read(PkiFile::ServerKey)?),
        ])
    }

    pub fn host(&self) -> &str {
        &self.host
    }

    pub fn http_port(&self) -> u16 {
        self.http_port
    }

    pub fn https_port(&self) -> u16 {
        self.https_port
    }

    pub fn network_alias(&self) -> Option<&str> {
        self.network_alias.as_deref()
    }

    pub fn pki(&self) -> &TestPki {
        &self.pki
    }

    pub fn password_credentials(&self) -> FixtureCredentials {
        FixtureCredentials::new(PASSWORD_USER, &self.password)
    }

    pub fn certificate_credentials(&self) -> FixtureCredentials {
        FixtureCredentials::new(TestPki::CLIENT_COMMON_NAME, "")
    }

    pub fn container(&self) -> &ContainerAsync<GenericImage> {
        &self.container
    }

    pub async fn exec(&self, command: &[&str]) -> Result<ExecOutput, FixtureError> {
        ExecOutput::run(&self.container, command).await
    }

    async fn create_database(&self) -> Result<(), FixtureError> {
        let request = query_request(
            &self.host,
            &self.password_credentials(),
            &format!("CREATE DATABASE IF NOT EXISTS {DATABASE}"),
        );
        let deadline = Instant::now() + READY_TIMEOUT;
        while Instant::now() < deadline {
            let attempt = exchange(&self.host, self.http_port, &request);
            if let Ok(Ok(reply)) = tokio::time::timeout(READY_ATTEMPT, attempt).await
                && status_code(&reply) == Some(200)
            {
                return Ok(());
            }
            tokio::time::sleep(READY_RETRY).await;
        }
        Err(FixtureError::NotReady {
            service: "clickhouse",
            seconds: READY_TIMEOUT.as_secs(),
        })
    }
}

fn query_request(host: &str, credentials: &FixtureCredentials, query: &str) -> String {
    format!(
        "POST / HTTP/1.0\r\n\
         Host: {host}\r\n\
         X-ClickHouse-User: {}\r\n\
         X-ClickHouse-Key: {}\r\n\
         Content-Length: {}\r\n\
         \r\n\
         {query}",
        credentials.username,
        credentials.password,
        query.len(),
    )
}

async fn exchange(host: &str, port: u16, request: &str) -> std::io::Result<String> {
    let mut stream = TcpStream::connect((host, port)).await?;
    stream.write_all(request.as_bytes()).await?;
    let mut reply = Vec::new();
    stream.read_to_end(&mut reply).await?;
    Ok(String::from_utf8_lossy(&reply).into_owned())
}

fn status_code(reply: &str) -> Option<u16> {
    let status_line = reply.lines().next()?;
    let mut parts = status_line.split_whitespace();
    parts.next().filter(|version| version.starts_with("HTTP/"))?;
    parts.next()?.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_query_request_carries_the_credentials_and_the_body_length() {
        let request = query_request("localhost", &FixtureCredentials::new("tablepro", "secret"), "SELECT 1");

        assert!(request.starts_with("POST / HTTP/1.0\r\nHost: localhost\r\n"));
        assert!(request.contains("\r\nX-ClickHouse-User: tablepro\r\nX-ClickHouse-Key: secret\r\n"));
        assert!(request.ends_with("\r\nContent-Length: 8\r\n\r\nSELECT 1"));
    }

    #[test]
    fn only_an_http_status_line_yields_a_status() {
        assert_eq!(status_code("HTTP/1.0 200 OK\r\n\r\n"), Some(200));
        assert_eq!(status_code("HTTP/1.1 516 Unknown\r\n\r\nCode: 516."), Some(516));
        assert_eq!(status_code("SSH-2.0-OpenSSH_10.3\r\n"), None);
        assert_eq!(status_code(""), None);
    }
}
