#![cfg(windows)]
// The in-process transport against Windows' own OpenSSH Server and agent, which
// scripts/ci/start-windows-sshd.ps1 starts on the core workflow's Windows runners.

use std::error::Error;
use std::path::PathBuf;
use std::sync::Arc;

use secrecy::SecretString;
use tablepro_core::credentials::{CredentialInteraction, PromptPurpose, PromptReply};
use tablepro_core::{LivenessPolicy, NetworkEndpoint, SshFailure, TransportError};
use tablepro_ssh::{InProcessSession, InProcessSsh, SshAuth, SshConfig, SshDestination};
use tablepro_test_support::FakePrompter;
use tokio::io::AsyncReadExt;
use tokio_util::sync::CancellationToken;

type TestResult<T = ()> = Result<T, Box<dyn Error>>;

const SSHD: &str = "127.0.0.1";

fn setting(name: &str) -> TestResult<String> {
    std::env::var(name).map_err(|_| format!("{name} is not set; run scripts/ci/start-windows-sshd.ps1").into())
}

struct Machine {
    services: InProcessSsh,
    user: String,
    _dir: tempfile::TempDir,
}

impl Machine {
    fn new() -> TestResult<Self> {
        let dir = tempfile::tempdir()?;
        let system = InProcessSsh::system();
        Ok(Self {
            services: InProcessSsh {
                user_known_hosts: Some(dir.path().join("known_hosts")),
                other_known_hosts: Vec::new(),
                identity_files: Vec::new(),
                ..system
            },
            user: setting("TABLEPRO_TEST_SSHD_USER")?,
            _dir: dir,
        })
    }

    fn config(&self, auth: SshAuth) -> TestResult<SshConfig> {
        Ok(SshConfig {
            destination: SshDestination::new(SSHD, Some(22), Some(self.user.clone()))?,
            jump_hosts: Vec::new(),
            auth,
        })
    }

    async fn connect(
        &self,
        config: &SshConfig,
        replies: Vec<PromptReply>,
    ) -> (Result<Arc<InProcessSession>, TransportError>, Arc<FakePrompter>) {
        let prompter = Arc::new(FakePrompter::new(replies));
        let session = InProcessSession::connect(
            config,
            &self.services,
            &LivenessPolicy::DESKTOP,
            CredentialInteraction::Attended(prompter.clone()),
            CancellationToken::new(),
        )
        .await;
        (session, prompter)
    }
}

// What the user was asked says which login step the server refused.
fn explained(
    session: Result<Arc<InProcessSession>, TransportError>,
    prompter: &FakePrompter,
) -> TestResult<Arc<InProcessSession>> {
    session.map_err(|error| {
        let asked: Vec<PromptPurpose> = prompter.requests().into_iter().map(|request| request.purpose).collect();
        format!("{error:?}, after asking {asked:?}").into()
    })
}

fn accept() -> PromptReply {
    PromptReply::Submitted {
        values: Vec::new(),
        remember: false,
    }
}

// sshd's own port answers with its banner, so a forward that carries bytes needs no database.
async fn assert_tunnel_answers(session: &Arc<InProcessSession>) -> TestResult {
    let transport = session
        .forward(NetworkEndpoint::new(SSHD, 22)?, &LivenessPolicy::DESKTOP)
        .await?;
    let mut stream = transport.open().await?;
    let mut banner = [0_u8; 8];
    stream.read_exact(&mut banner).await?;
    assert_eq!(&banner, b"SSH-2.0-");
    Ok(())
}

#[tokio::test]
#[ignore = "needs the OpenSSH Server scripts/ci/start-windows-sshd.ps1 starts"]
async fn a_password_signs_in_after_the_host_key_is_confirmed() -> TestResult {
    let machine = Machine::new()?;
    let config = machine.config(SshAuth::Password {
        password: SecretString::from(setting("TABLEPRO_TEST_SSHD_PASSWORD")?),
    })?;

    let (session, prompter) = machine.connect(&config, vec![accept()]).await;

    let session = explained(session, &prompter)?;
    assert!(matches!(
        prompter.requests().first().map(|request| &request.purpose),
        Some(PromptPurpose::SshHostKeyConfirmation { host, .. }) if host == SSHD
    ));
    assert_tunnel_answers(&session).await
}

#[tokio::test]
#[ignore = "needs the OpenSSH Server scripts/ci/start-windows-sshd.ps1 starts"]
async fn a_key_file_with_a_passphrase_signs_in() -> TestResult {
    let machine = Machine::new()?;
    let config = machine.config(SshAuth::PrivateKey {
        path: Some(PathBuf::from(setting("TABLEPRO_TEST_SSHD_LOCKED_KEY")?)),
        passphrase: Some(SecretString::from(setting("TABLEPRO_TEST_SSHD_PASSPHRASE")?)),
    })?;

    let (session, prompter) = machine.connect(&config, vec![accept()]).await;

    assert_tunnel_answers(&explained(session, &prompter)?).await
}

#[tokio::test]
#[ignore = "needs the OpenSSH Server scripts/ci/start-windows-sshd.ps1 starts"]
async fn the_windows_ssh_agent_signs_in() -> TestResult {
    let machine = Machine::new()?;
    let config = machine.config(SshAuth::Agent)?;

    let (session, prompter) = machine.connect(&config, vec![accept()]).await;

    assert_tunnel_answers(&explained(session, &prompter)?).await
}

#[tokio::test]
#[ignore = "needs the OpenSSH Server scripts/ci/start-windows-sshd.ps1 starts"]
async fn a_key_file_signs_in_through_a_jump_host() -> TestResult {
    let machine = Machine::new()?;
    let config = SshConfig {
        destination: SshDestination::new("localhost", Some(22), Some(machine.user.clone()))?,
        jump_hosts: vec![SshDestination::new(SSHD, Some(22), Some(machine.user.clone()))?],
        auth: SshAuth::PrivateKey {
            path: Some(PathBuf::from(setting("TABLEPRO_TEST_SSHD_KEY")?)),
            passphrase: None,
        },
    };

    let (session, prompter) = machine.connect(&config, vec![accept(), accept()]).await;
    let session = explained(session, &prompter)?;

    let hosts: Vec<String> = prompter
        .requests()
        .into_iter()
        .filter_map(|request| match request.purpose {
            PromptPurpose::SshHostKeyConfirmation { host, .. } => Some(host),
            _ => None,
        })
        .collect();
    assert_eq!(hosts, [SSHD, "localhost"]);
    assert_tunnel_answers(&session).await
}

#[tokio::test]
#[ignore = "needs the OpenSSH Server scripts/ci/start-windows-sshd.ps1 starts"]
async fn a_rejected_password_asks_again_and_a_cancel_ends_the_login() -> TestResult {
    let machine = Machine::new()?;
    let config = machine.config(SshAuth::Password {
        password: SecretString::from("wrong"),
    })?;

    let (session, prompter) = machine.connect(&config, vec![accept(), PromptReply::Cancelled]).await;

    assert!(
        matches!(&session, Err(TransportError::Ssh(SshFailure::InteractionCancelled))),
        "{session:?}"
    );
    assert!(matches!(
        prompter.requests().get(1).map(|request| &request.purpose),
        Some(PromptPurpose::SshPassword { .. })
    ));
    Ok(())
}
