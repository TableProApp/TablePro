use std::ffi::OsString;
use std::os::unix::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::AtomicU64;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
use tokio::net::UnixListener;
use tokio::process::{Child, ChildStderr, Command};
use tokio::sync::mpsc;
use tokio::time::Instant;
use tokio_util::sync::{CancellationToken, WaitForCancellationFutureOwned};

use super::argv::{ControlOp, master_args};
use super::askpass_bridge::AskpassBridge;
use super::error::{protocol, spawn_failure, unsafe_dir};
use super::stderr_classify::{ClassifyContext, DeclinedHostKey, classify};
use super::supervisor::{ForwardCancel, Supervisor, run_control};
use super::{OpenSshConfig, OpenSshError, OpenSshRuntime, OpenSshTimeouts, Prompter, TimeoutPhase, lock};

const CONTROL_SUFFIX: &str = ".0123456789abcdef";
const STDERR_TAIL_LIMIT: usize = 65_536;
const ASKPASS_SOCKET: &str = "askpass";

#[derive(Debug, Clone)]
pub struct OpenSshContext {
    pub runtime: Arc<OpenSshRuntime>,
    pub ssh_program: PathBuf,
    pub askpass_program: PathBuf,
    pub timeouts: OpenSshTimeouts,
}

#[derive(Debug)]
pub struct OpenSshSession {
    pub(crate) destination: String,
    pub(crate) host: String,
    pub(crate) ssh_program: PathBuf,
    pub(crate) master_dir: PathBuf,
    pub(crate) control: PathBuf,
    pub(crate) timeouts: OpenSshTimeouts,
    master_pid: Option<u32>,
    closed: CancellationToken,
    shutdown: CancellationToken,
    exit_status: Arc<Mutex<Option<i32>>>,
    stderr_tail: Arc<Mutex<String>>,
    pub(crate) forwards: mpsc::UnboundedSender<ForwardCancel>,
    pub(crate) next_forward: AtomicU64,
}

enum Handshake {
    Ready,
    Exited(Option<i32>),
    Failed(OpenSshError),
}

struct Master {
    child: Child,
    master_dir: MasterDir,
    control: PathBuf,
    stderr_tail: Arc<Mutex<String>>,
    stderr_task: Option<tokio::task::JoinHandle<()>>,
}

struct MasterDir {
    path: PathBuf,
    kept: bool,
}

impl MasterDir {
    fn new(path: PathBuf) -> Self {
        Self { path, kept: false }
    }

    fn path(&self) -> &Path {
        &self.path
    }

    fn keep(mut self) -> PathBuf {
        self.kept = true;
        self.path.clone()
    }
}

impl Drop for MasterDir {
    fn drop(&mut self) {
        if !self.kept {
            remove_dir_now(&self.path);
        }
    }
}

impl OpenSshSession {
    pub async fn connect(
        config: &OpenSshConfig,
        context: &OpenSshContext,
        prompter: Arc<dyn Prompter>,
        cancel: CancellationToken,
    ) -> Result<Arc<OpenSshSession>, OpenSshError> {
        let runtime = context.runtime.clone();
        let master_dir = tokio::task::spawn_blocking(move || runtime.create_master_dir())
            .await
            .map_err(|error| protocol(format!("the ssh setup task failed: {error}")))??;
        let master_dir = MasterDir::new(master_dir);
        let control = master_dir.path().join("control");
        let listener = bind_askpass(master_dir.path(), &control)?;
        let mut master = spawn_master(config, context, master_dir, control)?;
        let mut bridge = AskpassBridge::new(context.runtime.owner_uid(), config, prompter);
        let outcome = handshake(&mut master, &listener, &mut bridge, config, context, &cancel).await;
        drop(listener);
        remove_askpass_socket(master.master_dir.path()).await;
        match outcome {
            Handshake::Ready => Ok(Self::supervise(config, context, master)),
            Handshake::Failed(error) => {
                abandon(master.child).await;
                Err(error)
            }
            Handshake::Exited(status) => Err(exited_during_handshake(master, status, config, &bridge).await),
        }
    }

