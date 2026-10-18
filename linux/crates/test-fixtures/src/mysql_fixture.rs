use testcontainers::core::IntoContainerPort;
use testcontainers::runners::AsyncRunner;
use testcontainers::{ContainerAsync, GenericImage, ImageExt};

use crate::container_file::with_files;
use crate::{
    ContainerFile, ExecOutput, FixtureCredentials, FixtureError, MysqlFlavour, MysqlOptions, PkiFile, TestNetwork,
    TestPki,
};

const DATABASE: &str = "tablepro";
const PASSWORD_USER: &str = "tablepro";
const ROOT_USER: &str = "root";

pub struct MysqlFixture {
    container: ContainerAsync<GenericImage>,
    options: MysqlOptions,
    pki: TestPki,
    password: String,
    root_password: String,
    certificate_password: String,
    host: String,
    port: u16,
    network_alias: Option<String>,
}

impl MysqlFixture {
    pub const TLS_DIR: &'static str = "/etc/mysql/tls";
    pub const NETWORK_ROLE: &'static str = "mysql";
    pub const CONTAINER_PORT: u16 = 3306;

    pub async fn start(flavour: MysqlFlavour) -> Result<Self, FixtureError> {
        Self::start_with(MysqlOptions::new(flavour), None).await
    }

    pub async fn start_in(flavour: MysqlFlavour, network: &TestNetwork) -> Result<Self, FixtureError> {
        Self::start_with(MysqlOptions::new(flavour), Some(network)).await
    }

    pub async fn start_with(options: MysqlOptions, network: Option<&TestNetwork>) -> Result<Self, FixtureError> {
        let pki = TestPki::generate()?;
        let password = FixtureCredentials::generate_password();
        let root_password = FixtureCredentials::generate_password();
        let certificate_password = FixtureCredentials::generate_password();
        let flavour = options.flavour;
        let prefix = flavour.environment_prefix();
        let image = flavour
            .ready_conditions()
            .into_iter()
            .fold(flavour.image().generic(), GenericImage::with_wait_for)
            .with_exposed_port(Self::CONTAINER_PORT.tcp());
        let mut request = image
            .with_env_var(format!("{prefix}_ROOT_PASSWORD"), &root_password)
            .with_env_var(format!("{prefix}_DATABASE"), DATABASE)
            .with_env_var(format!("{prefix}_USER"), PASSWORD_USER)
            .with_env_var(format!("{prefix}_PASSWORD"), &password)
            .with_cmd(Self::server_arguments(&options));
        let network_alias = network.map(|network| network.container_name(Self::NETWORK_ROLE));
        if let (Some(network), Some(alias)) = (network, &network_alias) {
            request = request.with_network(network.name()).with_container_name(alias);
        }
        let container = with_files(request, Self::files(&pki, &options, &certificate_password)?)
            .start()
            .await?;
        let host = container.get_host().await?.to_string();
        let port = container.get_host_port_ipv4(Self::CONTAINER_PORT).await?;
        Ok(Self {
            container,
            options,
            pki,
            password,
            root_password,
            certificate_password,
            host,
            port,
            network_alias,
        })
    }

    pub fn server_arguments(options: &MysqlOptions) -> Vec<String> {
        let tls = Self::TLS_DIR;
        let mut arguments = vec![
            format!("--ssl-ca={tls}/ca.pem"),
            format!("--ssl-cert={tls}/server.pem"),
            format!("--ssl-key={tls}/server.key"),
        ];
        if options.require_secure_transport {
            arguments.push("--require-secure-transport=ON".to_owned());
        }
        if options.trust_function_creators {
            arguments.push("--log-bin-trust-function-creators=ON".to_owned());
        }
        arguments.extend(options.server_arguments.iter().cloned());
        arguments
    }

    pub fn files(
        pki: &TestPki,
        options: &MysqlOptions,
        certificate_password: &str,
    ) -> Result<Vec<ContainerFile>, FixtureError> {
        let tls = Self::TLS_DIR;
        let client = TestPki::CLIENT_COMMON_NAME;
        let mut principals = String::new();
        if options.require_secure_transport {
            principals.push_str(&format!("ALTER USER '{PASSWORD_USER}'@'%' REQUIRE SSL;\n"));
        }
        principals.push_str(&format!(
            "CREATE USER '{client}'@'%' IDENTIFIED BY '{certificate_password}' REQUIRE X509;\n\
             GRANT ALL PRIVILEGES ON {DATABASE}.* TO '{client}'@'%';\n"
        ));
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
        self.options.flavour
    }

    pub fn options(&self) -> &MysqlOptions {
        &self.options
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

    pub fn network_alias(&self) -> Option<&str> {
        self.network_alias.as_deref()
    }

    pub fn password_credentials(&self) -> FixtureCredentials {
        FixtureCredentials::new(PASSWORD_USER, &self.password)
    }

    /// The image's `root@'%'`, for a test that has to change a global
    /// or watch another session's transaction.
    pub fn root_credentials(&self) -> FixtureCredentials {
        FixtureCredentials::new(ROOT_USER, &self.root_password)
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

#[cfg(test)]
mod tests {
    use super::*;

    fn principals(options: &MysqlOptions) -> String {
        let pki = TestPki::generate().unwrap();
        let files = MysqlFixture::files(&pki, options, "secret").unwrap();
        let script = files
            .iter()
            .find(|file| file.target() == "/docker-entrypoint-initdb.d/10-principals.sql")
            .unwrap();
        String::from_utf8(script.contents().to_vec()).unwrap()
    }

    #[test]
    fn the_default_server_refuses_plaintext_for_every_user() {
        let options = MysqlOptions::new(MysqlFlavour::Mysql);

        assert!(MysqlFixture::server_arguments(&options).contains(&"--require-secure-transport=ON".to_owned()));
        assert!(principals(&options).contains("ALTER USER 'tablepro'@'%' REQUIRE SSL;"));
    }

    #[test]
    fn allowing_plaintext_lifts_both_tls_requirements_but_keeps_x509() {
        let options = MysqlOptions::new(MysqlFlavour::Mariadb).allowing_plaintext();
        let script = principals(&options);

        assert!(
            !MysqlFixture::server_arguments(&options)
                .iter()
                .any(|argument| argument.starts_with("--require-secure-transport"))
        );
        assert!(!script.contains("REQUIRE SSL"));
        assert!(script.contains("REQUIRE X509"));
    }

    #[test]
    fn only_a_trusting_server_lets_the_password_user_create_routines() {
        let trusting = "--log-bin-trust-function-creators=ON".to_owned();

        assert!(!MysqlFixture::server_arguments(&MysqlOptions::new(MysqlFlavour::Mysql)).contains(&trusting));
        assert!(
            MysqlFixture::server_arguments(&MysqlOptions::new(MysqlFlavour::Mariadb).trusting_function_creators())
                .contains(&trusting)
        );
    }

    #[test]
    fn extra_server_arguments_come_after_the_tls_arguments() {
        let options = MysqlOptions::new(MysqlFlavour::Mysql).with_server_argument("--sql-mode=NO_BACKSLASH_ESCAPES");
        let arguments = MysqlFixture::server_arguments(&options);

        assert_eq!(
            arguments.first().map(String::as_str),
            Some("--ssl-ca=/etc/mysql/tls/ca.pem")
        );
        assert_eq!(
            arguments.last().map(String::as_str),
            Some("--sql-mode=NO_BACKSLASH_ESCAPES")
        );
    }
}
