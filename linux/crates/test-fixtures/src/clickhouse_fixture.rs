use std::time::Duration;

use testcontainers::core::wait::HttpWaitStrategy;
use testcontainers::core::{IntoContainerPort, WaitFor};
use testcontainers::runners::AsyncRunner;
use testcontainers::{ContainerAsync, GenericImage, ImageExt};

use crate::container_file::with_files;
use crate::{ContainerFile, ExecOutput, FixtureCredentials, FixtureError, FixtureImage, PkiFile, TestNetwork, TestPki};

const HTTP_PORT: u16 = ClickHouseFixture::HTTP_PORT;
const HTTPS_PORT: u16 = ClickHouseFixture::HTTPS_PORT;
const PASSWORD_USER: &str = "tablepro";
/// The image starts the server once to create CLICKHOUSE_DB, stops it and
/// starts it again before /ping answers; on a busy CI runner that has
/// taken longer than testcontainers' default of one minute.
const STARTUP_TIMEOUT: Duration = Duration::from_secs(180);

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

    async fn launch(network: Option<&TestNetwork>) -> Result<Self, FixtureError> {
        let pki = TestPki::generate()?;
        let password = FixtureCredentials::generate_password();
        let ready = HttpWaitStrategy::new("/ping")
            .with_port(HTTP_PORT.tcp())
            .with_expected_status_code(200_u16);
        let mut request = FixtureImage::CLICKHOUSE
            .generic()
            .with_exposed_port(HTTP_PORT.tcp())
            .with_exposed_port(HTTPS_PORT.tcp())
            .with_wait_for(WaitFor::http(ready))
            .with_startup_timeout(STARTUP_TIMEOUT)
            .with_env_var("CLICKHOUSE_DB", "tablepro");
        let network_alias = network.map(|network| network.container_name(Self::NETWORK_ROLE));
        if let (Some(network), Some(alias)) = (network, &network_alias) {
            request = request.with_network(network.name()).with_container_name(alias);
        }
        let container = with_files(request, Self::files(&pki, &password)?).start().await?;
        let host = container.get_host().await?.to_string();
        let http_port = container.get_host_port_ipv4(HTTP_PORT).await?;
        let https_port = container.get_host_port_ipv4(HTTPS_PORT).await?;
        Ok(Self {
            container,
            pki,
            password,
            host,
            http_port,
            https_port,
            network_alias,
        })
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
}
