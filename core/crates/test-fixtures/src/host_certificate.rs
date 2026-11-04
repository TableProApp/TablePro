use crate::{ContainerFile, FixtureError, SshKeyPair};

pub struct HostCertificate {
    ca: SshKeyPair,
}

impl HostCertificate {
    pub const IDENTITY: &'static str = "tablepro-test-host";
    pub const PRINCIPALS: &'static str = "localhost,127.0.0.1";
    pub const HOST_PUBLIC_KEY: &'static str = "/config/ssh_host_keys/ssh_host_ed25519_key.pub";
    pub const CERTIFICATE: &'static str = "/config/ssh_host_keys/ssh_host_ed25519_key-cert.pub";
    const CONTAINER_CA_KEY: &'static str = "/tablepro/host_ca";
    const INIT_SCRIPT: &'static str = "/custom-cont-init.d/10-host-certificate";

    pub async fn generate() -> Result<Self, FixtureError> {
        Ok(Self {
            ca: SshKeyPair::generate("tablepro-test-host-ca").await?,
        })
    }

    pub fn ca_public_key(&self) -> &str {
        self.ca.public_key()
    }

    pub fn known_hosts_line(&self, host: &str, port: u16) -> String {
        format!("@cert-authority [{host}]:{port} {}\n", self.ca.public_key())
    }

    pub fn init_script() -> String {
        format!(
            "#!/usr/bin/with-contenv bash\n\
             set -e\n\
             ssh-keygen -q -s {} -h -I {} -n {} {}\n\
             chown \"${{USER_NAME}}\" {}\n",
            Self::CONTAINER_CA_KEY,
            Self::IDENTITY,
            Self::PRINCIPALS,
            Self::HOST_PUBLIC_KEY,
            Self::CERTIFICATE,
        )
    }

    pub fn files(&self) -> Result<Vec<ContainerFile>, FixtureError> {
        Ok(vec![
            ContainerFile::private(Self::CONTAINER_CA_KEY, std::fs::read(self.ca.private_key())?),
            ContainerFile::executable(Self::INIT_SCRIPT, Self::init_script()),
        ])
    }
}
