use std::ffi::OsString;
use std::os::unix::fs::MetadataExt;
use std::os::unix::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::AtomicU64;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tablepro_core::credentials::CredentialInteraction;
use tablepro_core::{LivenessPolicy, NetworkEndpoint, SshFailure, TimeoutPhase, TransportError};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
use tokio::net::UnixListener;
use tokio::process::{Child, ChildStderr, Command};
use tokio::sync::mpsc;
use tokio::time::Instant;
use tokio_util::sync::{CancellationToken, WaitForCancellationFutureOwned};

use crate::argv::{ControlOp, master_args};
use crate::askpass_bridge::AskpassBridge;
use crate::hop_config;
use crate::host_key_checking::HostKeyChecking;
use crate::known_hosts::{known_hosts_lookup, spawn_failure};
use crate::password_owner::password_owner;
use crate::route::{JumpHop, Route, lookup, trace_route};
use crate::runtime::unsafe_dir;
use crate::stderr_classify::{ClassifyContext, classify};
use crate::supervisor::{ForwardCancel, Supervisor, TASKS, run_control};
use crate::{SshAuth, SshConfig, SshServices, lock};

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
    pub(crate) first_hop: Option<NetworkEndpoint>,
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

/// A master that finished its handshake, and where it keeps its sockets.
struct Master {
    child: Child,
    master_dir: PathBuf,
    control: PathBuf,
    stderr_tail: Arc<Mutex<String>>,
}

/// What ssh's own configuration says about the destination, read before
/// the master starts.
struct MasterPlan {
    /// The `user@host` in the destination's password prompt.
    password_owner: Option<String>,
    host_keys: Option<HostKeyChecking>,
    strict_hosts: Vec<String>,
    route: Route,
    master_config: Option<PathBuf>,
}

impl MasterPlan {
    async fn resolve(
        config: &SshConfig,
        services: &SshServices,
        master_dir: &Path,
        cancel: &CancellationToken,
    ) -> Result<Self, TransportError> {
        let config_file = services.config_file.as_deref();
        let resolved = lookup(
            &services.ssh_program,
            config_file,
            &config.destination,
            &config.jump_hosts,
        )
        .await;
        let password_owner = match config.auth {
            SshAuth::Password { .. } => resolved.as_deref().and_then(password_owner),
            SshAuth::Agent | SshAuth::PrivateKey { .. } | SshAuth::KeyboardInteractive => None,
        };
        let host_keys = resolved.as_deref().and_then(HostKeyChecking::from_ssh_g);
        let route = tokio::select! {
            route = trace_route(&services.ssh_program, config_file, resolved.as_deref()) => route,
            () = cancel.cancelled() => return Err(SshFailure::InteractionCancelled.into()),
        };
        let master_config = pin_jump_hosts(&route.hops, config_file, master_dir)
            .await?
            .or_else(|| config_file.map(Path::to_path_buf));
        Ok(Self {
            password_owner,
            host_keys,
            strict_hosts: strict_hosts(resolved.as_deref(), &route.hops),
            route,
            master_config,
        })
    }

    fn spawn_master(
        &self,
        config: &SshConfig,
        services: &SshServices,
        liveness: &LivenessPolicy,
        control: &Path,
        master_dir: &Path,
    ) -> std::io::Result<Child> {
        Command::new(&services.ssh_program)
            .args(master_args(
                config,
                control,
                liveness,
                self.host_keys,
                self.master_config.as_deref(),
            ))
            .env("SSH_ASKPASS", &services.askpass_program)
            .env("SSH_ASKPASS_REQUIRE", "force")
            .env_remove("SSH_ASKPASS_PROMPT")
            .env("TABLEPRO_ASKPASS_SOCKET", master_dir.join("askpass"))
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
    }
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
            .map_err(|error| crate::setup_task_failed(&error))??;
        let control = master_dir.join("control");

