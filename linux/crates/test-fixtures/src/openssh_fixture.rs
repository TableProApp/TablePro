use std::time::Duration;

use testcontainers::core::{IntoContainerPort, WaitFor};
use testcontainers::runners::AsyncRunner;
use testcontainers::{ContainerAsync, GenericImage, ImageExt};
use tokio::io::AsyncReadExt;
use tokio::net::TcpStream;
use tokio::time::Instant;
use uuid::Uuid;

use crate::container_file::with_files;
use crate::{
    ContainerFile, ExecOutput, FixtureCredentials, FixtureError, HostCertificate, OpenSshOptions, OpenSshVersion,
    ServerVersion, SshAuthVariant, TestNetwork,
};

const USERNAME: &str = "tablepro";
const BANNER_TIMEOUT: Duration = Duration::from_secs(60);
const BANNER_ATTEMPT: Duration = Duration::from_secs(2);
const BANNER_RETRY: Duration = Duration::from_millis(250);

pub struct OpenSshFixture {
    container: ContainerAsync<GenericImage>,
    variant: SshAuthVariant,
    version: OpenSshVersion,
    host_certificate: Option<HostCertificate>,
    password: String,
    host: String,
    port: u16,
    network_alias: Option<String>,
}

impl OpenSshFixture {
    pub const DROP_IN: &'static str = "/config/sshd/sshd_config.d/tablepro.conf";
    pub const SSHD_CONFIG: &'static str = "/config/sshd/sshd_config";
    pub const CONTAINER_PORT: u16 = 2222;

    pub async fn start(variant: SshAuthVariant) -> Result<Self, FixtureError> {
        Self::start_with(variant, OpenSshOptions::selected()?, None).await
    }

    /// Start a server that reaches the network's other containers by
    /// alias. Each server gets its own alias, so a two-hop chain can put
    /// two of them on one network.
    pub async fn start_in(variant: SshAuthVariant, network: &TestNetwork) -> Result<Self, FixtureError> {
        Self::start_with(variant, OpenSshOptions::selected()?, Some(network)).await
    }

    pub async fn start_with(
        variant: SshAuthVariant,
        options: OpenSshOptions,
        network: Option<&TestNetwork>,
    ) -> Result<Self, FixtureError> {
        let password = FixtureCredentials::generate_password();
        let host_certificate = match variant {
            SshAuthVariant::HostCertificate => Some(HostCertificate::generate().await?),
            SshAuthVariant::Password | SshAuthVariant::PublicKey(_) | SshAuthVariant::KeyboardInteractive => None,
        };
        let mut request = options
            .version
            .image()
            .generic()
            .with_exposed_port(Self::CONTAINER_PORT.tcp())
            .with_wait_for(WaitFor::message_on_stdout("[ls.io-init] done."))
            .with_env_var("USER_NAME", USERNAME)
            .with_env_var("USER_PASSWORD", &password)
            .with_env_var(
                "PASSWORD_ACCESS",
                if variant.password_access() { "true" } else { "false" },
            );
        if let SshAuthVariant::PublicKey(key) = &variant {
            request = request.with_env_var("PUBLIC_KEY", key.public_key());
        }
        let mut files = vec![ContainerFile::readable(
            Self::DROP_IN,
            Self::drop_in(&variant, &options),
        )];
        if let Some(certificate) = &host_certificate {
            files.extend(certificate.files()?);
        }
        let network_alias = network.map(|network| {
            let suffix = Uuid::new_v4().simple().to_string();
            network.container_name(&format!("sshd-{}", &suffix[..8]))
        });
        if let (Some(network), Some(alias)) = (network, &network_alias) {
            request = request.with_network(network.name()).with_container_name(alias);
        }
        let container = with_files(request, files).start().await?;
        let host = container.get_host().await?.to_string();
        let port = container.get_host_port_ipv4(Self::CONTAINER_PORT).await?;
        wait_for_banner(&host, port).await?;
        Ok(Self {
            container,
            variant,
            version: options.version,
            host_certificate,
            password,
            host,
            port,
            network_alias,
        })
    }

