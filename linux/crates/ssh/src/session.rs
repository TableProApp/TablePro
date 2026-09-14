use std::ffi::OsString;
use std::os::unix::fs::MetadataExt;
use std::os::unix::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::AtomicU64;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tablepro_core::credentials::CredentialInteraction;
use tablepro_core::{LivenessPolicy, SshFailure, TimeoutPhase, TransportError};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
use tokio::net::UnixListener;
use tokio::process::{Child, ChildStderr, Command};
use tokio::sync::mpsc;
use tokio::time::Instant;
use tokio_util::sync::{CancellationToken, WaitForCancellationFutureOwned};

use crate::argv::{ControlOp, master_args};
use crate::askpass_bridge::AskpassBridge;
use crate::known_hosts::spawn_failure;
use crate::stderr_classify::{ClassifyContext, classify};
use crate::supervisor::{ForwardCancel, Supervisor, TASKS, run_control};
use crate::{SshConfig, SshServices, lock};

const CONTROL_SUFFIX: &str = ".0123456789abcdef";
const STDERR_TAIL_LIMIT: usize = 65_536;

#[derive(Debug)]
pub struct SshSession {
    pub(crate) destination: String,
    pub(crate) host: String,
    pub(crate) ssh_program: PathBuf,
    pub(crate) master_dir: PathBuf,
    pub(crate) control: PathBuf,
    pub(crate) master_pid: Option<u32>,
    pub(crate) closed: CancellationToken,
    pub(crate) shutdown: CancellationToken,
    pub(crate) exit_status: Arc<Mutex<Option<i32>>>,
    pub(crate) stderr_tail: Arc<Mutex<String>>,
    pub(crate) forwards: mpsc::UnboundedSender<ForwardCancel>,
    pub(crate) next_forward: AtomicU64,
}

enum Handshake {
    Ready,
    Exited(Option<i32>),
    Failed(TransportError),
}

impl SshSession {
    pub async fn connect(
        config: &SshConfig,
        services: &SshServices,
        liveness: &LivenessPolicy,
        interaction: CredentialInteraction,
        cancel: CancellationToken,
    ) -> Result<Arc<SshSession>, TransportError> {
        let runtime = services.runtime.get().await?;
        let master_dir = tokio::task::spawn_blocking(move || runtime.create_master_dir())
            .await
            .map_err(|error| protocol(&format!("the ssh setup task failed: {error}")))??;
        let control = master_dir.join("control");

        let (listener, owner_uid) = match prepare(&master_dir, &control).await {
            Ok(prepared) => prepared,
            Err(error) => {
                remove_dir(&master_dir).await;
                return Err(error);
            }
        };
        let spawned = Command::new(&services.ssh_program)
            .args(master_args(config, &control, liveness))
            .env("SSH_ASKPASS", &services.askpass_program)
            .env("SSH_ASKPASS_REQUIRE", "force")
            .env_remove("SSH_ASKPASS_PROMPT")
            .env("TABLEPRO_ASKPASS_SOCKET", master_dir.join("askpass"))
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn();
        let mut child = match spawned {
            Ok(child) => child,
            Err(error) => {
                remove_dir(&master_dir).await;
                return Err(spawn_failure(&services.ssh_program, &error).into());
            }
        };

        let stderr_tail = Arc::new(Mutex::new(String::new()));
        let stderr_task = child
            .stderr
            .take()
            .map(|stderr| TASKS.spawn(collect_stderr(stderr, stderr_tail.clone())));
        let mut bridge = AskpassBridge::new(owner_uid, config.destination.to_string(), interaction, &config.auth);
        let outcome = handshake(
            &mut child,
            &listener,
            &mut bridge,
            services,
            &control,
            liveness,
            &cancel,
        )
        .await;
        drop(listener);
        if let Err(error) = tokio::fs::remove_file(master_dir.join("askpass")).await {
            tracing::debug!(%error, "could not remove the askpass socket");
        }

        match outcome {
            Handshake::Ready => {}
            Handshake::Failed(error) => {
                abandon(child, &master_dir).await;
                return Err(error);
            }
            Handshake::Exited(status) => {
                if let Some(task) = stderr_task
                    && let Err(error) = task.await
                {
                    tracing::debug!(%error, "the ssh stderr reader failed");
                }
                remove_dir(&master_dir).await;
                let stderr = lock(&stderr_tail).clone();
                let context = ClassifyContext {
                    host: config.destination.host(),
                    forward_target: None,
                    declined_host_key: bridge.declined_host_key(),
                };
                return Err(classify(status, &stderr, &context));
            }
        }

        let closed = CancellationToken::new();
        let shutdown = CancellationToken::new();
        let exit_status = Arc::new(Mutex::new(None));
        let (forwards, forward_requests) = mpsc::unbounded_channel();
        let session = Arc::new(SshSession {
            destination: config.destination.to_string(),
            host: config.destination.host().to_owned(),
            ssh_program: services.ssh_program.clone(),
            master_dir: master_dir.clone(),
            control: control.clone(),
            master_pid: child.id(),
            closed: closed.clone(),
            shutdown: shutdown.clone(),
            exit_status: exit_status.clone(),
            stderr_tail,
            forwards,
            next_forward: AtomicU64::new(1),
        });
        TASKS.spawn(
            Supervisor {
                child,
                ssh_program: services.ssh_program.clone(),
                control,
                master_dir,
                grace: liveness.cancel_grace,
                shutdown,
                closed,
                exit_status,
                forward_requests,
            }
            .run(),
        );
        Ok(session)
    }

