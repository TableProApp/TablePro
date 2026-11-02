use testcontainers::core::{CmdWaitFor, ExecCommand, ExecResult};
use testcontainers::{ContainerAsync, Image, TestcontainersError};

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
        let exit_code = exit_code(result).await?;
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

// `ExecResult::exit_code` holds a borrow of a result that is not Sync
// across its await, which would make every future that runs a command
// !Send, a fixture's start among them. A blocking task owns it instead.
async fn exit_code(result: ExecResult) -> Result<Option<i64>, FixtureError> {
    let runtime = tokio::runtime::Handle::current();
    tokio::task::spawn_blocking(move || runtime.block_on(result.exit_code()))
        .await
        .map_err(|error| FixtureError::Container(TestcontainersError::Other(error.into())))?
        .map_err(FixtureError::Container)
}
