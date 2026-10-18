use std::ffi::OsStr;
use std::process::{Output, Stdio};

use tokio::process::Command;

use crate::FixtureError;

pub(crate) async fn run_host_command<I, S>(program: &'static str, arguments: I) -> Result<Output, FixtureError>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    run_host_command_with_env(program, arguments, std::iter::empty::<(&str, &OsStr)>()).await
}

pub(crate) async fn run_host_command_with_env<I, S, E, K, V>(
    program: &'static str,
    arguments: I,
    environment: E,
) -> Result<Output, FixtureError>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
    E: IntoIterator<Item = (K, V)>,
    K: AsRef<OsStr>,
    V: AsRef<OsStr>,
{
    let output = Command::new(program)
        .args(arguments)
        .envs(environment)
        .stdin(Stdio::null())
        .output()
        .await?;
    if output.status.success() {
        return Ok(output);
    }
    Err(FixtureError::HostCommand {
        program,
        status: output.status,
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    })
}
