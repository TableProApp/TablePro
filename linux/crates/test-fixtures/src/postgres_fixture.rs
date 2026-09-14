use testcontainers::runners::AsyncRunner;
use testcontainers::{ContainerAsync, ImageExt};
use testcontainers_modules::postgres::Postgres;

use crate::container_file::with_files;
use crate::{
    ContainerFile, ExecOutput, FixtureCredentials, FixtureError, FixtureImage, HbaMode, PkiFile, TestNetwork, TestPki,
};

const DATABASE: &str = "tablepro";
const PASSWORD_USER: &str = "tablepro";
const CONTAINER_PORT: u16 = 5432;
const INSTALLED_KEY: &str = "/var/lib/postgresql/server.key";
const CERTIFICATE_ROLE_SQL: &str = "CREATE ROLE tablepro_client LOGIN;\n\
     GRANT CONNECT ON DATABASE tablepro TO tablepro_client;\n\
     GRANT USAGE, CREATE ON SCHEMA public TO tablepro_client;\n";

pub struct PostgresFixture {
    container: ContainerAsync<Postgres>,
    pki: TestPki,
    hba: HbaMode,
    password: String,
    host: String,
    port: u16,
    network_alias: Option<String>,
}

impl PostgresFixture {
    pub const TLS_DIR: &'static str = "/tls";
    pub const NETWORK_ROLE: &'static str = "postgres";

    pub async fn start(hba: HbaMode) -> Result<Self, FixtureError> {
        Self::launch(hba, None).await
    }

    pub async fn start_in(hba: HbaMode, network: &TestNetwork) -> Result<Self, FixtureError> {
        Self::launch(hba, Some(network)).await
    }

    async fn launch(hba: HbaMode, network: Option<&TestNetwork>) -> Result<Self, FixtureError> {
        let pki = TestPki::generate()?;
        let password = FixtureCredentials::generate_password();
        let mut request = Postgres::default()
            .with_db_name(DATABASE)
            .with_user(PASSWORD_USER)
            .with_password(&password)
            .with_name(FixtureImage::POSTGRES.name)
            .with_tag(FixtureImage::POSTGRES.tag);
        if let Some(command) = Self::server_command(hba) {
            request = request.with_cmd(command);
        }
        let network_alias = network.map(|network| network.container_name(Self::NETWORK_ROLE));
        if let (Some(network), Some(alias)) = (network, &network_alias) {
            request = request.with_network(network.name()).with_container_name(alias);
        }
        let container = with_files(request, Self::files(hba, &pki)?).start().await?;
        let host = container.get_host().await?.to_string();
        let port = container.get_host_port_ipv4(CONTAINER_PORT).await?;
        Ok(Self {
            container,
            pki,
            hba,
            password,
            host,
            port,
            network_alias,
        })
    }

    pub fn server_command(hba: HbaMode) -> Option<Vec<String>> {
        hba.pg_hba()?;
        let tls = Self::TLS_DIR;
        let script = format!(
            "install -o postgres -g postgres -m 0600 {tls}/server.key {INSTALLED_KEY} \
             && exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file={tls}/server.pem \
             -c ssl_key_file={INSTALLED_KEY} -c ssl_ca_file={tls}/ca.pem -c hba_file={tls}/pg_hba.conf"
        );
        Some(vec!["sh".to_owned(), "-c".to_owned(), script])
    }

    pub fn files(hba: HbaMode, pki: &TestPki) -> Result<Vec<ContainerFile>, FixtureError> {
        let Some(pg_hba) = hba.pg_hba() else {
            return Ok(Vec::new());
        };
        let tls = Self::TLS_DIR;
        let mut files = vec![
            ContainerFile::readable(format!("{tls}/pg_hba.conf"), pg_hba),
            ContainerFile::readable(format!("{tls}/ca.pem"), pki.read(PkiFile::Ca)?),
            ContainerFile::readable(format!("{tls}/server.pem"), pki.read(PkiFile::ServerCertificate)?),
            ContainerFile::readable(format!("{tls}/server.key"), pki.read(PkiFile::ServerKey)?),
        ];
        if hba == HbaMode::ClientCertificate {
            files.extend([
                ContainerFile::readable(format!("{tls}/client.pem"), pki.read(PkiFile::ClientCertificate)?),
                ContainerFile::readable(format!("{tls}/client.key"), pki.read(PkiFile::ClientKey)?),
                ContainerFile::readable(
                    "/docker-entrypoint-initdb.d/10-certificate-role.sql",
                    CERTIFICATE_ROLE_SQL,
                ),
            ]);
        }
        Ok(files)
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

    pub fn hba(&self) -> HbaMode {
        self.hba
    }

    pub fn pki(&self) -> &TestPki {
        &self.pki
    }

    pub fn network_alias(&self) -> Option<&str> {
        self.network_alias.as_deref()
    }

    pub fn password_credentials(&self) -> FixtureCredentials {
        FixtureCredentials::new(PASSWORD_USER, &self.password)
    }

    pub fn certificate_credentials(&self) -> Option<FixtureCredentials> {
        (self.hba == HbaMode::ClientCertificate).then(|| FixtureCredentials::new(TestPki::CLIENT_COMMON_NAME, ""))
    }

    pub fn container(&self) -> &ContainerAsync<Postgres> {
        &self.container
    }

    pub async fn exec(&self, command: &[&str]) -> Result<ExecOutput, FixtureError> {
        ExecOutput::run(&self.container, command).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn postgres_key_install_command_sets_0600_postgres_owner() {
        let command = PostgresFixture::server_command(HbaMode::ClientCertificate).unwrap();

        assert_eq!(command[..2], ["sh", "-c"]);
        assert!(command[2].starts_with("install -o postgres -g postgres -m 0600 /tls/server.key "));
        assert!(command[2].contains("-c ssl_key_file=/var/lib/postgresql/server.key"));
        assert!(command[2].contains("-c ssl_ca_file=/tls/ca.pem"));
        assert!(command[2].contains("-c hba_file=/tls/pg_hba.conf"));
        assert_eq!(PostgresFixture::server_command(HbaMode::Password), None);
    }

    #[test]
    fn only_the_client_certificate_mode_creates_the_certificate_role() {
        let pki = TestPki::generate().unwrap();
        let role_script = "/docker-entrypoint-initdb.d/10-certificate-role.sql";

        let has_role = |hba| {
            PostgresFixture::files(hba, &pki)
                .unwrap()
                .iter()
                .any(|file| file.target() == role_script)
        };

        assert!(has_role(HbaMode::ClientCertificate));
        assert!(!has_role(HbaMode::HostSslOnly));
        assert!(PostgresFixture::files(HbaMode::Password, &pki).unwrap().is_empty());
    }
}
