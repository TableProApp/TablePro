use std::time::Duration;

use testcontainers::{ContainerAsync, ImageExt};
use testcontainers_modules::mssql_server::MssqlServer;
use uuid::Uuid;

use crate::container_file::with_files;
use crate::container_start::start_container;
use crate::{
    ContainerFile, ExecOutput, FixtureCredentials, FixtureError, MssqlVersion, PkiFile, ServerVersion, TestPki,
};

const CONTAINER_PORT: u16 = 1433;
const ADMIN_USER: &str = "sa";
const STARTUP_TIMEOUT: Duration = Duration::from_secs(240);
const MEMORY_LIMIT_MB: &str = "2048";

pub struct MssqlFixture {
    container: ContainerAsync<MssqlServer>,
    pki: TestPki,
    password: String,
    host: String,
    port: u16,
    version: MssqlVersion,
}

impl MssqlFixture {
    pub const TLS_DIR: &'static str = "/var/opt/mssql/tls";

    pub async fn start() -> Result<Self, FixtureError> {
        let pki = TestPki::generate()?;
        let password = format!("Tp1!{}", Uuid::new_v4().simple());
        let version = MssqlVersion::selected()?;
        let image = version.image();
        let files = Self::files(&pki)?;
        let container = start_container(|| {
            let request = MssqlServer::default()
                .with_accept_eula()
                .with_sa_password(&password)
                .with_name(image.name)
                .with_tag(image.tag)
                .with_startup_timeout(STARTUP_TIMEOUT)
                // SQL Server otherwise takes 80% of the host's memory, and a
                // container left behind by a killed test keeps all of it.
                .with_env_var("MSSQL_MEMORY_LIMIT_MB", MEMORY_LIMIT_MB);
            with_files(request, files.clone())
        })
        .await?;
        let host = container.get_host().await?.to_string();
        let port = container.get_host_port_ipv4(CONTAINER_PORT).await?;
        Ok(Self {
            container,
            pki,
            password,
            host,
            port,
            version,
        })
    }

    pub fn files(pki: &TestPki) -> Result<Vec<ContainerFile>, FixtureError> {
        let tls = Self::TLS_DIR;
        let configuration = format!(
            "[network]\n\
             tlscert = {tls}/server.pem\n\
             tlskey = {tls}/server.key\n\
             tlsprotocols = 1.2\n\
             forceencryption = 1\n"
        );
        Ok(vec![
            ContainerFile::readable("/var/opt/mssql/mssql.conf", configuration),
            ContainerFile::readable(format!("{tls}/server.pem"), pki.read(PkiFile::ServerCertificate)?),
            ContainerFile::readable(format!("{tls}/server.key"), pki.read(PkiFile::ServerKey)?),
        ])
    }

    pub fn host(&self) -> &str {
        &self.host
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn version(&self) -> MssqlVersion {
        self.version
    }

    pub fn pki(&self) -> &TestPki {
        &self.pki
    }

    pub fn password_credentials(&self) -> FixtureCredentials {
        FixtureCredentials::new(ADMIN_USER, &self.password)
    }

    pub fn container(&self) -> &ContainerAsync<MssqlServer> {
        &self.container
    }

    pub async fn exec(&self, command: &[&str]) -> Result<ExecOutput, FixtureError> {
        ExecOutput::run(&self.container, command).await
    }
}