        let (listener, owner_uid) = match prepare(&master_dir, &control).await {
            Ok(prepared) => prepared,
            Err(error) => {
                remove_dir(&master_dir).await;
                return Err(error);
            }
        };
        let plan = match MasterPlan::resolve(config, services, &master_dir, &cancel).await {
            Ok(plan) => plan,
            Err(error) => {
                remove_dir(&master_dir).await;
                return Err(error);
            }
        };
        let mut child = match plan.spawn_master(config, services, liveness, &control, &master_dir) {
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
        let mut bridge = AskpassBridge::new(
            owner_uid,
            config.destination.to_string(),
            interaction,
            &config.auth,
            plan.password_owner,
        );
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
                    strict_hosts: &plan.strict_hosts,
                };
                return Err(classify(status, &stderr, &context));
            }
        }

        let master = Master {
            child,
            master_dir,
            control,
            stderr_tail,
        };
        Ok(Self::supervise(
            config,
            services,
            liveness,
            master,
            plan.route.first_hop,
        ))
    }

    /// The session over a master that finished its handshake, with the
    /// supervisor that stops it.
    fn supervise(
        config: &SshConfig,
        services: &SshServices,
        liveness: &LivenessPolicy,
        master: Master,
        first_hop: Option<NetworkEndpoint>,
    ) -> Arc<SshSession> {
        let Master {
            child,
            master_dir,
            control,
            stderr_tail,
        } = master;
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
            first_hop,
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

    /// Where the session's first TCP connection goes, as ssh resolved
    /// it: the first jump host, or the destination behind its alias.
    /// `None` for a ProxyCommand route, whose first hop only that
    /// command knows.
    pub fn first_hop_endpoint(&self) -> Option<&NetworkEndpoint> {
        self.first_hop.as_ref()
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

/// The known_hosts names of the hosts whose configuration sets
/// StrictHostKeyChecking yes. The master's `-o` and the pinned file
/// raise only accept-new and no to ask, so yes is what ssh applies.
fn strict_hosts(destination: Option<&str>, hops: &[JumpHop]) -> Vec<String> {
    let destination = destination
        .filter(|resolved| HostKeyChecking::from_ssh_g(resolved) == Some(HostKeyChecking::Yes))
        .and_then(known_hosts_lookup);
    let hops = hops
        .iter()
        .filter(|hop| hop.host_keys == Some(HostKeyChecking::Yes))
        .filter_map(|hop| hop.known_hosts_name.clone());
    destination.into_iter().chain(hops).collect()
}

/// The master's ssh_config when a jump host's own configuration would
/// trust a host key without asking, which the master's `-o` options do
/// not reach. `None` when every hop already asks or refuses.
async fn pin_jump_hosts(
    hops: &[JumpHop],
    config_file: Option<&Path>,
    master_dir: &Path,
) -> Result<Option<PathBuf>, TransportError> {
    let pinned: Vec<String> = hop_config::hosts_to_pin(hops).into_iter().map(str::to_owned).collect();
    if pinned.is_empty() {
        return Ok(None);
    }
    let config_file = config_file.map(Path::to_path_buf);
    let master_dir = master_dir.to_owned();
    tokio::task::spawn_blocking(move || {
        let contents = hop_config::render(&pinned, config_file.as_deref())?;
        hop_config::write(&master_dir, &contents)
    })
    .await
    .map_err(|error| crate::setup_task_failed(&error))?
    .map(Some)
    .map_err(TransportError::from)
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
    let listener = UnixListener::bind(&askpass).map_err(|error| unsafe_dir(&askpass, &error))?;
    let owner_uid = tokio::fs::metadata(master_dir)
        .await
        .map_err(|error| unsafe_dir(master_dir, &error))?
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
        tracing::warn!("the ssh master's stdout was not piped");
        return Handshake::Failed(SshFailure::Internal.into());
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
            Ok(output) => Handshake::Failed(
                SshFailure::Protocol {
                    status: output.status.code(),
                    detail: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
                }
                .into(),
            ),
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::SshDestination;

    #[tokio::test(start_paused = true)]
    async fn handshake_deadline_paused_while_prompting() {
        let mut deadline = HandshakeDeadline::new(Duration::from_secs(20));
        tokio::time::advance(Duration::from_secs(5)).await;
        deadline.pause();
        tokio::time::advance(Duration::from_secs(60)).await;
        deadline.resume();
        assert_eq!(deadline.deadline() - Instant::now(), Duration::from_secs(15));
    }

    /// Each host's own StrictHostKeyChecking decides, as the real
    /// `ssh -G` resolves the destination and every jump host.
    #[tokio::test]
    async fn the_strict_hosts_are_those_whose_configuration_says_yes() {
        let dir = tempfile::tempdir().unwrap();
        let config_file = dir.path().join("ssh_config");
        std::fs::write(
            &config_file,
            "Host db\n    HostName 10.0.0.5\n    Port 2222\n    ProxyJump strict-jump,ask-jump\n    StrictHostKeyChecking yes\n\
             Host strict-jump\n    HostName 192.0.2.1\n    StrictHostKeyChecking yes\n\
             Host ask-jump\n    HostName 192.0.2.2\n    HostKeyAlias bastion\n    StrictHostKeyChecking ask\n\
             Host new-jump\n    HostName 192.0.2.4\n    StrictHostKeyChecking accept-new\n\
             Host open\n    HostName 192.0.2.3\n    StrictHostKeyChecking no\n\
             Host unset\n    HostName 192.0.2.5\n",
        )
        .unwrap();
        let services = SshServices {
            runtime: Arc::new(crate::SshRuntimeCell::new(dir.path().join("runtime"))),
            ssh_program: "ssh".into(),
            ssh_keygen_program: "ssh-keygen".into(),
            askpass_program: "tablepro-askpass".into(),
            config_file: Some(config_file),
        };
        let strict_hosts = async |host: &str, jumps: &[&str]| {
            let master_dir = tempfile::tempdir_in(dir.path()).unwrap();
            let config = SshConfig {
                destination: SshDestination::new(host, None, None).unwrap(),
                jump_hosts: jumps
                    .iter()
                    .map(|jump| SshDestination::new(jump, None, None).unwrap())
                    .collect(),
                auth: SshAuth::Agent,
            };
            let plan = MasterPlan::resolve(&config, &services, master_dir.path(), &CancellationToken::new())
                .await
                .unwrap();
            plan.strict_hosts
        };

        assert_eq!(strict_hosts("db", &[]).await, ["[10.0.0.5]:2222", "192.0.2.1"]);
        assert_eq!(strict_hosts("open", &["strict-jump"]).await, ["192.0.2.1"]);
        assert!(strict_hosts("unset", &["ask-jump", "new-jump"]).await.is_empty());
        assert!(strict_hosts("open", &[]).await.is_empty());
    }

    #[tokio::test]
    async fn a_master_that_exited_keeps_ssh_s_last_line_and_no_words_of_ours() {
        let dir = tempfile::tempdir().unwrap();
        let services = SshServices {
            runtime: Arc::new(crate::SshRuntimeCell::new(dir.path().join("runtime"))),
            ssh_program: "ssh".into(),
            ssh_keygen_program: "ssh-keygen".into(),
            askpass_program: "tablepro-askpass".into(),
            config_file: None,
        };
        let config = SshConfig {
            destination: SshDestination::new("db", None, None).unwrap(),
            jump_hosts: Vec::new(),
            auth: SshAuth::Agent,
        };
        let exited = async |stderr: &str| {
            let master_dir = tempfile::tempdir_in(dir.path()).unwrap().keep();
            let master = Master {
                child: Command::new("sh").args(["-c", "exit 3"]).spawn().unwrap(),
                control: master_dir.join("control"),
                master_dir,
                stderr_tail: Arc::new(Mutex::new(stderr.to_owned())),
            };
            let session = SshSession::supervise(&config, &services, &LivenessPolicy::DESKTOP, master, None);
            session.closed().await;
            session.master_exited()
        };

        assert_eq!(
            exited("").await,
            TransportError::Ssh(SshFailure::MasterExited {
                status: Some(3),
                detail: String::new(),
            })
        );
        assert_eq!(
            exited("debug1: closing\nConnection to db closed by remote host.\n").await,
            TransportError::Ssh(SshFailure::MasterExited {
                status: Some(3),
                detail: "Connection to db closed by remote host.".to_owned(),
            })
        );
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
