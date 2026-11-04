// Host keys, jump hosts and the session's end for the in-process transport, against a real sshd.

use std::error::Error;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use secrecy::SecretString;
use tablepro_core::credentials::{CredentialInteraction, PromptPurpose, PromptReply};
use tablepro_core::{LivenessPolicy, NetworkEndpoint, SshFailure, TransportError};
use tablepro_ssh::{ForgetHostKeyError, InProcessSession, InProcessSsh, SshAuth, SshConfig, SshDestination};
use tablepro_test_fixtures::{OpenSshFixture, SshAuthVariant};
use tablepro_test_support::FakePrompter;
use tokio::io::AsyncReadExt;
use tokio_util::sync::CancellationToken;

type TestResult<T = ()> = Result<T, Box<dyn Error>>;

struct Bastion {
    fixture: OpenSshFixture,
    services: InProcessSsh,
    known_hosts: PathBuf,
    _dir: tempfile::TempDir,
}

impl Bastion {
    async fn start() -> TestResult<Self> {
        Self::start_with(SshAuthVariant::Password).await
    }

    async fn start_with(variant: SshAuthVariant) -> TestResult<Self> {
        let fixture = OpenSshFixture::start(variant).await?;
        let dir = tempfile::tempdir()?;
        let known_hosts = dir.path().join(".ssh").join("known_hosts");
        let services = InProcessSsh {
            user_known_hosts: Some(known_hosts.clone()),
            other_known_hosts: Vec::new(),
            identity_files: Vec::new(),
            agent: None,
            pageant: false,
        };
        Ok(Self {
            fixture,
            services,
            known_hosts,
            _dir: dir,
        })
    }

    fn user(&self) -> String {
        self.fixture.password_credentials().username
    }

    fn name(&self) -> String {
        format!("[{}]:{}", self.fixture.host(), self.fixture.port())
    }

    fn config(&self) -> TestResult<SshConfig> {
        Ok(SshConfig {
            destination: SshDestination::new(self.fixture.host(), Some(self.fixture.port()), Some(self.user()))?,
            jump_hosts: Vec::new(),
            auth: SshAuth::Password {
                password: SecretString::from(self.fixture.password_credentials().password),
            },
        })
    }

    async fn connect(
        &self,
        config: &SshConfig,
        liveness: &LivenessPolicy,
        replies: Vec<PromptReply>,
    ) -> (Result<Arc<InProcessSession>, TransportError>, Arc<FakePrompter>) {
        let prompter = Arc::new(FakePrompter::new(replies));
        let session = InProcessSession::connect(
            config,
            &self.services,
            liveness,
            CredentialInteraction::Attended(prompter.clone()),
            CancellationToken::new(),
        )
        .await;
        (session, prompter)
    }
}

fn accept() -> PromptReply {
    PromptReply::Submitted {
        values: Vec::new(),
        remember: false,
    }
}

fn purposes(prompter: &FakePrompter) -> Vec<PromptPurpose> {
    prompter.requests().into_iter().map(|request| request.purpose).collect()
}

async fn banner(session: &Arc<InProcessSession>) -> TestResult<[u8; 8]> {
    let target = NetworkEndpoint::new("127.0.0.1", OpenSshFixture::CONTAINER_PORT)?;
    let transport = session.forward(target, &LivenessPolicy::DESKTOP).await?;
    let mut stream = transport.open().await?;
    let mut banner = [0_u8; 8];
    stream.read_exact(&mut banner).await?;
    Ok(banner)
}

