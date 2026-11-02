use std::io;
use std::path::{Path, PathBuf};
use std::process::{Output, Stdio};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;

use tablepro_core::NetworkEndpoint;
use tokio::process::{Child, Command};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;

use crate::argv::{ControlOp, control_args};
use crate::lock;
use crate::session::remove_dir;

pub(crate) static TASKS: LazyLock<TaskTracker> = LazyLock::new(TaskTracker::new);

#[derive(Debug)]
pub(crate) struct ForwardCancel {
    pub listen: PathBuf,
    pub target: NetworkEndpoint,
}

pub(crate) struct Supervisor {
    pub child: Child,
    pub ssh_program: PathBuf,
    pub control: PathBuf,
    pub master_dir: PathBuf,
    pub grace: Duration,
    pub shutdown: CancellationToken,
    pub closed: CancellationToken,
    pub exit_status: Arc<Mutex<Option<i32>>>,
    pub forward_requests: mpsc::UnboundedReceiver<ForwardCancel>,
}

impl Supervisor {
    pub async fn run(mut self) {
        loop {
            tokio::select! {
                biased;
                status = self.child.wait() => {
                    self.record(status.ok().and_then(|status| status.code()));
                    break;
                }
                () = self.shutdown.cancelled() => {
                    self.stop().await;
                    break;
                }
                request = self.forward_requests.recv() => match request {
                    Some(request) => self.cancel_forward(&request).await,
                    None => {
                        self.stop().await;
                        break;
                    }
                },
            }
        }
        self.closed.cancel();
        remove_dir(&self.master_dir).await;
    }

    async fn stop(&mut self) {
        let exit = run_control(&self.ssh_program, &self.control, ControlOp::Exit);
        match tokio::time::timeout(self.grace, exit).await {
            Ok(Ok(output)) if output.status.success() => {}
            Ok(Ok(output)) => tracing::debug!(
                stderr = %String::from_utf8_lossy(&output.stderr).trim(),
                "ssh -O exit failed"
            ),
            Ok(Err(error)) => tracing::debug!(%error, "could not run ssh -O exit"),
            Err(_) => tracing::debug!("ssh -O exit did not finish within the grace period"),
        }
        match tokio::time::timeout(self.grace, self.child.wait()).await {
            Ok(status) => self.record(status.ok().and_then(|status| status.code())),
            Err(_) => {
                if let Err(error) = self.child.start_kill() {
                    tracing::debug!(%error, "could not kill the ssh master");
                }
                let status = self.child.wait().await;
                self.record(status.ok().and_then(|status| status.code()));
            }
        }
    }

    async fn cancel_forward(&self, request: &ForwardCancel) {
        let op = ControlOp::Cancel {
            listen: &request.listen,
            target: &request.target,
        };
        match run_control(&self.ssh_program, &self.control, op).await {
            Ok(output) if !output.status.success() => tracing::debug!(
                stderr = %String::from_utf8_lossy(&output.stderr).trim(),
                "ssh -O cancel failed"
            ),
            Ok(_) => {}
            Err(error) => tracing::debug!(%error, "could not run ssh -O cancel"),
        }
        if let Err(error) = tokio::fs::remove_file(&request.listen).await
            && error.kind() != io::ErrorKind::NotFound
        {
            tracing::debug!(%error, "could not remove a forward socket");
        }
    }

    fn record(&self, code: Option<i32>) {
        *lock(&self.exit_status) = code;
    }
}

pub(crate) async fn run_control(ssh_program: &Path, control: &Path, op: ControlOp<'_>) -> io::Result<Output> {
    Command::new(ssh_program)
        .args(control_args(control, op))
        .stdin(Stdio::null())
        .kill_on_drop(true)
        .output()
        .await
}
