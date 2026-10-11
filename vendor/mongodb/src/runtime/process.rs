use std::{
    ffi::OsStr,
    process::{ExitStatus, Stdio},
};

use tokio::process::{Child, Command};

use crate::error::Result;

#[derive(Debug)]
pub(crate) struct Process {
    child: Child,
}

impl Process {
    pub(crate) fn spawn<P, I, A>(path: P, args: I) -> Result<Self>
    where
        P: AsRef<OsStr>,
        I: IntoIterator<Item = A>,
        A: AsRef<OsStr>,
    {
        let mut command = Command::new(path);
        let child = command
            .args(args)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
        Ok(Self { child })
    }

    /// Issue a kill signal to the child process and immediately return; to wait for the process to
    /// actually exit, use `wait`.
    pub(crate) fn kill(&mut self) -> Result<()> {
        Ok(self.child.start_kill()?)
    }

    pub(crate) async fn wait(&mut self) -> Result<ExitStatus> {
        Ok(self.child.wait().await?)
    }
}

impl Drop for Process {
    fn drop(&mut self) {
        // Attempt to reap the process.
        let _ = self.child.try_wait();
    }
}
