use std::time::Duration;

use testcontainers::core::IntoContainerPort;
use testcontainers::{ContainerAsync, ContainerRequest, GenericImage, ImageExt, TestcontainersError};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::time::Instant;

use crate::container_file::with_files;
use crate::container_report::{container_state, log_tail};
use crate::container_start::start_container;
use crate::{
    ClickHouseVersion, ContainerFile, ExecOutput, FixtureCredentials, FixtureError, PkiFile, ServerVersion,
    TestNetwork, TestPki,
};

const HTTP_PORT: u16 = ClickHouseFixture::HTTP_PORT;
const HTTPS_PORT: u16 = ClickHouseFixture::HTTPS_PORT;
const PASSWORD_USER: &str = "tablepro";
const LIMITED_USER: &str = "tablepro_limited";
const DATABASE: &str = "tablepro";
const SERVICE: &str = "clickhouse";
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
    version: ClickHouseVersion,
}

impl ClickHouseFixture {
    pub const TLS_DIR: &'static str = "/etc/clickhouse-server/tls";
    pub const NETWORK_ROLE: &'static str = "clickhouse";
    pub const HTTP_PORT: u16 = 8123;
    pub const HTTPS_PORT: u16 = 8443;

    pub async fn start() -> Result<Self, FixtureError> {
        Self::launch(None, Vec::new(), READY_TIMEOUT).await
    }

    pub async fn start_in(network: &TestNetwork) -> Result<Self, FixtureError> {
        Self::launch(Some(network), Vec::new(), READY_TIMEOUT).await
    }

