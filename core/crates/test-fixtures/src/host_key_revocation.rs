use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use crate::host_command::run_host_command;
use crate::{FixtureError, OpenSshFixture};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostKeyRevocation {
    krl: PathBuf,
    host_public_key: PathBuf,
}

impl HostKeyRevocation {
    pub async fn revoke_host_key(fixture: &OpenSshFixture, dir: &Path) -> Result<Self, FixtureError> {
        let host_public_key = dir.join("revoked_host_key.pub");
        tokio::fs::write(&host_public_key, format!("{}\n", fixture.host_public_key().await?)).await?;
        let krl = dir.join("revoked.krl");
        let arguments: [&OsStr; 4] = [
            "-k".as_ref(),
            "-f".as_ref(),
            krl.as_os_str(),
            host_public_key.as_os_str(),
        ];
        run_host_command("ssh-keygen", arguments).await?;
        Ok(Self { krl, host_public_key })
    }

    pub fn krl(&self) -> &Path {
        &self.krl
    }

    pub fn host_public_key(&self) -> &Path {
        &self.host_public_key
    }
}
