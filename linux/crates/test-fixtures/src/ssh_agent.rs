use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::Duration;

use tempfile::TempDir;
use tokio::time::Instant;

use crate::host_command::run_host_command_with_env;
use crate::{FixtureError, SshKeyPair};

const SOCKET_TIMEOUT: Duration = Duration::from_secs(10);
const SOCKET_RETRY: Duration = Duration::from_millis(20);

/// A private `ssh-agent` on the host, for tests of agent authentication
/// that must not touch the developer's own agent.
///
/// It runs in the foreground and is killed when this is dropped, so a
/// failed test leaves no agent behind.
pub struct SshAgent {
    process: Child,
    socket: PathBuf,
    _dir: TempDir,
}

impl SshAgent {
    pub async fn start() -> Result<Self, FixtureError> {
        let dir = tempfile::tempdir()?;
        let socket = dir.path().join("agent.sock");
        let process = Command::new("ssh-agent")
            .arg("-D")
            .arg("-a")
            .arg(&socket)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
        let agent = Self {
            process,
            socket,
            _dir: dir,
        };
        agent.wait_for_socket().await?;
        Ok(agent)
    }

    /// What `SSH_AUTH_SOCK` points at for a client of this agent.
    pub fn socket(&self) -> &Path {
        &self.socket
    }

    /// Load a key, and its `-cert.pub` certificate when one sits beside
    /// it, the way `ssh-add` does.
    pub async fn add(&self, key: &SshKeyPair) -> Result<(), FixtureError> {
        self.ssh_add([key.private_key().as_os_str()]).await.map(drop)
    }

    /// The public keys the agent holds, one OpenSSH line each.
    pub async fn identities(&self) -> Result<Vec<String>, FixtureError> {
        let output = tokio::process::Command::new("ssh-add")
            .arg("-L")
            .env("SSH_AUTH_SOCK", &self.socket)
            .stdin(Stdio::null())
            .output()
            .await?;
        match output.status.code() {
            Some(0) => Ok(String::from_utf8_lossy(&output.stdout)
                .lines()
                .map(str::to_owned)
                .collect()),
            // ssh-add -L exits 1 for an agent with no keys, which is an
            // answer rather than a failure.
            Some(1) => Ok(Vec::new()),
            _ => Err(FixtureError::HostCommand {
                program: "ssh-add",
                status: output.status,
                stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
            }),
        }
    }

    async fn ssh_add<'a>(&self, arguments: impl IntoIterator<Item = &'a OsStr>) -> Result<Output, FixtureError> {
        let environment = [("SSH_AUTH_SOCK", self.socket.as_os_str())];
        run_host_command_with_env("ssh-add", arguments, environment).await
    }

    async fn wait_for_socket(&self) -> Result<(), FixtureError> {
        let deadline = Instant::now() + SOCKET_TIMEOUT;
        while Instant::now() < deadline {
            if self.socket.exists() {
                return Ok(());
            }
            tokio::time::sleep(SOCKET_RETRY).await;
        }
        Err(FixtureError::NotReady {
            service: "ssh-agent",
            seconds: SOCKET_TIMEOUT.as_secs(),
        })
    }
}

impl Drop for SshAgent {
    fn drop(&mut self) {
        // An agent that already exited has nothing left to stop.
        let _ = self.process.kill();
        let _ = self.process.wait();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn an_added_key_is_listed_by_the_private_agent() {
        let agent = SshAgent::start().await.unwrap();
        let key = SshKeyPair::generate("tablepro-agent-test").await.unwrap();
        assert_eq!(agent.identities().await.unwrap(), Vec::<String>::new());

        agent.add(&key).await.unwrap();

        assert_eq!(agent.identities().await.unwrap(), vec![key.public_key().to_owned()]);
    }

    #[tokio::test]
    async fn dropping_the_agent_stops_it() {
        let agent = SshAgent::start().await.unwrap();
        let process = std::path::PathBuf::from(format!("/proc/{}", agent.process.id()));
        assert!(process.exists());

        drop(agent);

        assert!(!process.exists(), "the agent outlived its fixture");
    }
}
