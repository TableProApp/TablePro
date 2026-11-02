use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use tempfile::TempDir;

use crate::host_command::run_host_command;
use crate::{FixtureError, SshKeyType};

#[derive(Debug)]
pub struct SshKeyPair {
    _dir: TempDir,
    kind: SshKeyType,
    private_key: PathBuf,
    public_key: String,
    passphrase: Option<String>,
}

impl SshKeyPair {
    pub async fn generate(comment: &str) -> Result<Self, FixtureError> {
        Self::generate_with(SshKeyType::Ed25519, None, comment).await
    }

    pub async fn generate_with(
        kind: SshKeyType,
        passphrase: Option<&str>,
        comment: &str,
    ) -> Result<Self, FixtureError> {
        let dir = tempfile::tempdir()?;
        let private_key = dir.path().join(kind.file_name());
        let mut arguments = vec![OsStr::new("-q")];
        arguments.extend(kind.keygen_arguments().iter().map(OsStr::new));
        arguments.extend([
            OsStr::new("-N"),
            OsStr::new(passphrase.unwrap_or_default()),
            OsStr::new("-C"),
            OsStr::new(comment),
            OsStr::new("-f"),
            private_key.as_os_str(),
        ]);
        run_host_command("ssh-keygen", arguments).await?;
        let public_key = tokio::fs::read_to_string(private_key.with_extension("pub"))
            .await?
            .trim()
            .to_owned();
        Ok(Self {
            _dir: dir,
            kind,
            private_key,
            public_key,
            passphrase: passphrase.map(str::to_owned),
        })
    }

    pub fn kind(&self) -> SshKeyType {
        self.kind
    }

    pub fn private_key(&self) -> &Path {
        &self.private_key
    }

    pub fn public_key(&self) -> &str {
        &self.public_key
    }

    pub fn public_key_file(&self) -> PathBuf {
        self.private_key.with_extension("pub")
    }

    pub fn passphrase(&self) -> Option<&str> {
        self.passphrase.as_deref()
    }
}

#[cfg(test)]
mod tests {
    use std::process::Command;

    use super::*;

    fn opens_with(key: &SshKeyPair, passphrase: &str) -> bool {
        Command::new("ssh-keygen")
            .arg("-y")
            .arg("-P")
            .arg(passphrase)
            .arg("-f")
            .arg(key.private_key())
            .output()
            .unwrap()
            .status
            .success()
    }

    #[tokio::test]
    async fn each_key_type_writes_its_algorithm() {
        for kind in SshKeyType::ALL {
            let key = SshKeyPair::generate_with(kind, None, "tablepro-key-type")
                .await
                .unwrap();

            assert_eq!(key.kind(), kind);
            assert!(
                key.public_key()
                    .starts_with(&format!("{} ", kind.public_key_algorithm())),
                "{kind:?}: {}",
                key.public_key()
            );
            assert_eq!(
                std::fs::read_to_string(key.public_key_file()).unwrap().trim(),
                key.public_key()
            );
            assert!(opens_with(&key, ""), "{kind:?}");
        }
    }

    #[tokio::test]
    async fn a_passphrase_key_opens_only_with_its_passphrase() {
        for kind in SshKeyType::ALL {
            let key = SshKeyPair::generate_with(kind, Some("correct horse"), "tablepro-passphrase")
                .await
                .unwrap();

            assert_eq!(key.passphrase(), Some("correct horse"));
            assert!(opens_with(&key, "correct horse"), "{kind:?}");
            assert!(!opens_with(&key, ""), "{kind:?}");
        }
    }
}
