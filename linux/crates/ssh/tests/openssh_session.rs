use std::collections::HashSet;
use std::error::Error;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use secrecy::SecretString;
use tablepro_core::credentials::{CredentialInteraction, PromptPurpose, PromptReply};
use tablepro_core::{LivenessPolicy, NetworkEndpoint, SshFailure, TransportError, TransportRoute};
use tablepro_ssh::{SshAuth, SshConfig, SshDestination, SshRuntimeCell, SshServices, SshSession, forget_host_key};
use tablepro_test_support::FakePrompter;
use testcontainers::core::{IntoContainerPort, WaitFor};
use testcontainers::runners::AsyncRunner;
use testcontainers::{ContainerAsync, GenericImage, ImageExt};
use tokio::io::AsyncReadExt;
use tokio_util::sync::CancellationToken;

type TestResult<T> = Result<T, Box<dyn Error>>;

const SSHD_SCRIPT: &str = "apk add --no-cache openssh >/dev/null \
    && ssh-keygen -A >/dev/null \
    && adduser -D deploy \
    && echo 'deploy:s3cret' | chpasswd \
    && exec /usr/sbin/sshd -D -e -p 2222 -o PasswordAuthentication=yes -o KbdInteractiveAuthentication=no -o AllowTcpForwarding=yes";

struct Fixture {
    container: ContainerAsync<GenericImage>,
    temp: tempfile::TempDir,
    host: String,
    port: u16,
    config: PathBuf,
    known_hosts: PathBuf,
    services: SshServices,
}

fn write_config(config: &Path, known_hosts: &Path, strict_host_key_checking: &str) -> std::io::Result<()> {
    std::fs::write(
        config,
        format!(
            "Host *\n  UserKnownHostsFile {}\n  GlobalKnownHostsFile /dev/null\n  StrictHostKeyChecking {strict_host_key_checking}\n  IdentityAgent none\n  IdentitiesOnly yes\n  PubkeyAuthentication no\n",
            known_hosts.display()
        ),
    )
}

async fn start() -> TestResult<Fixture> {
    let container = GenericImage::new("alpine", "3.22")
        .with_exposed_port(2222.tcp())
        .with_wait_for(WaitFor::message_on_stderr("Server listening on"))
        .with_cmd(["sh", "-c", SSHD_SCRIPT])
        .start()
        .await?;
    let host = container.get_host().await?.to_string();
    let port = container.get_host_port_ipv4(2222).await?;

    let temp = tempfile::tempdir()?;
    let known_hosts = temp.path().join("known_hosts");
    let config = temp.path().join("ssh_config");
    write_config(&config, &known_hosts, "ask")?;
    let wrapper = temp.path().join("ssh");
    std::fs::write(
        &wrapper,
        format!("#!/bin/sh\nexec ssh -F '{}' \"$@\"\n", config.display()),
    )?;
    std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o755))?;

    let runtime_dir = temp.path().join("runtime");
    std::fs::create_dir(&runtime_dir)?;
    let services = SshServices {
        runtime: Arc::new(SshRuntimeCell::new(runtime_dir)),
        ssh_program: wrapper,
        ssh_keygen_program: PathBuf::from("ssh-keygen"),
        askpass_program: PathBuf::from(env!("CARGO_BIN_EXE_tablepro-askpass")),
        config_file: None,
    };
    Ok(Fixture {
        container,
        temp,
        host,
        port,
        config,
        known_hosts,
        services,
    })
}

fn config(fixture: &Fixture, auth: SshAuth) -> TestResult<SshConfig> {
    Ok(SshConfig {
        destination: SshDestination::new(&fixture.host, Some(fixture.port), Some("deploy".to_owned()))?,
        jump_hosts: Vec::new(),
        auth,
    })
}

fn accept() -> PromptReply {
    PromptReply::Submitted {
        values: Vec::new(),
        remember: false,
    }
}

fn answer(secret: &str) -> PromptReply {
    PromptReply::Submitted {
        values: vec![SecretString::from(secret)],
        remember: false,
    }
}

async fn connect(
    fixture: &Fixture,
    auth: SshAuth,
    replies: Vec<PromptReply>,
) -> (Result<Arc<SshSession>, TransportError>, Arc<FakePrompter>) {
    let prompter = Arc::new(FakePrompter::new(replies));
    let result = connect_with(
        fixture,
        auth,
        &LivenessPolicy::DESKTOP,
        CredentialInteraction::Attended(prompter.clone()),
        CancellationToken::new(),
    )
    .await;
    (result, prompter)
}