    pub fn drop_in(variant: &SshAuthVariant, options: &OpenSshOptions) -> String {
        // Every connection comes from one Docker gateway address, so a test's
        // refused login must not lock out the next one.
        let mut configuration = String::from("AllowTcpForwarding yes\nPerSourcePenalties no\n");
        match variant {
            SshAuthVariant::KeyboardInteractive => configuration.push_str(
                "UsePAM yes\n\
                 KbdInteractiveAuthentication yes\n\
                 PasswordAuthentication no\n\
                 AuthenticationMethods keyboard-interactive\n",
            ),
            SshAuthVariant::HostCertificate => {
                configuration.push_str(&format!("HostCertificate {}\n", HostCertificate::CERTIFICATE));
            }
            SshAuthVariant::Password | SshAuthVariant::PublicKey(_) => {}
        }
        configuration.push_str(&options.sshd_lines());
        configuration
    }

    pub fn host(&self) -> &str {
        &self.host
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn network_alias(&self) -> Option<&str> {
        self.network_alias.as_deref()
    }

    pub fn variant(&self) -> &SshAuthVariant {
        &self.variant
    }

    pub fn version(&self) -> OpenSshVersion {
        self.version
    }

    pub fn host_certificate(&self) -> Option<&HostCertificate> {
        self.host_certificate.as_ref()
    }

    pub fn password_credentials(&self) -> FixtureCredentials {
        FixtureCredentials::new(USERNAME, &self.password)
    }

    pub async fn host_public_key(&self) -> Result<String, FixtureError> {
        let output = self.exec(&["cat", HostCertificate::HOST_PUBLIC_KEY]).await?;
        Ok(output.stdout_text().trim().to_owned())
    }

    pub fn container(&self) -> &ContainerAsync<GenericImage> {
        &self.container
    }

    pub async fn exec(&self, command: &[&str]) -> Result<ExecOutput, FixtureError> {
        ExecOutput::run(&self.container, command).await
    }
}

async fn wait_for_banner(host: &str, port: u16) -> Result<(), FixtureError> {
    let deadline = Instant::now() + BANNER_TIMEOUT;
    while Instant::now() < deadline {
        if banner_received(host, port).await {
            return Ok(());
        }
        tokio::time::sleep(BANNER_RETRY).await;
    }
    Err(FixtureError::NotReady {
        service: "sshd",
        seconds: BANNER_TIMEOUT.as_secs(),
    })
}

async fn banner_received(host: &str, port: u16) -> bool {
    let attempt = async {
        let mut stream = TcpStream::connect((host, port)).await?;
        let mut prefix = [0_u8; 4];
        stream.read_exact(&mut prefix).await?;
        Ok::<bool, std::io::Error>(&prefix == b"SSH-")
    };
    matches!(tokio::time::timeout(BANNER_ATTEMPT, attempt).await, Ok(Ok(true)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_variant_enables_tcp_forwarding_first_and_the_options_last() {
        for variant in [
            SshAuthVariant::Password,
            SshAuthVariant::KeyboardInteractive,
            SshAuthVariant::HostCertificate,
        ] {
            let drop_in = OpenSshFixture::drop_in(&variant, &OpenSshOptions::default().with_max_auth_tries(3));
            assert!(drop_in.starts_with("AllowTcpForwarding yes\n"), "{drop_in}");
            assert!(drop_in.ends_with("MaxAuthTries 3\n"), "{drop_in}");
        }
    }

    #[test]
    fn keyboard_interactive_turns_off_password_authentication() {
        let drop_in = OpenSshFixture::drop_in(&SshAuthVariant::KeyboardInteractive, &OpenSshOptions::default());

        assert!(drop_in.contains("UsePAM yes\n"));
        assert!(drop_in.contains("PasswordAuthentication no\n"));
        assert!(drop_in.contains("AuthenticationMethods keyboard-interactive\n"));
        assert!(SshAuthVariant::KeyboardInteractive.password_access());
    }

    #[test]
    fn host_certificate_script_signs_the_ed25519_host_key() {
        let script = HostCertificate::init_script();

        assert!(script.contains(
            "ssh-keygen -q -s /tablepro/host_ca -h -I tablepro-test-host -n localhost,127.0.0.1 \
             /config/ssh_host_keys/ssh_host_ed25519_key.pub"
        ));
        assert!(
            OpenSshFixture::drop_in(&SshAuthVariant::HostCertificate, &OpenSshOptions::default())
                .contains(HostCertificate::CERTIFICATE)
        );
    }
}
