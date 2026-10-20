use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use tempfile::TempDir;

use crate::host_command::run_host_command;
use crate::{FixtureError, SshKeyType};

#[derive(Debug)]
pub struct SshKeyPair {
    _dir: TempDir,
    key_type: SshKeyType,
    private_key: PathBuf,
    public_key: String,
    passphrase: Option<String>,
}

impl SshKeyPair {
    /// An ed25519 key with no passphrase.
    pub async fn generate(comment: &str) -> Result<Self, FixtureError> {
        Self::generate_with(SshKeyType::Ed25519, None, comment).await
    }

    /// A key of `key_type`, its private half encrypted with `passphrase`
    /// when there is one.
    pub async fn generate_with(
        key_type: SshKeyType,
        passphrase: Option<&str>,
        comment: &str,
    ) -> Result<Self, FixtureError> {
        let dir = tempfile::tempdir()?;
        let private_key = dir.path().join(key_type.file_name());
        let mut arguments: Vec<&OsStr> = vec![OsStr::new("-q")];
        arguments.extend(key_type.keygen_arguments().iter().map(OsStr::new));
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
            key_type,
            private_key,
            public_key,
            passphrase: passphrase.map(str::to_owned),
        })
    }

    pub fn key_type(&self) -> SshKeyType {
        self.key_type
    }

    pub fn private_key(&self) -> &Path {
        &self.private_key
    }

    pub fn public_key(&self) -> &str {
        &self.public_key
    }

    pub fn passphrase(&self) -> Option<&str> {
        self.passphrase.as_deref()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn each_key_type_writes_its_own_public_key_line() {
        for key_type in SshKeyType::ALL {
            let key = SshKeyPair::generate_with(key_type, None, "tablepro-key-test")
                .await
                .unwrap();

            assert!(
                key.public_key()
                    .starts_with(&format!("{} ", key_type.public_key_type())),
                "{key_type:?}: {}",
                key.public_key()
            );
            assert!(key.public_key().ends_with(" tablepro-key-test"));
            assert_eq!(key.key_type(), key_type);
        }
    }

    /// `ssh-keygen -y` derives the public key from the private one, and
    /// with `-P ''` it fails on a key that needs a passphrase.
    #[tokio::test]
    async fn a_passphrase_encrypts_the_private_key() {
        let derive = |key: &SshKeyPair, passphrase: &str| {
            std::process::Command::new("ssh-keygen")
                .args(["-y", "-P", passphrase, "-f"])
                .arg(key.private_key())
                .output()
                .unwrap()
        };
        let plain = SshKeyPair::generate("tablepro-key-test").await.unwrap();
        let encrypted = SshKeyPair::generate_with(SshKeyType::EcdsaP256, Some("open sesame"), "tablepro-key-test")
            .await
            .unwrap();

        assert!(derive(&plain, "").status.success());
        assert!(!derive(&encrypted, "").status.success());
        let unlocked = derive(&encrypted, "open sesame");
        assert!(unlocked.status.success());
        assert!(
            encrypted
                .public_key()
                .starts_with(String::from_utf8_lossy(&unlocked.stdout).trim())
        );
        assert_eq!(encrypted.passphrase(), Some("open sesame"));
        assert_eq!(plain.passphrase(), None);
    }
}
