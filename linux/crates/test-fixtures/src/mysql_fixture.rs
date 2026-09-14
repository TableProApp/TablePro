use testcontainers::core::IntoContainerPort;
use testcontainers::runners::AsyncRunner;
use testcontainers::{ContainerAsync, GenericImage, ImageExt};

use crate::container_file::with_files;
use crate::{ContainerFile, ExecOutput, FixtureCredentials, FixtureError, MysqlFlavour, PkiFile, TestPki};

const DATABASE: &str = "tablepro";
const PASSWORD_USER: &str = "tablepro";
const CONTAINER_PORT: u16 = 3306;

pub struct MysqlFixture {
    container: ContainerAsync<GenericImage>,
    flavour: MysqlFlavour,
    pki: TestPki,
    password: String,
    certificate_password: String,
    host: String,
    port: u16,
}

impl MysqlFixture {
    pub const TLS_DIR: &'static str = "/etc/mysql/tls";

    pub async fn start(flavour: MysqlFlavour) -> Result<Self, FixtureError> {
        let pki = TestPki::generate()?;
        let password = FixtureCredentials::generate_password();
        let certificate_password = FixtureCredentials::generate_password();
        let prefix = flavour.environment_prefix();
        let image = flavour
            .ready_conditions()
            .into_iter()
            .fold(flavour.image().generic(), GenericImage::with_wait_for)
            .with_exposed_port(CONTAINER_PORT.tcp());
        let request = image
            .with_env_var(format!("{prefix}_RANDOM_ROOT_PASSWORD"), "yes")
            .with_env_var(format!("{prefix}_DATABASE"), DATABASE)
            .with_env_var(format!("{prefix}_USER"), PASSWORD_USER)
            .with_env_var(format!("{prefix}_PASSWORD"), &password)
            .with_cmd(Self::server_arguments());
        let container = with_files(request, Self::files(&pki, &certificate_password)?)
            .start()
            .await?;
        let host = container.get_host().await?.to_string();
        let port = container.get_host_port_ipv4(CONTAINER_PORT).await?;
        Ok(Self {
            container,
            flavour,
            pki,
            password,
            certificate_password,
            host,
            port,
        })
    }

    pub fn server_arguments() -> Vec<String> {
        let tls = Self::TLS_DIR;
        vec![
            format!("--ssl-ca={tls}/ca.pem"),
            format!("--ssl-cert={tls}/server.pem"),
            format!("--ssl-key={tls}/server.key"),
            "--require-secure-transport=ON".to_owned(),
        ]
    }

    pub fn files(pki: &TestPki, certificate_password: &str) -> Result<Vec<ContainerFile>, FixtureError> {
        let tls = Self::TLS_DIR;
        let client = TestPki::CLIENT_COMMON_NAME;
        let principals = format!(
            "ALTER USER '{PASSWORD_USER}'@'%' REQUIRE SSL;\n\
             CREATE USER '{client}'@'%' IDENTIFIED BY '{certificate_password}' REQUIRE X509;\n\
             GRANT ALL PRIVILEGES ON {DATABASE}.* TO '{client}'@'%';\n"
        );
        Ok(vec![
            ContainerFile::readable(format!("{tls}/ca.pem"), pki.read(PkiFile::Ca)?),
            ContainerFile::readable(format!("{tls}/server.pem"), pki.read(PkiFile::ServerCertificate)?),
            ContainerFile::readable(format!("{tls}/server.key"), pki.read(PkiFile::ServerKey)?),
            ContainerFile::readable(format!("{tls}/client.pem"), pki.read(PkiFile::ClientCertificate)?),
            ContainerFile::readable(format!("{tls}/client.key"), pki.read(PkiFile::ClientKey)?),
            ContainerFile::readable("/docker-entrypoint-initdb.d/10-principals.sql", principals),
        ])
    }

    pub fn flavour(&self) -> MysqlFlavour {
        self.flavour
    }

    pub fn host(&self) -> &str {
        &self.host
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn database(&self) -> &str {
        DATABASE
    }

    pub fn pki(&self) -> &TestPki {
        &self.pki
    }

    pub fn password_credentials(&self) -> FixtureCredentials {
        FixtureCredentials::new(PASSWORD_USER, &self.password)
    }

    pub fn certificate_credentials(&self) -> FixtureCredentials {
        FixtureCredentials::new(TestPki::CLIENT_COMMON_NAME, &self.certificate_password)
    }

    pub fn container(&self) -> &ContainerAsync<GenericImage> {
        &self.container
    }

    pub async fn exec(&self, command: &[&str]) -> Result<ExecOutput, FixtureError> {
        ExecOutput::run(&self.container, command).await
    }
}