async fn connect_with(
    fixture: &Fixture,
    auth: SshAuth,
    liveness: &LivenessPolicy,
    interaction: CredentialInteraction,
    cancel: CancellationToken,
) -> Result<Arc<SshSession>, TransportError> {
    match config(fixture, auth) {
        Ok(config) => SshSession::connect(&config, &fixture.services, liveness, interaction, cancel).await,
        Err(error) => Err(SshFailure::Protocol {
            detail: error.to_string(),
        }
        .into()),
    }
}

fn password_auth() -> SshAuth {
    SshAuth::Password {
        password: SecretString::from("s3cret"),
    }
}

/// Socket inodes a process holds open, read from its fd links.
fn socket_inodes(pid: &str) -> HashSet<u64> {
    let Ok(entries) = std::fs::read_dir(format!("/proc/{pid}/fd")) else {
        return HashSet::new();
    };
    entries
        .filter_map(Result::ok)
        .filter_map(|entry| std::fs::read_link(entry.path()).ok())
        .filter_map(|target| {
            let target = target.to_string_lossy().into_owned();
            target.strip_prefix("socket:[")?.strip_suffix(']')?.parse::<u64>().ok()
        })
        .collect()
}

/// Inodes of every TCP socket in LISTEN state (state 0A) in this
/// network namespace.
fn listening_tcp_inodes() -> HashSet<u64> {
    ["/proc/self/net/tcp", "/proc/self/net/tcp6"]
        .iter()
        .filter_map(|table| std::fs::read_to_string(table).ok())
        .flat_map(|table| {
            table
                .lines()
                .skip(1)
                .filter_map(|row| {
                    let fields: Vec<&str> = row.split_whitespace().collect();
                    (fields.get(3) == Some(&"0A"))
                        .then(|| fields.get(9)?.parse::<u64>().ok())
                        .flatten()
                })
                .collect::<Vec<_>>()
        })
        .collect()
}

fn process_alive(pid: u32) -> bool {
    Path::new(&format!("/proc/{pid}")).exists()
}

#[tokio::test]
#[ignore = "requires docker"]
async fn password_through_prompter() {
    let fixture = start().await.unwrap();
    let (session, prompter) = connect(&fixture, SshAuth::Agent, vec![accept(), answer("s3cret")]).await;
    let session = session.unwrap();

    assert!(session.master_pid().is_some_and(process_alive));
    let purposes: Vec<PromptPurpose> = prompter.requests().into_iter().map(|request| request.purpose).collect();
    assert!(matches!(purposes[0], PromptPurpose::SshHostKeyConfirmation { .. }));
    assert!(matches!(purposes[1], PromptPurpose::SshPassword { .. }));
    assert!(
        std::fs::read_to_string(&fixture.known_hosts)
            .unwrap()
            .contains(&format!("]:{} ", fixture.port))
    );
    session.shutdown(Duration::from_secs(5)).await;
    assert!(session.is_closed());
}

