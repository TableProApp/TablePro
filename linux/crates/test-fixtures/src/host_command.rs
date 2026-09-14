use std::ffi::OsStr;
use std::process::{Output, Stdio};

use tokio::process::Command;

use crate::FixtureError;

pub(crate) async fn run_host_command<I, S>(program: &'static str, arguments: I) -> Result<Output, FixtureError>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let output = Command::new(program)
        .args(arguments)
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
