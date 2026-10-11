use std::io;
use std::path::{Path, PathBuf};
use std::process::{Output, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::process::{Child, Command};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use super::argv::{ControlOp, control_args};
use super::session::remove_dir_now;
use super::{ForwardTarget, LocalEndpoint, lock};

#[derive(Debug)]
pub(crate) struct ForwardCancel {
    pub listen: LocalEndpoint,
    pub target: ForwardTarget,
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
        let master_dir = self.master_dir.clone();
        if let Err(error) = tokio::task::spawn_blocking(move || remove_dir_now(&master_dir)).await {
            tracing::debug!(%error, "the ssh master directory removal task failed");
        }
        self.closed.cancel();
    }

    async fn stop(&mut self) {
        let exit = run_control(&self.ssh_program, &self.control, ControlOp::Exit);
        match tokio::time::timeout(self.grace, exit).await {
            Ok(Ok(output)) if output.status.success() => {}
            Ok(Ok(_)) => tracing::debug!("ssh -O exit failed"),
            Ok(Err(error)) => tracing::debug!(%error, "could not run ssh -O exit"),
            Err(_) => tracing::debug!("ssh -O exit did not finish within the grace period"),
        }
        if let Ok(status) = tokio::time::timeout(self.grace, self.child.wait()).await {
            self.record(status.ok().and_then(|status| status.code()));
            return;
        }
        if let Err(error) = self.child.start_kill() {
            tracing::debug!(%error, "could not kill the ssh master");
        }
        let status = self.child.wait().await;
        self.record(status.ok().and_then(|status| status.code()));
    }

    async fn cancel_forward(&self, request: &ForwardCancel) {
        let op = ControlOp::Cancel {
            listen: &request.listen,
            target: &request.target,
        };
        match tokio::time::timeout(self.grace, run_control(&self.ssh_program, &self.control, op)).await {
            Ok(Ok(output)) if !output.status.success() => tracing::debug!("ssh -O cancel failed"),
            Ok(Ok(_)) => {}
            Ok(Err(error)) => tracing::debug!(%error, "could not run ssh -O cancel"),
            Err(_) => tracing::debug!("ssh -O cancel did not finish within the grace period"),
        }
        let LocalEndpoint::Unix(socket) = &request.listen else {
            return;
        };
        if let Err(error) = tokio::fs::remove_file(socket).await
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
