use crate::{FixtureError, OpenSshVersion, ServerVersion};

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct OpenSshOptions {
    pub version: OpenSshVersion,
    pub kex_algorithms: Option<String>,
    pub max_auth_tries: Option<u32>,
    pub pubkey_accepted_algorithms: Option<String>,
}

impl OpenSshOptions {
    pub const POST_QUANTUM_KEX: &'static str = "mlkem768x25519-sha256,sntrup761x25519-sha512";

    pub fn selected() -> Result<Self, FixtureError> {
        Ok(Self::default().with_version(OpenSshVersion::selected()?))
    }

    pub fn with_version(self, version: OpenSshVersion) -> Self {
        Self { version, ..self }
    }

    pub fn with_kex_algorithms(self, algorithms: impl Into<String>) -> Self {
        Self {
            kex_algorithms: Some(algorithms.into()),
            ..self
        }
    }

    pub fn with_max_auth_tries(self, tries: u32) -> Self {
        Self {
            max_auth_tries: Some(tries),
            ..self
        }
    }

    pub fn with_pubkey_accepted_algorithms(self, algorithms: impl Into<String>) -> Self {
        Self {
            pubkey_accepted_algorithms: Some(algorithms.into()),
            ..self
        }
    }

    pub(crate) fn sshd_lines(&self) -> String {
        let mut lines = String::new();
        if let Some(algorithms) = &self.kex_algorithms {
            lines.push_str(&format!("KexAlgorithms {algorithms}\n"));
        }
        if let Some(tries) = self.max_auth_tries {
            lines.push_str(&format!("MaxAuthTries {tries}\n"));
        }
        if let Some(algorithms) = &self.pubkey_accepted_algorithms {
            lines.push_str(&format!("PubkeyAcceptedAlgorithms {algorithms}\n"));
        }
        lines
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_option_renders_its_sshd_line() {
        let options = OpenSshOptions::default()
            .with_kex_algorithms(OpenSshOptions::POST_QUANTUM_KEX)
            .with_max_auth_tries(3)
            .with_pubkey_accepted_algorithms("rsa-sha2-256");

        assert_eq!(
            options.sshd_lines(),
            "KexAlgorithms mlkem768x25519-sha256,sntrup761x25519-sha512\n\
             MaxAuthTries 3\n\
             PubkeyAcceptedAlgorithms rsa-sha2-256\n"
        );
    }

    #[test]
    fn an_unset_option_renders_nothing() {
        assert_eq!(OpenSshOptions::default().sshd_lines(), "");
        assert_eq!(
            OpenSshOptions::default().with_max_auth_tries(3).sshd_lines(),
            "MaxAuthTries 3\n"
        );
    }
}