#[tokio::test]
#[ignore = "requires docker"]
async fn an_unknown_host_key_is_asked_about_once_then_recorded() -> TestResult {
    let bastion = Bastion::start().await?;
    let config = bastion.config()?;

    let (first, asked) = bastion.connect(&config, &LivenessPolicy::DESKTOP, vec![accept()]).await;
    let (second, again) = bastion.connect(&config, &LivenessPolicy::DESKTOP, Vec::new()).await;

    assert!(matches!(
        purposes(&asked).as_slice(),
        [PromptPurpose::SshHostKeyConfirmation { host, algorithm, fingerprint }]
            if *host == bastion.name() && !algorithm.is_empty() && fingerprint.starts_with("SHA256:")
    ));
    assert!(again.requests().is_empty(), "{:?}", again.requests());
    assert_eq!(&banner(&first?).await?, b"SSH-2.0-");
    assert_eq!(&banner(&second?).await?, b"SSH-2.0-");
    let recorded = std::fs::read_to_string(&bastion.known_hosts)?;
    assert!(recorded.starts_with(&format!("{} ", bastion.name())), "{recorded}");
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_host_certificate_from_a_listed_authority_is_trusted_without_a_question() -> TestResult {
    let bastion = Bastion::start_with(SshAuthVariant::HostCertificate).await?;
    let authority = bastion
        .fixture
        .host_certificate()
        .ok_or("the server has no host certificate")?
        .known_hosts_line(bastion.fixture.host(), bastion.fixture.port());
    std::fs::create_dir_all(bastion.known_hosts.parent().ok_or("no parent")?)?;
    std::fs::write(&bastion.known_hosts, authority)?;

    let session = InProcessSession::connect(
        &bastion.config()?,
        &bastion.services,
        &LivenessPolicy::DESKTOP,
        CredentialInteraction::Unattended,
        CancellationToken::new(),
    )
    .await?;

    assert_eq!(&banner(&session).await?, b"SSH-2.0-");
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn an_unattended_connect_to_an_unknown_host_is_refused_with_the_key_to_review() -> TestResult {
    let bastion = Bastion::start().await?;

    let refused = InProcessSession::connect(
        &bastion.config()?,
        &bastion.services,
        &LivenessPolicy::DESKTOP,
        CredentialInteraction::Unattended,
        CancellationToken::new(),
    )
    .await;

    let Err(TransportError::Ssh(SshFailure::HostKeyUnknown {
        host,
        sha256_fingerprint,
        trust_allowed: true,
        declined: true,
        ..
    })) = &refused
    else {
        return Err(format!("expected an unknown host key, got {refused:?}").into());
    };
    assert_eq!(*host, bastion.name());
    assert!(sha256_fingerprint.starts_with("SHA256:"));
    assert!(!bastion.known_hosts.exists());
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_changed_key_names_its_line_and_forgetting_it_lets_the_new_key_be_trusted() -> TestResult {
    let bastion = Bastion::start().await?;
    let config = bastion.config()?;
    // An Ed25519 key that is not the server's, which offers Ed25519 first as russh prefers it.
    let stale = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILM+rvN+ot98qgEN796jTiQfZfG1KaT0PtFDJ/XFSqti";
    std::fs::create_dir_all(bastion.known_hosts.parent().ok_or("no parent")?)?;
    std::fs::write(&bastion.known_hosts, format!("# kept\n{} {stale}\n", bastion.name()))?;

    let (changed, asked) = bastion.connect(&config, &LivenessPolicy::DESKTOP, Vec::new()).await;
    let Err(TransportError::Ssh(SshFailure::HostKeyChanged {
        host,
        known_hosts,
        line,
        trust_allowed: true,
        ..
    })) = &changed
    else {
        return Err(format!("expected a changed host key, got {changed:?}").into());
    };
    assert!(asked.requests().is_empty());
    assert_eq!((known_hosts, *line), (&bastion.known_hosts, 2));
    let other = bastion
        .services
        .forget_changed_host_key(&config, "other.example", known_hosts)
        .await;
    assert!(matches!(other, Err(ForgetHostKeyError::NotThisConnection { .. })));
    bastion
        .services
        .forget_changed_host_key(&config, host, known_hosts)
        .await?;

    let (session, asked) = bastion.connect(&config, &LivenessPolicy::DESKTOP, vec![accept()]).await;

    assert_eq!(&banner(&session?).await?, b"SSH-2.0-");
    assert_eq!(asked.requests().len(), 1);
    assert!(std::fs::read_to_string(&bastion.known_hosts)?.starts_with("# kept\n"));
    Ok(())
}

// sshd reaches itself on its own port, so one container is the jump host and the destination behind it.
#[tokio::test]
#[ignore = "requires docker"]
async fn a_jump_host_asks_for_its_own_key_and_password_and_never_gets_the_destinations() -> TestResult {
    let bastion = Bastion::start().await?;
    let password = bastion.fixture.password_credentials().password;
    let config = SshConfig {
        destination: SshDestination::new("127.0.0.1", Some(OpenSshFixture::CONTAINER_PORT), Some(bastion.user()))?,
        jump_hosts: vec![SshDestination::new(
            bastion.fixture.host(),
            Some(bastion.fixture.port()),
            Some(bastion.user()),
        )?],
        auth: SshAuth::Password {
            password: SecretString::from(password.clone()),
        },
    };
    let typed = PromptReply::Submitted {
        values: vec![SecretString::from(password)],
        remember: false,
    };

    let (session, prompter) = bastion
        .connect(&config, &LivenessPolicy::DESKTOP, vec![accept(), typed, accept()])
        .await;

    let requests = prompter.requests();
    assert!(
        matches!(
            purposes(&prompter).as_slice(),
            [
                PromptPurpose::SshHostKeyConfirmation { host: jump, .. },
                PromptPurpose::SshPassword { .. },
                PromptPurpose::SshHostKeyConfirmation { host: destination, .. },
            ] if *jump == bastion.name() && destination == "[127.0.0.1]:2222"
        ),
        "{requests:?}"
    );
    assert_eq!(
        requests[1].target,
        format!("{}@{}", bastion.user(), bastion.fixture.host())
    );
    let session = session?;
    assert_eq!(
        session.first_hop_endpoint(),
        &NetworkEndpoint::new(bastion.fixture.host(), bastion.fixture.port())?
    );
    assert_eq!(&banner(&session).await?, b"SSH-2.0-");
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn keepalives_end_the_session_when_the_server_stops_answering() -> TestResult {
    let bastion = Bastion::start().await?;
    let liveness = LivenessPolicy {
        ssh_keepalive_interval: Duration::from_secs(1),
        ssh_keepalive_max: 2,
        ..LivenessPolicy::DESKTOP
    };
    let (session, _) = bastion.connect(&bastion.config()?, &liveness, vec![accept()]).await;
    let session = session?;

    bastion.fixture.container().pause().await?;
    let closed = tokio::time::timeout(Duration::from_secs(10), session.closed()).await;
    bastion.fixture.container().unpause().await?;

    assert!(
        closed.is_ok(),
        "a paused server was not noticed within the keepalive window"
    );
    let target = NetworkEndpoint::new("127.0.0.1", OpenSshFixture::CONTAINER_PORT)?;
    assert!(matches!(
        session.forward(target, &liveness).await,
        Err(TransportError::Ssh(SshFailure::MasterExited { status: None, .. }))
    ));
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn the_session_ends_when_the_bastion_stops_and_a_reroute_shares_it_until_then() -> TestResult {
    let bastion = Bastion::start().await?;
    let (session, _) = bastion
        .connect(&bastion.config()?, &LivenessPolicy::DESKTOP, vec![accept()])
        .await;
    let session = session?;
    let first = session
        .forward(NetworkEndpoint::new("127.0.0.1", 1)?, &LivenessPolicy::DESKTOP)
        .await?;
    let refused = first.open().await.err();
    let rerouted = first
        .reroute(NetworkEndpoint::new("127.0.0.1", OpenSshFixture::CONTAINER_PORT)?)
        .await?;
    let mut stream = rerouted.open().await?;
    let mut banner = [0_u8; 8];
    stream.read_exact(&mut banner).await?;

    bastion.fixture.container().stop_with_timeout(Some(5)).await?;
    tokio::time::timeout(Duration::from_secs(30), session.closed()).await?;

    assert!(
        matches!(&refused, Some(TransportError::Ssh(SshFailure::ChannelOpenFailed { target, .. })) if target == "127.0.0.1:1"),
        "{refused:?}"
    );
    assert_eq!(&banner, b"SSH-2.0-");
    assert!(session.is_closed());
    assert!(rerouted.explain_closed_stream().await.is_some());
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_cancel_while_the_user_is_asked_ends_the_connect() -> TestResult {
    let bastion = Bastion::start().await?;
    let prompter = Arc::new(FakePrompter::new([accept()]).with_delay(Duration::from_secs(60)));
    let cancel = CancellationToken::new();
    let cancelling = cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(2)).await;
        cancelling.cancel();
    });

    let connected = InProcessSession::connect(
        &bastion.config()?,
        &bastion.services,
        &LivenessPolicy::DESKTOP,
        CredentialInteraction::Attended(prompter),
        cancel,
    )
    .await;

    assert!(matches!(
        connected,
        Err(TransportError::Ssh(SshFailure::InteractionCancelled))
    ));
    Ok(())
}
