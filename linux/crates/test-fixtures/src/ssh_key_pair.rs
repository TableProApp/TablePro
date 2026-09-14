use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use tempfile::TempDir;

use crate::FixtureError;
use crate::host_command::run_host_command;

#[derive(Debug)]
pub struct SshKeyPair {
    _dir: TempDir,
    private_key: PathBuf,
    public_key: String,
}

impl SshKeyPair {
    pub async fn generate(comment: &str) -> Result<Self, FixtureError> {
        let dir = tempfile::tempdir()?;
        let private_key = dir.path().join("id_ed25519");
        let arguments: [&OsStr; 9] = [
            "-q".as_ref(),
            "-t".as_ref(),
            "ed25519".as_ref(),
            "-N".as_ref(),
            "".as_ref(),
            "-C".as_ref(),
            comment.as_ref(),
            "-f".as_ref(),
            private_key.as_os_str(),
        ];
        run_host_command("ssh-keygen", arguments).await?;
        let public_key = tokio::fs::read_to_string(private_key.with_extension("pub"))
            .await?
            .trim()
            .to_owned();
        Ok(Self {
            _dir: dir,
            private_key,
            public_key,
        })
    }

    pub fn private_key(&self) -> &Path {
        &self.private_key
    }

    pub fn public_key(&self) -> &str {
        &self.public_key
    }
}