    pub fn closed(&self) -> WaitForCancellationFutureOwned {
        self.closed.clone().cancelled_owned()
    }

    pub fn is_closed(&self) -> bool {
        self.closed.is_cancelled()
    }

    pub fn master_pid(&self) -> Option<u32> {
        self.master_pid
    }

    pub fn destination(&self) -> &str {
        &self.destination
    }

    pub async fn shutdown(&self, grace: Duration) {
        self.shutdown.cancel();
        if tokio::time::timeout(grace.saturating_mul(2), self.closed.cancelled())
            .await
            .is_err()
        {
            tracing::warn!(destination = %self.destination, "the ssh master did not stop within its grace period");
        }
    }
}

impl Drop for SshSession {
    fn drop(&mut self) {
        self.shutdown.cancel();
    }
}

pub(crate) struct HandshakeDeadline {
    remaining: Duration,
    running_since: Option<Instant>,
}

impl HandshakeDeadline {
    pub fn new(timeout: Duration) -> Self {
        Self {
            remaining: timeout,
            running_since: Some(Instant::now()),
        }
    }

    pub fn deadline(&self) -> Instant {
        let since = self.running_since.unwrap_or_else(Instant::now);
        since + self.remaining
    }

    pub fn pause(&mut self) {
        if let Some(since) = self.running_since.take() {
            self.remaining = self.remaining.saturating_sub(since.elapsed());
        }
    }

    pub fn resume(&mut self) {
        if self.running_since.is_none() {
            self.running_since = Some(Instant::now());
        }
    }
}

async fn prepare(master_dir: &Path, control: &Path) -> Result<(UnixListener, u32), TransportError> {
    let mut longest: OsString = control.as_os_str().to_owned();
    longest.push(CONTROL_SUFFIX);
    if SocketAddr::from_pathname(Path::new(&longest)).is_err() {
        return Err(SshFailure::ControlPathTooLong {
            path: control.to_owned(),
        }
        .into());
    }
    let askpass = master_dir.join("askpass");
    let listener = UnixListener::bind(&askpass).map_err(|error| SshFailure::RuntimeDirUnsafe {
        path: askpass.clone(),
        detail: error.to_string(),
    })?;
    let owner_uid = tokio::fs::metadata(master_dir)
        .await
        .map_err(|error| SshFailure::RuntimeDirUnsafe {
            path: master_dir.to_owned(),
            detail: error.to_string(),
        })?
        .uid();
    Ok((listener, owner_uid))
}

