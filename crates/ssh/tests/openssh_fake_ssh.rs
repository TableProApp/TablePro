#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use secrecy::SecretString;
use tablepro_ssh::openssh::{
    ForwardRoute, ForwardTarget, LocalEndpoint, OpenSshAuth, OpenSshConfig, OpenSshContext, OpenSshError,
    OpenSshRuntime, OpenSshSession, OpenSshTimeouts, SshDestination, TimeoutPhase, UnattendedPrompter,
    sweep_stale_masters,
};
use tokio_util::sync::CancellationToken;

const FAKE_SSH: &str = r#"#!/bin/sh
dir='@DIR@'
printf '%s\n' "$*" >> "$dir/calls"
case " $* " in
  *" -O check "*) exit 0 ;;
  *" -O exit "*)
    [ -f "$dir/exit-fails" ] && exit 1
    kill "$(cat "$dir/master.pid")"
    exit 0 ;;
  *" -O forward "*) [ -f "$dir/forward-fails" ] && { echo 'mux_client_forward: forwarding request failed: master forward request failed' >&2; exit 255; }; exit 0 ;;
  *" -O "*) exit 0 ;;
esac
echo "$$" > "$dir/master.pid"
{
  printf '%s\n' "$SSH_ASKPASS_REQUIRE" "$TABLEPRO_ASKPASS_SOCKET"
  readlink "/proc/$$/fd/0"
} > "$dir/env"
if [ -f "$dir/fail-auth" ]; then
  echo 'deploy@bastion: Permission denied (publickey,password).' >&2
  exit 255
fi
if [ -f "$dir/prompt" ]; then
  "$SSH_ASKPASS" "$(cat "$dir/prompt")" > "$dir/answer"
fi
[ -f "$dir/hang" ] && exec sleep 300
exec 1>/dev/null
exec sleep 300
"#;

struct Fake {
    dir: tempfile::TempDir,
    context: OpenSshContext,
}

impl Fake {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("ssh");
        std::fs::write(&script, FAKE_SSH.replace("@DIR@", &dir.path().display().to_string())).unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        let base = dir.path().join("run");
        std::fs::create_dir(&base).unwrap();
        let context = OpenSshContext {
            runtime: OpenSshRuntime::acquire(&base).unwrap(),
            ssh_program: script,
            askpass_program: PathBuf::from(env!("CARGO_BIN_EXE_tablepro-askpass")),
            timeouts: OpenSshTimeouts {
                handshake: Duration::from_secs(10),
                grace: Duration::from_millis(300),
                ..OpenSshTimeouts::default()
            },
        };
        Self { dir, context }
    }

    fn path(&self, name: &str) -> PathBuf {
        self.dir.path().join(name)
    }

    fn flag(&self, name: &str) {
        std::fs::write(self.path(name), b"").unwrap();
    }

    fn read(&self, name: &str) -> String {
        std::fs::read_to_string(self.path(name)).unwrap_or_default()
    }

    fn calls(&self) -> Vec<String> {
        self.read("calls").lines().map(str::to_owned).collect()
    }

    async fn connect(&self, auth: OpenSshAuth) -> Result<Arc<OpenSshSession>, OpenSshError> {
        let config = OpenSshConfig {
            destination: SshDestination::new("bastion", Some(2222), Some("deploy".to_owned())).unwrap(),
            jump_hosts: SshDestination::parse_jump_list("ops@jump1").unwrap(),
            auth,
        };
        OpenSshSession::connect(
            &config,
            &self.context,
            Arc::new(UnattendedPrompter),
            CancellationToken::new(),
        )
        .await
    }
}

fn password() -> OpenSshAuth {
    OpenSshAuth::Password {
        password: SecretString::from("s3cret"),
    }
}

fn process_alive(pid: u32) -> bool {
    Path::new(&format!("/proc/{pid}")).exists()
}

