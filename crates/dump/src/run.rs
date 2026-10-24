use std::io::ErrorKind;
use std::process::{ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use tokio::io::AsyncReadExt;
use tokio::process::{ChildStderr, Command};
use tokio_util::sync::CancellationToken;

use crate::DumpError;

const STDERR_LIMIT: usize = 16 * 1024;
const EXECUTABLE_BUSY_RETRIES: usize = 5;
const EXECUTABLE_BUSY_RETRY_DELAY: Duration = Duration::from_millis(10);

pub(crate) struct Finished {
    pub(crate) status: ExitStatus,
    pub(crate) stderr: String,
}

pub(crate) async fn run_supervised(
    mut command: Command,
    cancel: CancellationToken,
    dispatched: Option<&AtomicBool>,
) -> Result<Finished, DumpError> {
    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let mut retries = 0;
    let mut child = loop {
        match command.spawn() {
            Ok(child) => break child,
            Err(error) if error.kind() == ErrorKind::ExecutableFileBusy && retries < EXECUTABLE_BUSY_RETRIES => {
                retries += 1;
                tokio::select! {
                    biased;
                    () = cancel.cancelled() => return Err(DumpError::Cancelled),
                    () = tokio::time::sleep(EXECUTABLE_BUSY_RETRY_DELAY) => {}
                }
            }
            Err(error) => return Err(error.into()),
        }
    };
    if let Some(dispatched) = dispatched {
        dispatched.store(true, Ordering::Release);
    }
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

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    #[tokio::test]
    async fn retries_when_the_executable_is_temporarily_open_for_writing() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("tool");
        std::fs::write(&path, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        let file = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
        let release = std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(40));
            drop(file);
        });

        let result = run_supervised(Command::new(path), CancellationToken::new(), None).await;
        release.join().unwrap();

        assert!(result.is_ok(), "{:?}", result.err());
        assert!(result.unwrap().status.success());
    }

    #[tokio::test]
    async fn cancellation_during_the_executable_retry_does_not_start_the_tool() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("tool");
        let marker = dir.path().join("started");
        std::fs::write(&path, format!("#!/bin/sh\ntouch \"{}\"\n", marker.display())).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        let file = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
        let release = std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(100));
            drop(file);
        });
        let cancel = CancellationToken::new();
        let trigger = cancel.clone();
        let cancellation = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(20)).await;
            trigger.cancel();
        });

        let result = run_supervised(Command::new(path), cancel, None).await;
        cancellation.await.unwrap();
        release.join().unwrap();

        assert!(matches!(result, Err(DumpError::Cancelled)));
        assert!(!marker.exists());
    }
}
