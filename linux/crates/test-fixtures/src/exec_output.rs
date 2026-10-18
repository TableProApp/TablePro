use testcontainers::core::{CmdWaitFor, ExecCommand};
use testcontainers::{ContainerAsync, Image};

use crate::FixtureError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExecOutput {
    pub exit_code: Option<i64>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

impl ExecOutput {
    pub(crate) async fn run<I: Image>(container: &ContainerAsync<I>, command: &[&str]) -> Result<Self, FixtureError> {
        let request = ExecCommand::new(command.iter().copied()).with_cmd_ready_condition(CmdWaitFor::exit());
        let mut result = container.exec(request).await?;
        let stdout = result.stdout_to_vec().await?;
        let stderr = result.stderr_to_vec().await?;
        let exit_code = result.exit_code().await?;
        Ok(Self {
            exit_code,
            stdout,
            stderr,
        })
    }

    pub fn succeeded(&self) -> bool {
        self.exit_code == Some(0)
    }

    pub fn stdout_text(&self) -> String {
        String::from_utf8_lossy(&self.stdout).into_owned()
    }

    pub fn stderr_text(&self) -> String {
        String::from_utf8_lossy(&self.stderr).into_owned()
    }
}
