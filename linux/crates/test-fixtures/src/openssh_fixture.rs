use std::time::Duration;

use testcontainers::core::{IntoContainerPort, WaitFor};
use testcontainers::runners::AsyncRunner;
use testcontainers::{ContainerAsync, GenericImage, ImageExt};
use tokio::io::AsyncReadExt;
use tokio::net::TcpStream;
use tokio::time::Instant;

use crate::container_file::with_files;
use crate::{
    ContainerFile, ExecOutput, FixtureCredentials, FixtureError, FixtureImage, HostCertificate, SshAuthVariant,
};

const CONTAINER_PORT: u16 = 2222;
const USERNAME: &str = "tablepro";
const BANNER_TIMEOUT: Duration = Duration::from_secs(60);
const BANNER_ATTEMPT: Duration = Duration::from_secs(2);
const BANNER_RETRY: Duration = Duration::from_millis(250);

pub struct OpenSshFixture {
    container: ContainerAsync<GenericImage>,
    variant: SshAuthVariant,
    host_certificate: Option<HostCertificate>,
    password: String,
    host: String,
    port: u16,
}

impl OpenSshFixture {
    pub const DROP_IN: &'static str = "/config/sshd/sshd_config.d/tablepro.conf";
    pub const SSHD_CONFIG: &'static str = "/config/sshd/sshd_config";

    pub async fn start(variant: SshAuthVariant) -> Result<Self, FixtureError> {
        let password = FixtureCredentials::generate_password();
        let host_certificate = match variant {
            SshAuthVariant::HostCertificate => Some(HostCertificate::generate().await?),
            SshAuthVariant::Password | SshAuthVariant::PublicKey(_) | SshAuthVariant::KeyboardInteractive => None,
        };
        let mut request = FixtureImage::OPENSSH
            .generic()
            .with_exposed_port(CONTAINER_PORT.tcp())
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
        let mut files = vec![ContainerFile::readable(Self::DROP_IN, Self::drop_in(&variant))];
        if let Some(certificate) = &host_certificate {
            files.extend(certificate.files()?);
        }
        let container = with_files(request, files).start().await?;
        let host = container.get_host().await?.to_string();
        let port = container.get_host_port_ipv4(CONTAINER_PORT).await?;
        wait_for_banner(&host, port).await?;
        Ok(Self {
            container,
            variant,
            host_certificate,
            password,
            host,
            port,
        })
    }

    pub fn drop_in(variant: &SshAuthVariant) -> String {
        let mut configuration = String::from("AllowTcpForwarding yes\n");
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
        configuration
    }

    pub fn host(&self) -> &str {
        &self.host
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn variant(&self) -> &SshAuthVariant {
        &self.variant
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
    fn every_variant_enables_tcp_forwarding_first() {
        for variant in [
            SshAuthVariant::Password,
            SshAuthVariant::KeyboardInteractive,
            SshAuthVariant::HostCertificate,
        ] {
            assert!(OpenSshFixture::drop_in(&variant).starts_with("AllowTcpForwarding yes\n"));
        }
    }

    #[test]
    fn keyboard_interactive_turns_off_password_authentication() {
        let drop_in = OpenSshFixture::drop_in(&SshAuthVariant::KeyboardInteractive);

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
        assert!(OpenSshFixture::drop_in(&SshAuthVariant::HostCertificate).contains(HostCertificate::CERTIFICATE));
    }
}
