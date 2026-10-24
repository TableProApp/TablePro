use std::time::Duration;

use testcontainers::core::{IntoContainerPort, WaitFor};
use testcontainers::{ContainerAsync, ContainerRequest, GenericImage, ImageExt};

use crate::container_file::with_files;
use crate::container_start::start_container;
use crate::{
    ContainerFile, ExecOutput, FixtureCredentials, FixtureError, MongoVersion, PkiFile, ServerVersion, TestNetwork,
    TestPki,
};

const PORT: u16 = MongoFixture::PORT;
const CERTIFICATE_PORT: u16 = MongoFixture::CERTIFICATE_PORT;
const USER: &str = "tablepro";
const CONFIG_DIR: &str = "/etc/tablepro";
const READY_TIMEOUT: Duration = Duration::from_secs(120);
/// What the start script prints once the set has a primary and the root
/// user exists.
const READY: &str = "tablepro: ready";

/// The container's command. It starts the member, and on a TLS fixture
/// the certificate-only server beside it, initiates the set through the
/// localhost exception, waits for the member to be primary, then makes
/// the root user, which ends the exception. Done here rather than through
/// `docker exec`, whose result a `Send` future cannot await.
const START_SCRIPT: &str = r#"set -e
cp /etc/tablepro/keyfile /tmp/keyfile
chmod 400 /tmp/keyfile
TLS="--tlsCertificateKeyFile /etc/tablepro/server.pem --tlsCAFile /etc/tablepro/ca.pem"
MEMBER_TLS=""
SHELL_TLS=""
if [ "$TABLEPRO_TLS" = 1 ]; then
    mkdir -p /tmp/certificate-db
    mongod --port 27018 --bind_ip_all --dbpath /tmp/certificate-db --tlsMode requireTLS $TLS         --fork --logpath /tmp/certificate.log
    MEMBER_TLS="--tlsMode requireTLS $TLS --tlsAllowConnectionsWithoutCertificates"
    SHELL_TLS="--tls --tlsCAFile /etc/tablepro/ca.pem"
fi
mongod --replSet rs0 --bind_ip_all --port 27017 --keyFile /tmp/keyfile $MEMBER_TLS &
member=$!
ask() {
    mongosh --quiet --host localhost --port 27017 $SHELL_TLS --eval "$1"
}
until [ "$(ask 'db.runCommand({ping: 1}).ok' 2> /dev/null)" = 1 ]; do sleep 0.5; done
ask "rs.initiate({_id: 'rs0', members: [{_id: 0, host: 'localhost:27017'}]}).ok"
until [ "$(ask 'db.hello().isWritablePrimary' 2> /dev/null)" = true ]; do sleep 0.5; done
ask "db.getSiblingDB('admin').createUser({user: 'tablepro', pwd: process.env.TABLEPRO_PASSWORD, roles: ['root']}).ok"
echo "tablepro: ready"
wait "$member"
"#;

/// How the fixture's server takes connections.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Listening {
    Plain,
    /// TLS only on `PORT`, where a client certificate is optional, and on
    /// `CERTIFICATE_PORT` a second server, with no login, that takes only
    /// a client that presents one.
    Tls,
}

/// A one-member replica set, `rs0`, with access control on and a user,
/// `tablepro`, who holds the root role.
///
/// The member is named `localhost:27017` inside the container, which the
/// tests never reach by that name: they connect to the one host they are
/// given, as a direct connection does.
pub struct MongoFixture {
    container: ContainerAsync<GenericImage>,
    pki: TestPki,
    password: String,
    host: String,
    port: u16,
    certificate_port: Option<u16>,
    network_alias: Option<String>,
    version: MongoVersion,
    listening: Listening,
}

impl MongoFixture {
    pub const PORT: u16 = 27017;
    pub const CERTIFICATE_PORT: u16 = 27018;
    pub const NETWORK_ROLE: &'static str = "mongodb";

    pub async fn start() -> Result<Self, FixtureError> {
        Self::launch(None, Listening::Plain).await
    }

    pub async fn start_in(network: &TestNetwork) -> Result<Self, FixtureError> {
        Self::launch(Some(network), Listening::Plain).await
    }

    /// A replica set that takes only TLS, with a server beside it that
    /// takes only clients that present a certificate the CA issued.
    pub async fn start_tls() -> Result<Self, FixtureError> {
        Self::launch(None, Listening::Tls).await
    }

