use std::process::{ExitStatus, Stdio};

use tokio::io::AsyncReadExt;
use tokio::process::{ChildStderr, Command};
use tokio_util::sync::CancellationToken;

use crate::DumpError;

const STDERR_LIMIT: usize = 16 * 1024;

pub(crate) struct Finished {
    pub(crate) status: ExitStatus,
    pub(crate) stderr: String,
}

pub(crate) async fn run_supervised(mut command: Command, cancel: CancellationToken) -> Result<Finished, DumpError> {
    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let mut child = command.spawn()?;
    let stderr = child.stderr.take().map(|pipe| tokio::spawn(read_tail(pipe)));
    let status = tokio::select! {
        biased;
        () = cancel.cancelled() => {
            let _ = child.kill().await;
            return Err(DumpError::Cancelled);
        }
        status = child.wait() => status?,
    };
    let stderr = match stderr {
        Some(task) => task.await.unwrap_or_default(),
        None => String::new(),
    };
    Ok(Finished { status, stderr })
}

async fn read_tail(mut pipe: ChildStderr) -> String {
    let mut tail = Vec::new();
    let mut chunk = [0_u8; 4096];
    while let Ok(read) = pipe.read(&mut chunk).await {
        if read == 0 {
            break;
        }
        tail.extend_from_slice(&chunk[..read]);
        if tail.len() > STDERR_LIMIT {
            tail.drain(..tail.len() - STDERR_LIMIT);
        }
    }
    String::from_utf8_lossy(&tail).into_owned()
}
