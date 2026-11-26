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
        Self::launch(TestPki::generate()?, false).await
    }

    /// A server whose certificate is self-signed, which a client accepts
    /// only by trusting that certificate itself.
    pub async fn start_self_signed() -> Result<Self, FixtureError> {
        Self::launch(TestPki::generate_self_signed()?, false).await
    }

    /// A server that takes only strict (TDS 8.0) connections. Needs SQL
    /// Server 2025 or later.
    pub async fn start_force_strict() -> Result<Self, FixtureError> {
        Self::launch(TestPki::generate()?, true).await
    }

    async fn launch(pki: TestPki, force_strict: bool) -> Result<Self, FixtureError> {
        let password = format!("Tp1!{}", Uuid::new_v4().simple());
        let version = MssqlVersion::selected()?;
        let image = version.image();
        let files = Self::files(&pki, force_strict)?;
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

    pub fn files(pki: &TestPki, force_strict: bool) -> Result<Vec<ContainerFile>, FixtureError> {
        let tls = Self::TLS_DIR;
        let mut configuration = format!(
            "[network]\n\
             tlscert = {tls}/server.pem\n\
             tlskey = {tls}/server.key\n\
             tlsprotocols = 1.2\n\
             forceencryption = 1\n"
        );
        if force_strict {
            configuration.push_str("forcestrict = 1\n");
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    fn configuration(force_strict: bool) -> String {
        let pki = TestPki::generate().unwrap();
        let files = MssqlFixture::files(&pki, force_strict).unwrap();
        let file = files
            .iter()
            .find(|file| file.target() == "/var/opt/mssql/mssql.conf")
            .unwrap();
        String::from_utf8_lossy(file.contents()).into_owned()
    }

    #[test]
    fn only_the_force_strict_server_enforces_strict_encryption() {
        let strict = configuration(true);

        assert!(strict.starts_with("[network]\n"), "{strict}");
        assert!(strict.contains("\nforceencryption = 1\nforcestrict = 1\n"), "{strict}");
        assert!(!configuration(false).contains("forcestrict"));
    }
}