    async fn launch(network: Option<&TestNetwork>, listening: Listening) -> Result<Self, FixtureError> {
        let pki = TestPki::generate()?;
        let password = FixtureCredentials::generate_password();
        let version = MongoVersion::selected()?;
        let mut request: ContainerRequest<GenericImage> = version
            .image()
            .generic()
            .with_wait_for(WaitFor::message_on_stdout(READY))
            .with_exposed_port(PORT.tcp())
            .with_exposed_port(CERTIFICATE_PORT.tcp())
            .with_entrypoint("sh")
            .with_cmd([format!("{CONFIG_DIR}/start.sh")])
            .with_env_var("TABLEPRO_PASSWORD", &password)
            .with_env_var("TABLEPRO_TLS", if listening == Listening::Tls { "1" } else { "0" })
            .with_startup_timeout(READY_TIMEOUT);
        let network_alias = network.map(|network| network.container_name(Self::NETWORK_ROLE));
        if let (Some(network), Some(alias)) = (network, &network_alias) {
            request = request.with_network(network.name()).with_container_name(alias);
        }
        let container = start_container(with_files(request, Self::files(&pki)?)).await?;
        let host = container.get_host().await?.to_string();
        let port = container.get_host_port_ipv4(PORT).await?;
        let certificate_port = match listening {
            Listening::Plain => None,
            Listening::Tls => Some(container.get_host_port_ipv4(CERTIFICATE_PORT).await?),
        };
        Ok(Self {
            container,
            pki,
            password,
            host,
            port,
            certificate_port,
            network_alias,
            version,
            listening,
        })
    }

    /// The key the members of the set share, and the PKI the TLS servers
    /// read. The server's certificate and key go in one file, as mongod
    /// takes them.
    pub fn files(pki: &TestPki) -> Result<Vec<ContainerFile>, FixtureError> {
        let mut server = pki.read(PkiFile::ServerCertificate)?;
        if !server.ends_with(b"\n") {
            server.push(b'\n');
        }
        server.extend(pki.read(PkiFile::ServerKey)?);
        Ok(vec![
            ContainerFile::private(
                format!("{CONFIG_DIR}/keyfile"),
                uuid::Uuid::new_v4().simple().to_string(),
            ),
            ContainerFile::readable(format!("{CONFIG_DIR}/ca.pem"), pki.read(PkiFile::Ca)?),
            ContainerFile::readable(format!("{CONFIG_DIR}/server.pem"), server),
            ContainerFile::readable(format!("{CONFIG_DIR}/start.sh"), START_SCRIPT),
        ])
    }

    pub fn host(&self) -> &str {
        &self.host
    }

    /// The port of the replica set's member.
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

    pub fn version(&self) -> MongoVersion {
        self.version
    }

    pub fn pki(&self) -> &TestPki {
        &self.pki
    }

    /// The root user, defined in `admin`.
    pub fn password_credentials(&self) -> FixtureCredentials {
        FixtureCredentials::new(USER, &self.password)
    }

    pub fn container(&self) -> &ContainerAsync<GenericImage> {
        &self.container
    }

    pub async fn exec(&self, command: &[&str]) -> Result<ExecOutput, FixtureError> {
        ExecOutput::run(&self.container, command).await
    }

    /// Evaluate shell text with mongosh inside the container, as the root
    /// user once there is one.
    pub async fn shell(&self, script: &str) -> Result<ExecOutput, FixtureError> {
        let mut command = vec!["mongosh", "--quiet", "--host", "localhost", "--port", "27017"];
        let ca = format!("{CONFIG_DIR}/ca.pem");
        if self.listening == Listening::Tls {
            command.extend(["--tls", "--tlsCAFile", &ca]);
        }
        command.extend([
            "-u",
            USER,
            "-p",
            &self.password,
            "--authenticationDatabase",
            "admin",
            "--eval",
            script,
        ]);
        self.exec(&command).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_server_reads_its_certificate_and_key_from_one_file() {
        let pki = TestPki::generate().unwrap();
        let files = MongoFixture::files(&pki).unwrap();

        let server = files.iter().find(|file| file.target().ends_with("server.pem")).unwrap();
        let text = String::from_utf8_lossy(server.contents());
        assert!(
            text.contains("BEGIN CERTIFICATE") && text.contains("PRIVATE KEY"),
            "{text}"
        );
        let key = files.iter().find(|file| file.target().ends_with("keyfile")).unwrap();
        assert_eq!(key.mode(), ContainerFile::PRIVATE);
    }

    #[test]
    fn the_start_script_makes_the_user_only_once_the_set_has_a_primary() {
        let primary = START_SCRIPT.find("isWritablePrimary").unwrap();
        let user = START_SCRIPT.find("createUser").unwrap();
        let ready = START_SCRIPT.find(READY).unwrap();

        assert!(primary < user && user < ready, "{START_SCRIPT}");
        assert!(START_SCRIPT.contains("--port 27018") && START_SCRIPT.contains("--fork"));
    }
}