#[tokio::test]
#[ignore = "requires docker"]
async fn unknown_host_declined_is_host_key_unknown_declined() {
    let fixture = start().await.unwrap();
    let (session, _) = connect(&fixture, SshAuth::Agent, vec![PromptReply::Cancelled]).await;
    assert!(matches!(
        session.unwrap_err(),
        TransportError::Ssh(SshFailure::HostKeyUnknown { declined: true, .. })
    ));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_user_config_that_skips_the_host_key_check_still_asks() {
    let fixture = start().await.unwrap();
    for strict in ["no", "accept-new"] {
        write_config(&fixture.config, &fixture.known_hosts, strict).unwrap();
        if let Err(error) = std::fs::remove_file(&fixture.known_hosts) {
            assert_eq!(error.kind(), std::io::ErrorKind::NotFound, "{error}");
        }

        let (session, prompter) = connect(&fixture, password_auth(), vec![PromptReply::Cancelled]).await;

        assert!(
            matches!(
                session,
                Err(TransportError::Ssh(SshFailure::HostKeyUnknown { declined: true, .. }))
            ),
            "StrictHostKeyChecking {strict} trusted the key without asking"
        );
        let purposes: Vec<PromptPurpose> = prompter.requests().into_iter().map(|request| request.purpose).collect();
        assert!(
            matches!(purposes.as_slice(), [PromptPurpose::SshHostKeyConfirmation { .. }]),
            "{strict}: {purposes:?}"
        );
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_user_config_that_requires_a_known_key_refuses_without_asking() {
    let fixture = start().await.unwrap();
    write_config(&fixture.config, &fixture.known_hosts, "yes").unwrap();

    let (session, prompter) = connect(&fixture, password_auth(), Vec::new()).await;

    assert!(
        matches!(
            session,
            Err(TransportError::Ssh(SshFailure::HostKeyUnknown {
                trust_allowed: false,
                declined: false,
                ..
            }))
        ),
        "{session:?}"
    );
    assert!(prompter.requests().is_empty(), "{:?}", prompter.requests());
    assert!(!fixture.known_hosts.exists(), "the key was trusted");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn wrong_password_is_authentication_rejected() {
    let fixture = start().await.unwrap();
    let auth = SshAuth::Password {
        password: SecretString::from("wrong"),
    };
    let (session, _) = connect(&fixture, auth, vec![accept()]).await;
    assert!(matches!(
        session.unwrap_err(),
        TransportError::Ssh(SshFailure::AuthenticationRejected { .. })
    ));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn forward_reaches_sshd_and_socket_is_0600() {
    let fixture = start().await.unwrap();
    let auth = SshAuth::Password {
        password: SecretString::from("s3cret"),
    };
    let (session, _) = connect(&fixture, auth, vec![accept()]).await;
    let session = session.unwrap();

    let target = NetworkEndpoint::new("127.0.0.1", 2222).unwrap();
    let transport = session.forward(target, &LivenessPolicy::DESKTOP).await.unwrap();
    let TransportRoute::UnixSocket(socket) = transport.route() else {
        panic!("an ssh forward routes through a unix socket");
    };
    assert_eq!(std::fs::metadata(&socket).unwrap().permissions().mode() & 0o777, 0o600);

    let mut stream = transport.open().await.unwrap();
    let mut banner = [0u8; 8];
    stream.read_exact(&mut banner).await.unwrap();
    assert_eq!(&banner, b"SSH-2.0-");

    drop(stream);
    drop(transport);
    session.shutdown(Duration::from_secs(5)).await;
}

#[tokio::test]
#[ignore = "requires docker"]
async fn killing_master_fires_closed() {
    let fixture = start().await.unwrap();
    let auth = SshAuth::Password {
        password: SecretString::from("s3cret"),
    };
    let (session, _) = connect(&fixture, auth, vec![accept()]).await;
    let session = session.unwrap();
    let pid = session.master_pid().unwrap();

    let killed = std::process::Command::new("kill")
        .arg(pid.to_string())
        .status()
        .unwrap();
    assert!(killed.success());
    tokio::time::timeout(Duration::from_secs(10), session.closed())
        .await
        .unwrap();
    assert!(session.is_closed());
}

#[tokio::test]
#[ignore = "requires docker"]
async fn dropping_last_arc_ends_master() {
    let fixture = start().await.unwrap();
    let auth = SshAuth::Password {
        password: SecretString::from("s3cret"),
    };
    let (session, _) = connect(&fixture, auth, vec![accept()]).await;
    let session = session.unwrap();
    let pid = session.master_pid().unwrap();

    std::thread::spawn(move || drop(session)).join().unwrap();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
    while process_alive(pid) && tokio::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(!process_alive(pid));
}

#[tokio::test]
#[ignore = "requires docker"]
async fn changed_key_reports_file_and_line_then_forget_allows_new_key() {
    let fixture = start().await.unwrap();
    let keys = tempfile::tempdir().unwrap();
    let stale_key = keys.path().join("stale");
    let generated = std::process::Command::new("ssh-keygen")
        .args(["-q", "-t", "ed25519", "-N", "", "-f"])
        .arg(&stale_key)
        .status()
        .unwrap();
    assert!(generated.success());
    let public = std::fs::read_to_string(stale_key.with_extension("pub")).unwrap();
    let mut fields = public.split_whitespace();
    let entry = format!(
        "[{}]:{} {} {}\n",
        fixture.host,
        fixture.port,
        fields.next().unwrap(),
        fields.next().unwrap()
    );
    std::fs::write(&fixture.known_hosts, entry).unwrap();

    let auth = SshAuth::Password {
        password: SecretString::from("s3cret"),
    };
    let (session, _) = connect(&fixture, auth.clone(), Vec::new()).await;
    let TransportError::Ssh(SshFailure::HostKeyChanged { known_hosts, line, .. }) = session.unwrap_err() else {
        panic!("expected a changed host key");
    };
    assert_eq!(known_hosts, fixture.known_hosts);
    assert_eq!(line, 1);

    forget_host_key(
        &fixture.services,
        &config(&fixture, auth.clone()).unwrap(),
        &fixture.known_hosts,
    )
    .await
    .unwrap();
    let (session, prompter) = connect(&fixture, auth, vec![accept()]).await;
    assert!(session.is_ok());
    assert_eq!(prompter.requests().len(), 1);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn first_hop_is_the_destination_ssh_resolved() {
    let fixture = start().await.unwrap();
    let (session, _) = connect(&fixture, password_auth(), vec![accept()]).await;
    let session = session.unwrap();

    let first_hop = session.first_hop_endpoint().unwrap();

    assert_eq!(first_hop.port(), fixture.port);
    assert_eq!(first_hop.host(), fixture.host);
}

/// OpenSSH runs a jump host through a second ssh that never sees the
/// master's `-o` options, so a configuration that trusts new keys for
/// every host would trust the jump host's without the dialog.
#[tokio::test]
#[ignore = "requires docker"]
async fn a_jump_host_whose_config_skips_the_host_key_check_still_asks() {
    let fixture = start().await.unwrap();
    write_config(&fixture.config, &fixture.known_hosts, "accept-new").unwrap();
    let services = SshServices {
        ssh_program: PathBuf::from("ssh"),
        config_file: Some(fixture.config.clone()),
        ..fixture.services.clone()
    };

    jump_host_asks(&fixture, &services).await.unwrap();
}

/// The same with no `-F`, as the app runs: the pinned file includes the
/// user's `~/.ssh/config` and copies in the system's. ssh looks the user
/// file up in the password database but an `Include` follows `HOME`, so
/// the wrapper hands the file to the lookups with `-F` and to the
/// `Include` through `HOME`. The pinned file's own `-F` comes last on
/// the master's command line and wins.
#[tokio::test]
#[ignore = "requires docker"]
async fn a_jump_host_whose_user_config_skips_the_host_key_check_still_asks() {
    let fixture = start().await.unwrap();
    let home = fixture.temp.path().join("home");
    std::fs::create_dir_all(home.join(".ssh")).unwrap();
    let user_config = home.join(".ssh").join("config");
    write_config(&user_config, &fixture.known_hosts, "accept-new").unwrap();
    // An Include refuses a file others can write.
    std::fs::set_permissions(&user_config, std::fs::Permissions::from_mode(0o600)).unwrap();
    let wrapper = fixture.temp.path().join("ssh-as-user");
    std::fs::write(
        &wrapper,
        format!(
            "#!/bin/sh\nHOME='{}' exec ssh -F '{}' \"$@\"\n",
            home.display(),
            user_config.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o755)).unwrap();
    let services = SshServices {
        ssh_program: wrapper,
        config_file: None,
        ..fixture.services.clone()
    };

    jump_host_asks(&fixture, &services).await.unwrap();
}

async fn jump_host_asks(fixture: &Fixture, services: &SshServices) -> TestResult<()> {
    let config = SshConfig {
        // sshd reaches itself on its own port, so one container is both
        // the jump host and the destination behind it.
        destination: SshDestination::new("127.0.0.1", Some(2222), Some("deploy".to_owned()))?,
        jump_hosts: vec![SshDestination::new(
            &fixture.host,
            Some(fixture.port),
            Some("deploy".to_owned()),
        )?],
        auth: SshAuth::Agent,
    };
    let prompter = Arc::new(FakePrompter::new(vec![
        accept(),
        answer("s3cret"),
        accept(),
        answer("s3cret"),
    ]));

    let session = SshSession::connect(
        &config,
        services,
        &LivenessPolicy::DESKTOP,
        CredentialInteraction::Attended(prompter.clone()),
        CancellationToken::new(),
    )
    .await;

    let purposes: Vec<PromptPurpose> = prompter.requests().into_iter().map(|request| request.purpose).collect();
    let jump = format!("]:{}", fixture.port);
    assert!(
        matches!(
            purposes.as_slice(),
            [
                PromptPurpose::SshHostKeyConfirmation { host, .. },
                PromptPurpose::SshPassword { .. },
                PromptPurpose::SshHostKeyConfirmation { .. },
                PromptPurpose::SshPassword { .. },
            ] if host.ends_with(&jump)
        ),
        "{purposes:?}"
    );
    let session = session?;
    assert_eq!(
        session.first_hop_endpoint(),
        Some(&NetworkEndpoint::new(&fixture.host, fixture.port)?)
    );
    session.shutdown(Duration::from_secs(5)).await;
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn no_loopback_listener_while_tunnelled() {
    let fixture = start().await.unwrap();
    let (session, _) = connect(&fixture, password_auth(), vec![accept()]).await;
    let session = session.unwrap();
    let target = NetworkEndpoint::new("127.0.0.1", 2222).unwrap();
    let transport = session.forward(target, &LivenessPolicy::DESKTOP).await.unwrap();
    let _stream = transport.open().await.unwrap();

    let listening = listening_tcp_inodes();
    let master = session.master_pid().unwrap().to_string();
    let ours: HashSet<u64> = socket_inodes("self").union(&socket_inodes(&master)).copied().collect();

    assert!(
        ours.is_disjoint(&listening),
        "a TCP listener carries the tunnel: {:?}",
        ours.intersection(&listening).collect::<Vec<_>>()
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn reroute_reuses_session() {
    let fixture = start().await.unwrap();
    let (session, _) = connect(&fixture, password_auth(), vec![accept()]).await;
    let session = session.unwrap();
    let pid = session.master_pid().unwrap();
    let first = session
        .forward(
            NetworkEndpoint::new("127.0.0.1", 2222).unwrap(),
            &LivenessPolicy::DESKTOP,
        )
        .await
        .unwrap();

    let rerouted = first
        .reroute(NetworkEndpoint::new("localhost", 2222).unwrap())
        .await
        .unwrap();

    let (TransportRoute::UnixSocket(first_socket), TransportRoute::UnixSocket(second_socket)) =
        (first.route(), rerouted.route())
    else {
        panic!("an ssh forward routes through a unix socket");
    };
    assert_ne!(first_socket, second_socket);
    assert_eq!(
        first_socket.parent(),
        second_socket.parent(),
        "the reroute started another master"
    );
    assert_eq!(session.master_pid(), Some(pid));
    let mut stream = rerouted.open().await.unwrap();
    let mut banner = [0u8; 8];
    stream.read_exact(&mut banner).await.unwrap();
    assert_eq!(&banner, b"SSH-2.0-");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn cancel_during_handshake_returns_cancelled() {
    let fixture = start().await.unwrap();
    let prompter = Arc::new(FakePrompter::new([accept()]).with_delay(Duration::from_secs(60)));
    let cancel = CancellationToken::new();
    let cancelling = {
        let cancel = cancel.clone();
        async move {
            tokio::time::sleep(Duration::from_secs(1)).await;
            cancel.cancel();
        }
    };

    let started = tokio::time::Instant::now();
    let (outcome, ()) = tokio::join!(
        connect_with(
            &fixture,
            SshAuth::Agent,
            &LivenessPolicy::DESKTOP,
            CredentialInteraction::Attended(prompter.clone()),
            cancel,
        ),
        cancelling,
    );

    assert!(matches!(
        outcome,
        Err(TransportError::Ssh(SshFailure::InteractionCancelled))
    ));
    assert!(started.elapsed() < Duration::from_secs(10));
    assert_eq!(prompter.requests().len(), 1, "the cancel came before the prompt");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn keepalive_detects_black_hole() {
    let fixture = start().await.unwrap();
    let liveness = LivenessPolicy {
        ssh_keepalive_interval: Duration::from_secs(1),
        ssh_keepalive_max: 2,
        ..LivenessPolicy::DESKTOP
    };
    let prompter = Arc::new(FakePrompter::new([accept()]));
    let session = connect_with(
        &fixture,
        password_auth(),
        &liveness,
        CredentialInteraction::Attended(prompter),
        CancellationToken::new(),
    )
    .await
    .unwrap();

    fixture.container.pause().await.unwrap();
    let closed = tokio::time::timeout(Duration::from_secs(5), session.closed()).await;
    fixture.container.unpause().await.unwrap();

    assert!(
        closed.is_ok(),
        "a paused server was not noticed within the keepalive window"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn session_closed_fires_when_bastion_stops() {
    let fixture = start().await.unwrap();
    let (session, _) = connect(&fixture, password_auth(), vec![accept()]).await;
    let session = session.unwrap();

    fixture.container.stop_with_timeout(Some(5)).await.unwrap();

    tokio::time::timeout(Duration::from_secs(30), session.closed())
        .await
        .unwrap();
    assert!(session.is_closed());
}