async fn wait_until_dead(pid: u32) -> bool {
    for _ in 0..100 {
        if !process_alive(pid) {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    false
}

#[tokio::test]
async fn the_master_starts_with_forced_options_null_stdin_and_the_askpass_socket() {
    let fake = Fake::new();
    let session = fake.connect(OpenSshAuth::Agent).await.unwrap();

    let calls = fake.calls();
    assert!(calls[0].starts_with("-M -N -T -o ControlPath="), "{}", calls[0]);
    assert!(calls[0].contains(" -o StrictHostKeyChecking=ask "));
    assert!(calls[0].contains(" -o ForwardAgent=no "));
    assert!(
        calls[0].ends_with(" -J ops@jump1 -p 2222 -l deploy -- bastion"),
        "{}",
        calls[0]
    );
    assert!(calls[1].starts_with("-F none ") && calls[1].contains(" -O check -- tablepro"));

    let env = fake.read("env");
    let lines: Vec<&str> = env.lines().collect();
    assert_eq!(lines[0], "force");
    assert!(Path::new(lines[1]).starts_with(fake.context.runtime.instance_dir()));
    assert_eq!(lines[2], "/dev/null");
    let master_dir = Path::new(lines[1]).parent().unwrap();
    assert_eq!(
        std::fs::metadata(master_dir).unwrap().permissions().mode() & 0o777,
        0o700
    );
    assert!(!Path::new(lines[1]).exists());
    assert!(session.master_pid().is_some_and(process_alive));
}

#[tokio::test]
async fn the_stored_password_reaches_the_configured_account_through_the_helper() {
    let fake = Fake::new();
    std::fs::write(fake.path("prompt"), "deploy@bastion's password: ").unwrap();
    let _session = fake.connect(password()).await.unwrap();
    assert_eq!(fake.read("answer"), "s3cret\n");
}

#[tokio::test]
async fn a_jump_host_password_prompt_gets_nothing_when_unattended() {
    let fake = Fake::new();
    std::fs::write(fake.path("prompt"), "ops@jump1's password: ").unwrap();
    let _session = fake.connect(password()).await.unwrap();
    assert_eq!(fake.read("answer"), "");
}

#[tokio::test]
async fn an_early_exit_is_classified_from_stderr_and_the_master_dir_is_removed() {
    let fake = Fake::new();
    fake.flag("fail-auth");
    let error = fake.connect(password()).await.unwrap_err();
    assert!(
        matches!(error, OpenSshError::AuthenticationRejected { ref user, .. } if user == "deploy"),
        "{error:?}"
    );
    let entries: Vec<_> = std::fs::read_dir(fake.context.runtime.instance_dir())
        .unwrap()
        .filter_map(Result::ok)
        .filter(|entry| entry.file_name() != "lock")
        .collect();
    assert!(entries.is_empty());
}

#[tokio::test]
async fn a_master_that_never_finishes_authenticating_hits_the_connect_deadline() {
    let mut fake = Fake::new();
    fake.flag("hang");
    fake.context.timeouts.handshake = Duration::from_millis(500);
    let error = fake.connect(OpenSshAuth::Agent).await.unwrap_err();
    assert_eq!(
        error,
        OpenSshError::Timeout {
            phase: TimeoutPhase::Handshake
        }
    );
    let pid: u32 = fake.read("master.pid").trim().parse().unwrap();
    assert!(wait_until_dead(pid).await);
}

#[tokio::test]
async fn a_cancelled_connect_stops_the_master() {
    let fake = Fake::new();
    fake.flag("hang");
    let config = OpenSshConfig {
        destination: SshDestination::new("bastion", None, None).unwrap(),
        jump_hosts: Vec::new(),
        auth: OpenSshAuth::Agent,
    };
    let cancel = CancellationToken::new();
    let connecting = OpenSshSession::connect(&config, &fake.context, Arc::new(UnattendedPrompter), cancel.clone());
    let cancelling = async {
        tokio::time::sleep(Duration::from_millis(300)).await;
        cancel.cancel();
    };
    let (result, ()) = tokio::join!(connecting, cancelling);
    assert_eq!(result.unwrap_err(), OpenSshError::Cancelled);
    let pid: u32 = fake.read("master.pid").trim().parse().unwrap();
    assert!(wait_until_dead(pid).await);
}

#[tokio::test]
async fn dropping_the_session_asks_the_master_to_exit() {
    let fake = Fake::new();
    let session = fake.connect(OpenSshAuth::Agent).await.unwrap();
    let pid = session.master_pid().unwrap();
    let closed = session.closed();
    drop(session);
    tokio::time::timeout(Duration::from_secs(5), closed).await.unwrap();
    assert!(wait_until_dead(pid).await);
    assert!(fake.calls().iter().any(|call| call.contains(" -O exit ")));
}

#[tokio::test]
async fn a_master_that_ignores_exit_is_killed_after_the_grace_period() {
    let fake = Fake::new();
    fake.flag("exit-fails");
    let session = fake.connect(OpenSshAuth::Agent).await.unwrap();
    let pid = session.master_pid().unwrap();
    session.shutdown().await;
    assert!(session.is_closed());
    assert!(wait_until_dead(pid).await);
}

#[tokio::test]
async fn a_killed_master_closes_the_session() {
    let fake = Fake::new();
    let session = fake.connect(OpenSshAuth::Agent).await.unwrap();
    let pid = session.master_pid().unwrap();
    let killed = std::process::Command::new("kill")
        .arg(pid.to_string())
        .status()
        .unwrap();
    assert!(killed.success());
    tokio::time::timeout(Duration::from_secs(5), session.closed())
        .await
        .unwrap();
    let target = ForwardTarget::new("db.internal", 5432).unwrap();
    assert!(matches!(
        session.forward(target, ForwardRoute::UnixSocket).await,
        Err(OpenSshError::MasterExited { .. })
    ));
}

#[tokio::test]
async fn a_named_socket_forward_lives_in_its_own_private_directory() {
    use std::os::unix::fs::PermissionsExt;
    let fake = Fake::new();
    let session = fake.connect(OpenSshAuth::Agent).await.unwrap();
    let target = ForwardTarget::new("db.internal", 5432).unwrap();

    let forward = session
        .forward(target.clone(), ForwardRoute::NamedUnixSocket(".s.PGSQL.5432".into()))
        .await
        .unwrap();

    let LocalEndpoint::Unix(socket) = forward.local_endpoint().clone() else {
        panic!("expected a unix socket");
    };
    assert_eq!(socket.file_name().unwrap(), ".s.PGSQL.5432");
    let directory = socket.parent().unwrap();
    assert_eq!(
        std::fs::metadata(directory).unwrap().permissions().mode() & 0o777,
        0o700
    );
    for bad in ["", "..", "a/b"] {
        assert!(
            session
                .forward(target.clone(), ForwardRoute::NamedUnixSocket(bad.into()))
                .await
                .is_err(),
            "{bad:?}"
        );
    }
}

#[tokio::test]
async fn each_forward_gets_its_own_socket_and_is_cancelled_on_drop() {
    let fake = Fake::new();
    let session = fake.connect(OpenSshAuth::Agent).await.unwrap();
    let target = ForwardTarget::new("db.internal", 5432).unwrap();

    let first = session.forward(target.clone(), ForwardRoute::UnixSocket).await.unwrap();
    let second = session.forward(target.clone(), ForwardRoute::UnixSocket).await.unwrap();
    let LocalEndpoint::Unix(first_socket) = first.local_endpoint().clone() else {
        panic!("expected a unix socket");
    };
    let LocalEndpoint::Unix(second_socket) = second.local_endpoint().clone() else {
        panic!("expected a unix socket");
    };
    assert_ne!(first_socket, second_socket);
    assert_eq!(first.target().host(), "db.internal");
    let spec = format!("-O forward -L {}:db.internal:5432 -- tablepro", first_socket.display());
    assert!(
        fake.calls().iter().any(|call| call.ends_with(&spec)),
        "{:?}",
        fake.calls()
    );

    let tcp = session.forward(target, ForwardRoute::LoopbackTcp).await.unwrap();
    let LocalEndpoint::Tcp(address) = tcp.local_endpoint().clone() else {
        panic!("expected a loopback port");
    };
    assert!(address.ip().is_loopback());
    let spec = format!(
        "-O forward -L 127.0.0.1:{}:db.internal:5432 -- tablepro",
        address.port()
    );
    assert!(fake.calls().iter().any(|call| call.ends_with(&spec)));

    drop(first);
    let cancel = format!("-O cancel -L {}:db.internal:5432 -- tablepro", first_socket.display());
    for _ in 0..100 {
        if fake.calls().iter().any(|call| call.ends_with(&cancel)) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("the dropped forward was not cancelled: {:?}", fake.calls());
}

#[tokio::test]
async fn a_refused_forward_is_classified() {
    let fake = Fake::new();
    fake.flag("forward-fails");
    let session = fake.connect(OpenSshAuth::Agent).await.unwrap();
    let target = ForwardTarget::new("db.internal", 5432).unwrap();
    assert!(matches!(
        session.forward(target, ForwardRoute::UnixSocket).await,
        Err(OpenSshError::ForwardRejected { target, .. }) if target == "db.internal:5432"
    ));
}

#[tokio::test]
async fn the_sweep_asks_stale_masters_to_exit_and_removes_their_directories() {
    let fake = Fake::new();
    let root = fake.context.runtime.root().to_owned();
    let stale = root.join("00000000deadbeef");
    std::fs::create_dir_all(stale.join("0badc0de")).unwrap();
    std::fs::write(stale.join("0badc0de").join("control"), b"").unwrap();
    let lock = std::fs::File::create(stale.join("lock")).unwrap();
    lock.set_modified(SystemTime::now() - Duration::from_secs(3600))
        .unwrap();
    drop(lock);

    let removed = sweep_stale_masters(&fake.context.runtime, &fake.context.ssh_program).await;

    assert_eq!(removed, 1);
    assert!(!stale.exists());
    assert!(fake.context.runtime.instance_dir().exists());
    let exit = format!(
        "ControlPath={} -o LogLevel=INFO -O exit",
        stale.join("0badc0de").join("control").display()
    );
    assert!(
        fake.calls().iter().any(|call| call.contains(&exit)),
        "{:?}",
        fake.calls()
    );
}