    // No CLICKHOUSE_DB: the image would start, stop and restart the server
    // to create it. One HTTP CREATE DATABASE is both that and the readiness check.
    async fn launch(
        network: Option<&TestNetwork>,
        extra_files: Vec<ContainerFile>,
        ready_timeout: Duration,
    ) -> Result<Self, FixtureError> {
        let pki = TestPki::generate()?;
        let password = FixtureCredentials::generate_password();
        let version = ClickHouseVersion::selected()?;
        let network_alias = network.map(|network| network.container_name(Self::NETWORK_ROLE));
        let mut files = Self::files(&pki, &password)?;
        files.extend(extra_files);
        let container = start_container(|| {
            let mut request: ContainerRequest<GenericImage> = version
                .image()
                .generic()
                .with_exposed_port(HTTP_PORT.tcp())
                .with_exposed_port(HTTPS_PORT.tcp())
                .into();
            if let (Some(network), Some(alias)) = (network, &network_alias) {
                request = request.with_network(network.name()).with_container_name(alias);
            }
            with_files(request, files.clone())
        })
        .await?;
        let (host, http_port, https_port) = match published(&container).await {
            Ok(published) => published,
            Err(error) => {
                let reason = format!("its ports are not published: {error}");
                return Err(not_ready(&container, reason, "none".to_owned()).await);
            }
        };
        let fixture = Self {
            container,
            pki,
            password,
            host,
            http_port,
            https_port,
            network_alias,
            version,
        };
        fixture.create_database(ready_timeout).await?;
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
             <{LIMITED_USER}>\n\
             <password>{password}</password>\n\
             <networks><ip>::/0</ip></networks>\n\
             <profile>default</profile><quota>default</quota>\n\
             <grants>\n\
             <query>GRANT SELECT ON {DATABASE}.*</query>\n\
             <query>GRANT SELECT ON system.query_log</query>\n\
             <query>GRANT SYSTEM FLUSH LOGS ON *.*</query>\n\
             </grants>\n\
             </{LIMITED_USER}>\n\
             <{client}>\n\
             <ssl_certificates><common_name>{client}</common_name></ssl_certificates>\n\
             <networks><ip>::/0</ip></networks>\n\
             <profile>default</profile><quota>default</quota>\n\
             </{client}>\n\
             </users></clickhouse>\n"
        );
        // Otherwise the server logs only to files, and a failed start leaves no log to report.
        let console = "<clickhouse><logger>\n\
                       <console>1</console>\n\
                       <console_log_level>information</console_log_level>\n\
                       </logger></clickhouse>\n";
        Ok(vec![
            ContainerFile::readable("/etc/clickhouse-server/config.d/tls.xml", server),
            ContainerFile::readable("/etc/clickhouse-server/config.d/console.xml", console),
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

    pub fn version(&self) -> ClickHouseVersion {
        self.version
    }

    pub fn pki(&self) -> &TestPki {
        &self.pki
    }

    pub fn password_credentials(&self) -> FixtureCredentials {
        FixtureCredentials::new(PASSWORD_USER, &self.password)
    }

    /// A login granted the query log but not `system.processes`, which the
    /// stock server config holds back without a grant.
    pub fn limited_credentials(&self) -> FixtureCredentials {
        FixtureCredentials::new(LIMITED_USER, &self.password)
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

    async fn create_database(&self, ready_timeout: Duration) -> Result<(), FixtureError> {
        let request = query_request(
            &self.host,
            &self.password_credentials(),
            &format!("CREATE DATABASE IF NOT EXISTS {DATABASE}"),
        );
        let deadline = Instant::now() + ready_timeout;
        loop {
            let attempt = exchange(&self.host, self.http_port, &request);
            let last_reply = match tokio::time::timeout(READY_ATTEMPT, attempt).await {
                Ok(Ok(reply)) if status_code(&reply) == Some(200) => return Ok(()),
                Ok(Ok(reply)) => reply_summary(&reply),
                Ok(Err(error)) => error.to_string(),
                Err(_) => format!("no reply within {} seconds", READY_ATTEMPT.as_secs()),
            };
            if !self.container.is_running().await? {
                return Err(not_ready(&self.container, "the container exited".to_owned(), last_reply).await);
            }
            if Instant::now() >= deadline {
                let reason = format!("no answer within {} seconds", ready_timeout.as_secs());
                return Err(not_ready(&self.container, reason, last_reply).await);
            }
            tokio::time::sleep(READY_RETRY).await;
        }
    }
}

async fn published(container: &ContainerAsync<GenericImage>) -> Result<(String, u16, u16), TestcontainersError> {
    let host = container.get_host().await?.to_string();
    let http_port = container.get_host_port_ipv4(HTTP_PORT).await?;
    let https_port = container.get_host_port_ipv4(HTTPS_PORT).await?;
    Ok((host, http_port, https_port))
}

async fn not_ready(container: &ContainerAsync<GenericImage>, reason: String, last_reply: String) -> FixtureError {
    FixtureError::ContainerNotReady {
        service: SERVICE,
        reason,
        last_reply,
        state: container_state(container).await,
        logs: log_tail(container).await,
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

fn reply_summary(reply: &str) -> String {
    let status = reply.lines().next().unwrap_or_default();
    let body = reply
        .split_once("\r\n\r\n")
        .and_then(|(_, body)| body.lines().find(|line| !line.trim().is_empty()))
        .unwrap_or_default();
    match (status.is_empty(), body.is_empty()) {
        (true, _) => "an empty reply".to_owned(),
        (false, true) => status.to_owned(),
        (false, false) => format!("{status}: {body}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config_file(name: &str, body: &str) -> ContainerFile {
        ContainerFile::readable(
            format!("/etc/clickhouse-server/config.d/{name}"),
            format!("<clickhouse>{body}</clickhouse>\n"),
        )
    }

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

    #[test]
    fn a_refused_query_is_summarised_with_the_server_message() {
        let reply = "HTTP/1.0 516 Unknown\r\nX-ClickHouse-Exception-Code: 516\r\n\r\n\
                     Code: 516. DB::Exception: tablepro: Authentication failed\n";

        assert_eq!(
            reply_summary(reply),
            "HTTP/1.0 516 Unknown: Code: 516. DB::Exception: tablepro: Authentication failed"
        );
        assert_eq!(
            reply_summary("HTTP/1.0 500 Internal Server Error\r\n\r\n"),
            "HTTP/1.0 500 Internal Server Error"
        );
        assert_eq!(reply_summary(""), "an empty reply");
    }

    #[test]
    fn the_server_also_logs_to_the_console() {
        let pki = TestPki::generate().unwrap();
        let files = ClickHouseFixture::files(&pki, "secret").unwrap();

        let console = files
            .iter()
            .find(|file| file.target() == "/etc/clickhouse-server/config.d/console.xml")
            .unwrap();

        let text = String::from_utf8_lossy(console.contents());
        assert!(text.contains("<console>1</console>"), "{text}");
        assert!(
            text.contains("<console_log_level>information</console_log_level>"),
            "{text}"
        );
    }

    #[tokio::test]
    #[ignore = "requires docker"]
    async fn a_server_that_exits_is_reported_at_once_with_its_state_and_logs() {
        let broken = config_file("zz-broken.xml", "<timezone>Nowhere/Invalid</timezone>");
        let started = Instant::now();

        let error = ClickHouseFixture::launch(None, vec![broken], READY_TIMEOUT)
            .await
            .err()
            .unwrap();

        assert!(started.elapsed() < READY_TIMEOUT / 2, "took {:?}", started.elapsed());
        let FixtureError::ContainerNotReady {
            reason, state, logs, ..
        } = &error
        else {
            panic!("unexpected error: {error}");
        };
        assert_eq!(reason, "the container exited");
        assert!(state.starts_with("status exited, exit code "), "{state}");
        assert!(logs.contains("Nowhere/Invalid"), "{logs}");
    }

    #[tokio::test]
    #[ignore = "requires docker"]
    async fn a_server_that_never_answers_is_reported_with_its_state_and_logs() {
        let elsewhere = config_file("zz-elsewhere.xml", "<http_port>8124</http_port>");

        let error = ClickHouseFixture::launch(None, vec![elsewhere], Duration::from_secs(8))
            .await
            .err()
            .unwrap();

        let FixtureError::ContainerNotReady {
            reason, state, logs, ..
        } = &error
        else {
            panic!("unexpected error: {error}");
        };
        assert_eq!(reason, "no answer within 8 seconds");
        assert!(state.starts_with("status running, "), "{state}");
        assert!(logs.contains("Listening for http://0.0.0.0:8124"), "{logs}");
    }
}