    fn supervise(config: &OpenSshConfig, context: &OpenSshContext, master: Master) -> Arc<OpenSshSession> {
        let closed = CancellationToken::new();
        let shutdown = CancellationToken::new();
        let exit_status = Arc::new(Mutex::new(None));
        let (forwards, forward_requests) = mpsc::unbounded_channel();
        let master_dir = master.master_dir.keep();
        let session = Arc::new(OpenSshSession {
            destination: config.destination.to_string(),
            host: config.destination.host().to_owned(),
            ssh_program: context.ssh_program.clone(),
            master_dir: master_dir.clone(),
            control: master.control.clone(),
            timeouts: context.timeouts,
            master_pid: master.child.id(),
            closed: closed.clone(),
            shutdown: shutdown.clone(),
            exit_status: exit_status.clone(),
            stderr_tail: master.stderr_tail,
            forwards,
            next_forward: AtomicU64::new(1),
        });
        tokio::spawn(
            Supervisor {
                child: master.child,
                ssh_program: context.ssh_program.clone(),
                control: master.control,
                master_dir,
                grace: context.timeouts.grace,
                shutdown,
                closed,
                exit_status,
                forward_requests,
            }
            .run(),
        );
        session
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

    pub async fn shutdown(&self) {
        self.shutdown.cancel();
        let wait = self.timeouts.grace.saturating_mul(3);
        if tokio::time::timeout(wait, self.closed.cancelled()).await.is_err() {
            tracing::warn!(destination = %self.destination, "the ssh master did not stop within its grace period");
        }
    }

    pub(crate) fn master_exited(&self) -> OpenSshError {
        let status = *lock(&self.exit_status);
        let detail = lock(&self.stderr_tail)
            .lines()
            .last()
            .unwrap_or("the ssh master exited")
            .to_owned();
        OpenSshError::MasterExited { status, detail }
    }
}

impl Drop for OpenSshSession {
    fn drop(&mut self) {
        self.shutdown.cancel();
    }
}

fn bind_askpass(master_dir: &Path, control: &Path) -> Result<UnixListener, OpenSshError> {
    let mut longest: OsString = control.as_os_str().to_owned();
    longest.push(CONTROL_SUFFIX);
    if SocketAddr::from_pathname(Path::new(&longest)).is_err() {
        return Err(OpenSshError::ControlPathTooLong {
            path: control.to_owned(),
        });
    }
    let askpass = master_dir.join(ASKPASS_SOCKET);
    UnixListener::bind(&askpass).map_err(|error| unsafe_dir(&askpass, error))
}

fn spawn_master(
    config: &OpenSshConfig,
    context: &OpenSshContext,
    master_dir: MasterDir,
    control: PathBuf,
) -> Result<Master, OpenSshError> {
    let mut command = Command::new(&context.ssh_program);
    command
        .args(master_args(config, &control, &context.timeouts))
        .env("SSH_ASKPASS", &context.askpass_program)
        .env("SSH_ASKPASS_REQUIRE", "force")
        .env_remove("SSH_ASKPASS_PROMPT")
        .env("TABLEPRO_ASKPASS_SOCKET", master_dir.path().join(ASKPASS_SOCKET))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let expected_parent = std::process::id();
    unsafe {
        command.pre_exec(move || die_if_parent_is_gone(expected_parent));
    }
    let mut child = command
        .spawn()
        .map_err(|error| spawn_failure(&context.ssh_program, &error))?;
    let stderr_tail = Arc::new(Mutex::new(String::new()));
    let stderr_task = child
        .stderr
        .take()
        .map(|stderr| tokio::spawn(collect_stderr(stderr, stderr_tail.clone())));
    Ok(Master {
        child,
        master_dir,
        control,
        stderr_tail,
        stderr_task,
    })
}

fn die_if_parent_is_gone(expected_parent: u32) -> std::io::Result<()> {
    if unsafe { libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL, 0, 0, 0) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    if unsafe { libc::getppid() } as u32 != expected_parent {
        std::process::exit(1);
    }
    Ok(())
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

fn handshake_timeout() -> OpenSshError {
    OpenSshError::Timeout {
        phase: TimeoutPhase::Handshake,
    }
}

async fn handshake(
    master: &mut Master,
    listener: &UnixListener,
    bridge: &mut AskpassBridge,
    config: &OpenSshConfig,
    context: &OpenSshContext,
    cancel: &CancellationToken,
) -> Handshake {
    let mut deadline = HandshakeDeadline::new(context.timeouts.handshake);
    let Some(mut stdout) = master.child.stdout.take() else {
        return Handshake::Failed(protocol("the ssh stdout pipe was not captured"));
    };
    let mut discarded = Vec::new();
    let stdout_closed = stdout.read_to_end(&mut discarded);
    tokio::pin!(stdout_closed);
    loop {
        tokio::select! {
            biased;
            () = cancel.cancelled() => return Handshake::Failed(OpenSshError::Cancelled),
            status = master.child.wait() => return Handshake::Exited(status.ok().and_then(|status| status.code())),
            _ = &mut stdout_closed => break,
            accepted = listener.accept() => {
                let Ok((stream, _)) = accepted else {
                    continue;
                };
                deadline.pause();
                tokio::select! {
                    biased;
                    () = cancel.cancelled() => return Handshake::Failed(OpenSshError::Cancelled),
                    handled = bridge.handle(stream) => {
                        if let Err(error) = handled {
                            tracing::warn!(kind = ?error.kind(), "an askpass exchange failed");
                        }
                    }
                }
                if let Some(error) = declined_host_key_error(
                    config.destination.host(),
                    bridge.declined_host_key(),
                ) {
                    return Handshake::Failed(error);
                }
                deadline.resume();
            }
            () = tokio::time::sleep_until(deadline.deadline()) => return Handshake::Failed(handshake_timeout()),
        }
    }
    confirm_master(master, context, cancel, deadline.deadline()).await
}

fn declined_host_key_error(host: &str, declined: Option<&DeclinedHostKey>) -> Option<OpenSshError> {
    declined.map(|declined| OpenSshError::HostKeyUnknown {
        host: host.to_owned(),
        algorithm: declined.algorithm.clone(),
        fingerprint: declined.fingerprint.clone(),
        declined: true,
    })
}

async fn confirm_master(
    master: &mut Master,
    context: &OpenSshContext,
    cancel: &CancellationToken,
    deadline: Instant,
) -> Handshake {
    let check = run_control(&context.ssh_program, &master.control, ControlOp::Check);
    tokio::select! {
        biased;
        () = cancel.cancelled() => Handshake::Failed(OpenSshError::Cancelled),
        status = master.child.wait() => Handshake::Exited(status.ok().and_then(|status| status.code())),
        output = check => match output {
            Ok(output) if output.status.success() => Handshake::Ready,
            Ok(output) => {
                tracing::debug!(stderr = %String::from_utf8_lossy(&output.stderr).trim(), "ssh -O check failed");
                Handshake::Failed(protocol("the ssh master did not answer its control socket"))
            }
            Err(error) => Handshake::Failed(spawn_failure(&context.ssh_program, &error)),
        },
        () = tokio::time::sleep_until(deadline) => Handshake::Failed(handshake_timeout()),
    }
}

async fn exited_during_handshake(
    master: Master,
    status: Option<i32>,
    config: &OpenSshConfig,
    bridge: &AskpassBridge,
) -> OpenSshError {
    if let Some(task) = master.stderr_task
        && let Err(error) = task.await
    {
        tracing::debug!(%error, "the ssh stderr reader failed");
    }
    let stderr = lock(&master.stderr_tail).clone();
    let context = ClassifyContext {
        host: config.destination.host(),
        forward_target: None,
        declined_host_key: bridge.declined_host_key(),
    };
    classify(status, &stderr, &context)
}

async fn collect_stderr(stderr: ChildStderr, tail: Arc<Mutex<String>>) {
    let mut segments = BufReader::new(stderr).split(b'\n');
    while let Ok(Some(bytes)) = segments.next_segment().await {
        let line = String::from_utf8_lossy(&bytes);
        tracing::debug!(target: "tablepro_ssh::openssh::master", "{line}");
        append_bounded(&mut lock(&tail), &line);
    }
}

fn append_bounded(tail: &mut String, line: &str) {
    tail.push_str(line);
    tail.push('\n');
    if tail.len() <= STDERR_TAIL_LIMIT {
        return;
    }
    let mut cut = tail.len() - STDERR_TAIL_LIMIT;
    while !tail.is_char_boundary(cut) {
        cut += 1;
    }
    tail.drain(..cut);
}

async fn abandon(mut child: Child) {
    if let Err(error) = child.start_kill() {
        tracing::debug!(%error, "could not kill the ssh master");
    }
    if let Err(error) = child.wait().await {
        tracing::debug!(%error, "could not reap the ssh master");
    }
}

async fn remove_askpass_socket(master_dir: &Path) {
    if let Err(error) = tokio::fs::remove_file(master_dir.join(ASKPASS_SOCKET)).await {
        tracing::debug!(%error, "could not remove the askpass socket");
    }
}

pub(crate) fn remove_dir_now(dir: &Path) {
    if let Err(error) = std::fs::remove_dir_all(dir) {
        tracing::debug!(%error, dir = %dir.display(), "could not remove an ssh master directory");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_declined_host_key_ends_the_master_handshake_as_a_refusal() {
        let declined = DeclinedHostKey {
            algorithm: "ED25519".to_owned(),
            fingerprint: "SHA256:abc".to_owned(),
        };

        assert_eq!(
            declined_host_key_error("bastion.example", Some(&declined)),
            Some(OpenSshError::HostKeyUnknown {
                host: "bastion.example".to_owned(),
                algorithm: "ED25519".to_owned(),
                fingerprint: "SHA256:abc".to_owned(),
                declined: true,
            })
        );
        assert_eq!(declined_host_key_error("bastion.example", None), None);
    }

    #[tokio::test(start_paused = true)]
    async fn the_handshake_deadline_is_paused_while_prompting() {
        let mut deadline = HandshakeDeadline::new(Duration::from_secs(20));
        tokio::time::advance(Duration::from_secs(5)).await;
        deadline.pause();
        tokio::time::advance(Duration::from_secs(60)).await;
        deadline.resume();
        assert_eq!(deadline.deadline() - Instant::now(), Duration::from_secs(15));
    }

    #[tokio::test]
    async fn a_control_path_too_long_for_a_socket_is_refused_before_spawning() {
        let temp = tempfile::tempdir().unwrap();
        let long = temp.path().join("a".repeat(100));
        std::fs::create_dir(&long).unwrap();
        assert!(matches!(
            bind_askpass(&long, &long.join("control")),
            Err(OpenSshError::ControlPathTooLong { .. })
        ));
        assert!(bind_askpass(temp.path(), &temp.path().join("control")).is_ok());
    }

    #[test]
    fn the_stderr_tail_stays_bounded_on_a_char_boundary() {
        let mut tail = String::new();
        for _ in 0..100 {
            append_bounded(&mut tail, &"é".repeat(1000));
        }
        assert!(tail.len() <= STDERR_TAIL_LIMIT);
        assert!(tail.ends_with("é\n"));
    }

    #[test]
    fn a_dropped_master_dir_is_removed_unless_kept() {
        let temp = tempfile::tempdir().unwrap();
        let removed = temp.path().join("removed");
        let kept = temp.path().join("kept");
        std::fs::create_dir(&removed).unwrap();
        std::fs::create_dir(&kept).unwrap();
        drop(MasterDir::new(removed.clone()));
        assert_eq!(MasterDir::new(kept.clone()).keep(), kept);
        assert!(!removed.exists());
        assert!(kept.exists());
    }
}
