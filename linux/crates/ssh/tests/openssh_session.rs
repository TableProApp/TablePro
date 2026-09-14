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
    _container: ContainerAsync<GenericImage>,
    _temp: tempfile::TempDir,
    host: String,
    port: u16,
    known_hosts: PathBuf,
    services: SshServices,
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
    std::fs::write(
        &config,
        format!(
            "Host *\n  UserKnownHostsFile {}\n  GlobalKnownHostsFile /dev/null\n  StrictHostKeyChecking ask\n  IdentityAgent none\n  IdentitiesOnly yes\n  PubkeyAuthentication no\n",
            known_hosts.display()
        ),
    )?;
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
    };
    Ok(Fixture {
        _container: container,
        _temp: temp,
        host,
        port,
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
    let result = match config(fixture, auth) {
        Ok(config) => {
            SshSession::connect(
                &config,
                &fixture.services,
                &LivenessPolicy::DESKTOP,
                CredentialInteraction::Attended(prompter.clone()),
                CancellationToken::new(),
            )
            .await
        }
        Err(error) => Err(SshFailure::Protocol {
            detail: error.to_string(),
        }
        .into()),
    };
    (result, prompter)
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