async fn handshake(
    child: &mut Child,
    listener: &UnixListener,
    bridge: &mut AskpassBridge,
    services: &SshServices,
    control: &Path,
    liveness: &LivenessPolicy,
    cancel: &CancellationToken,
) -> Handshake {
    let mut deadline = HandshakeDeadline::new(liveness.ssh_handshake_timeout);
    let Some(mut stdout) = child.stdout.take() else {
        return Handshake::Failed(protocol("the ssh stdout pipe was not captured"));
    };
    let mut discarded = Vec::new();
    let stdout_closed = stdout.read_to_end(&mut discarded);
    tokio::pin!(stdout_closed);

    loop {
        tokio::select! {
            biased;
            () = cancel.cancelled() => return Handshake::Failed(SshFailure::InteractionCancelled.into()),
            status = child.wait() => return Handshake::Exited(status.ok().and_then(|status| status.code())),
            _ = &mut stdout_closed => break,
            accepted = listener.accept() => {
                let Ok((stream, _)) = accepted else {
                    continue;
                };
                deadline.pause();
                tokio::select! {
                    biased;
                    () = cancel.cancelled() => return Handshake::Failed(SshFailure::InteractionCancelled.into()),
                    handled = bridge.handle(stream) => {
                        if let Err(error) = handled {
                            tracing::warn!(%error, "an askpass exchange failed");
                        }
                    }
                }
                deadline.resume();
            }
            () = tokio::time::sleep_until(deadline.deadline()) => {
                return Handshake::Failed(TransportError::Timeout { phase: TimeoutPhase::SshHandshake });
            }
        }
    }

    let check = run_control(&services.ssh_program, control, ControlOp::Check);
    tokio::select! {
        biased;
        () = cancel.cancelled() => Handshake::Failed(SshFailure::InteractionCancelled.into()),
        status = child.wait() => Handshake::Exited(status.ok().and_then(|status| status.code())),
        output = check => match output {
            Ok(output) if output.status.success() => Handshake::Ready,
            Ok(output) => Handshake::Failed(protocol(&format!(
                "ssh -O check failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ))),
            Err(error) => Handshake::Failed(spawn_failure(&services.ssh_program, &error).into()),
        },
        () = tokio::time::sleep_until(deadline.deadline()) => {
            Handshake::Failed(TransportError::Timeout { phase: TimeoutPhase::SshHandshake })
        }
    }
}

async fn collect_stderr(stderr: ChildStderr, tail: Arc<Mutex<String>>) {
    let mut segments = BufReader::new(stderr).split(b'\n');
    while let Ok(Some(bytes)) = segments.next_segment().await {
        let line = String::from_utf8_lossy(&bytes);
        tracing::debug!(target: "tablepro_ssh::master", "{line}");
        let mut tail = lock(&tail);
        tail.push_str(&line);
        tail.push('\n');
        if tail.len() > STDERR_TAIL_LIMIT {
            let mut cut = tail.len() - STDERR_TAIL_LIMIT;
            while !tail.is_char_boundary(cut) {
                cut += 1;
            }
            tail.drain(..cut);
        }
    }
}

async fn abandon(mut child: Child, master_dir: &Path) {
    if let Err(error) = child.start_kill() {
        tracing::debug!(%error, "could not kill the ssh master");
    }
    if let Err(error) = child.wait().await {
        tracing::debug!(%error, "could not reap the ssh master");
    }
    remove_dir(master_dir).await;
}

pub(crate) async fn remove_dir(dir: &Path) {
    if let Err(error) = tokio::fs::remove_dir_all(dir).await {
        tracing::debug!(%error, dir = %dir.display(), "could not remove an ssh master directory");
    }
}

fn protocol(detail: &str) -> TransportError {
    SshFailure::Protocol {
        detail: detail.to_owned(),
    }
    .into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(start_paused = true)]
    async fn handshake_deadline_paused_while_prompting() {
        let mut deadline = HandshakeDeadline::new(Duration::from_secs(20));
        tokio::time::advance(Duration::from_secs(5)).await;
        deadline.pause();
        tokio::time::advance(Duration::from_secs(60)).await;
        deadline.resume();
        assert_eq!(deadline.deadline() - Instant::now(), Duration::from_secs(15));
    }

    #[test]
    fn control_path_too_long_detected() {
        let long = PathBuf::from(format!("/tmp/{}", "a".repeat(100))).join("control");
        let mut longest: OsString = long.as_os_str().to_owned();
        longest.push(CONTROL_SUFFIX);
        assert!(SocketAddr::from_pathname(Path::new(&longest)).is_err());
        let short = Path::new("/run/user/1000/app/ssh/0123456789abcdef/89abcdef/control");
        let mut suffixed: OsString = short.as_os_str().to_owned();
        suffixed.push(CONTROL_SUFFIX);
        assert!(SocketAddr::from_pathname(Path::new(&suffixed)).is_ok());
    }
}
