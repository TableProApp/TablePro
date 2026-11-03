#![cfg(unix)]
// The in-process transport against the OpenSSH server the system transport's tests use. The ssh-agent and
// ssh-keygen fixtures run on the host, so this runs where they do.

use std::error::Error;
use std::sync::Arc;

use secrecy::SecretString;
use tablepro_core::credentials::{CredentialInteraction, PromptPurpose, PromptReason, PromptReply};
use tablepro_core::{LivenessPolicy, NetworkEndpoint, SshFailure, TransportError, TransportRoute};
use tablepro_ssh::{InProcessSession, InProcessSsh, SshAuth, SshConfig, SshDestination};
use tablepro_test_fixtures::{OpenSshFixture, OpenSshOptions, SshAgent, SshAuthVariant, SshKeyPair, SshKeyType};
use tablepro_test_support::FakePrompter;
use tokio::io::AsyncReadExt;
use tokio_util::sync::CancellationToken;

type TestResult<T = ()> = Result<T, Box<dyn Error>>;

const PASSPHRASE: &str = "correct horse battery";

struct Server {
    fixture: OpenSshFixture,
    services: InProcessSsh,
    _dir: tempfile::TempDir,
}

impl Server {
    // known_hosts already trusts the server, and no agent is reachable unless a case names one.
    async fn start(variant: SshAuthVariant, options: OpenSshOptions, agent: Option<&SshAgent>) -> TestResult<Self> {
        let fixture = OpenSshFixture::start_with(variant, options, None).await?;
        let dir = tempfile::tempdir()?;
        let known_hosts = dir.path().join("known_hosts");
        let host_key = fixture.host_public_key().await?;
        std::fs::write(
            &known_hosts,
            format!("[{}]:{} {host_key}\n", fixture.host(), fixture.port()),
        )?;
        let services = InProcessSsh {
            user_known_hosts: Some(known_hosts),
            other_known_hosts: Vec::new(),
            identity_files: Vec::new(),
            agent: Some(agent.map_or_else(|| dir.path().join("no-agent.sock"), |agent| agent.socket().to_owned())),
            pageant: false,
        };
        Ok(Self {
            fixture,
            services,
            _dir: dir,
        })
    }

    fn key(&self) -> TestResult<&SshKeyPair> {
        match self.fixture.variant() {
            SshAuthVariant::PublicKey(key) => Ok(key),
            other => Err(format!("the server trusts no key: {other:?}").into()),
        }
    }

    fn config(&self, auth: SshAuth) -> TestResult<SshConfig> {
        Ok(SshConfig {
            destination: SshDestination::new(
                self.fixture.host(),
                Some(self.fixture.port()),
                Some(self.fixture.password_credentials().username),
            )?,
            jump_hosts: Vec::new(),
            auth,
        })
    }

    // Every secret a case needs is stored, so a prompt is a failure.
    async fn connect(&self, auth: SshAuth) -> TestResult<Result<Arc<InProcessSession>, TransportError>> {
        let prompter = Arc::new(FakePrompter::new(Vec::new()));
        let session = self.connect_asking(auth, prompter.clone()).await?;
        assert!(prompter.requests().is_empty(), "{:?}", prompter.requests());
        Ok(session)
    }

    async fn connect_asking(
        &self,
        auth: SshAuth,
        prompter: Arc<FakePrompter>,
    ) -> TestResult<Result<Arc<InProcessSession>, TransportError>> {
        Ok(InProcessSession::connect(
            &self.config(auth)?,
            &self.services,
            &LivenessPolicy::DESKTOP,
            CredentialInteraction::Attended(prompter),
            CancellationToken::new(),
        )
        .await)
    }

    fn password(&self) -> SshAuth {
        SshAuth::Password {
            password: SecretString::from(self.fixture.password_credentials().password),
        }
    }
}

fn key_file(key: &SshKeyPair) -> SshAuth {
    SshAuth::PrivateKey {
        path: Some(key.private_key().to_owned()),
        passphrase: key.passphrase().map(SecretString::from),
    }
}

fn typed(text: &str) -> PromptReply {
    PromptReply::Submitted {
        values: vec![SecretString::from(text)],
        remember: false,
    }
}

// A forward to the server's own sshd answers with its banner, which proves the channel carries bytes.
async fn assert_tunnel_answers(session: &Arc<InProcessSession>) -> TestResult {
    let target = NetworkEndpoint::new("127.0.0.1", OpenSshFixture::CONTAINER_PORT)?;
    let transport = session.forward(target, &LivenessPolicy::DESKTOP).await?;
    assert_eq!(transport.route(), TransportRoute::InProcess);
    let mut stream = transport.open().await?;
    let mut banner = [0_u8; 8];
    stream.read_exact(&mut banner).await?;
    assert_eq!(&banner, b"SSH-2.0-");
    Ok(())
}

async fn key_signs_in(kind: SshKeyType, passphrase: Option<&str>, options: OpenSshOptions) -> TestResult {
    let key = SshKeyPair::generate_with(kind, passphrase, "tablepro-in-process").await?;
    let server = Server::start(SshAuthVariant::PublicKey(key), options, None).await?;

    let session = server.connect(key_file(server.key()?)).await??;

    assert_tunnel_answers(&session).await
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_stored_password_signs_in() -> TestResult {
    let server = Server::start(SshAuthVariant::Password, OpenSshOptions::selected()?, None).await?;

    let session = server.connect(server.password()).await??;

    assert_tunnel_answers(&session).await
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_rejected_password_asks_again_and_unattended_is_refused() -> TestResult {
    let server = Server::start(SshAuthVariant::Password, OpenSshOptions::selected()?, None).await?;
    let wrong = SshAuth::Password {
        password: SecretString::from("wrong"),
    };
    let prompter = Arc::new(FakePrompter::new([typed(
        &server.fixture.password_credentials().password,
    )]));

    let session = server.connect_asking(wrong.clone(), prompter.clone()).await??;
    let refused = InProcessSession::connect(
        &server.config(wrong)?,
        &server.services,
        &LivenessPolicy::DESKTOP,
        CredentialInteraction::Unattended,
        CancellationToken::new(),
    )
    .await;

    assert_tunnel_answers(&session).await?;
    let purposes: Vec<PromptPurpose> = prompter.requests().into_iter().map(|request| request.purpose).collect();
    assert_eq!(
        purposes,
        [PromptPurpose::SshPassword {
            reason: PromptReason::Rejected
        }]
    );
    assert!(
        matches!(&refused, Err(TransportError::Ssh(SshFailure::AuthenticationRejected { methods, .. })) if methods.contains(&"password".to_owned())),
        "{refused:?}"
    );
    Ok(())
}

// PAM asks through keyboard-interactive, and the stored password answers its one hidden prompt.
#[tokio::test]
#[ignore = "requires docker"]
async fn a_stored_password_answers_a_pam_prompt() -> TestResult {
    let server = Server::start(SshAuthVariant::KeyboardInteractive, OpenSshOptions::selected()?, None).await?;

    let session = server.connect(server.password()).await??;

    assert_tunnel_answers(&session).await
}

#[tokio::test]
#[ignore = "requires docker"]
async fn ed25519_key_signs_in() -> TestResult {
    key_signs_in(SshKeyType::Ed25519, None, OpenSshOptions::selected()?).await
}

#[tokio::test]
#[ignore = "requires docker"]
async fn ed25519_key_with_a_passphrase_signs_in() -> TestResult {
    key_signs_in(SshKeyType::Ed25519, Some(PASSPHRASE), OpenSshOptions::selected()?).await
}

#[tokio::test]
#[ignore = "requires docker"]
async fn rsa_key_signs_in_with_rsa_sha2_256() -> TestResult {
    let options = OpenSshOptions::selected()?.with_pubkey_accepted_algorithms("rsa-sha2-256");
    key_signs_in(SshKeyType::Rsa, Some(PASSPHRASE), options).await
}

#[tokio::test]
#[ignore = "requires docker"]
async fn rsa_key_signs_in_with_rsa_sha2_512() -> TestResult {
    let options = OpenSshOptions::selected()?.with_pubkey_accepted_algorithms("rsa-sha2-512");
    key_signs_in(SshKeyType::Rsa, None, options).await
}

#[tokio::test]
#[ignore = "requires docker"]
async fn ecdsa_p256_key_with_a_passphrase_signs_in() -> TestResult {
    key_signs_in(SshKeyType::EcdsaP256, Some(PASSPHRASE), OpenSshOptions::selected()?).await
}

// The PEM format keeps no public half in the clear, so the passphrase opens it.
#[tokio::test]
#[ignore = "requires docker"]
async fn an_encrypted_pem_rsa_key_signs_in() -> TestResult {
    let key = SshKeyPair::generate_with(SshKeyType::Rsa, Some(PASSPHRASE), "tablepro-in-process").await?;
    let rewritten = std::process::Command::new("ssh-keygen")
        .args(["-q", "-p", "-m", "PEM", "-P", PASSPHRASE, "-N", PASSPHRASE, "-f"])
        .arg(key.private_key())
        .status()?;
    assert!(rewritten.success());
    let server = Server::start(SshAuthVariant::PublicKey(key), OpenSshOptions::selected()?, None).await?;

    let session = server.connect(key_file(server.key()?)).await??;

    assert_tunnel_answers(&session).await
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_missing_passphrase_is_asked_for_with_the_key_path() -> TestResult {
    let key = SshKeyPair::generate_with(SshKeyType::Ed25519, Some(PASSPHRASE), "tablepro-in-process").await?;
    let server = Server::start(SshAuthVariant::PublicKey(key), OpenSshOptions::selected()?, None).await?;
    let path = server.key()?.private_key().to_owned();
    let auth = SshAuth::PrivateKey {
        path: Some(path.clone()),
        passphrase: None,
    };
    let prompter = Arc::new(FakePrompter::new([typed("wrong"), typed(PASSPHRASE)]));

    let session = server.connect_asking(auth, prompter.clone()).await??;

    assert_tunnel_answers(&session).await?;
    let purposes: Vec<PromptPurpose> = prompter.requests().into_iter().map(|request| request.purpose).collect();
    assert_eq!(
        purposes,
        [
            PromptPurpose::SshPassphrase {
                path: path.clone(),
                reason: PromptReason::NotStored
            },
            PromptPurpose::SshPassphrase {
                path,
                reason: PromptReason::Rejected
            },
        ]
    );
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn the_agent_signs_in() -> TestResult {
    let agent = SshAgent::start().await?;
    let key = SshKeyPair::generate("tablepro-in-process").await?;
    agent.add(&key).await?;
    let server = Server::start(
        SshAuthVariant::PublicKey(key),
        OpenSshOptions::selected()?,
        Some(&agent),
    )
    .await?;

    let session = server.connect(SshAuth::Agent).await??;

    assert_tunnel_answers(&session).await
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_missing_agent_is_named_when_nothing_else_signs_in() -> TestResult {
    let key = SshKeyPair::generate("tablepro-in-process").await?;
    let server = Server::start(SshAuthVariant::PublicKey(key), OpenSshOptions::selected()?, None).await?;

    let session = server.connect(SshAuth::Agent).await?;

    assert!(
        matches!(&session, Err(TransportError::Ssh(SshFailure::AgentUnavailable { location })) if location.ends_with("no-agent.sock")),
        "{session:?}"
    );
    Ok(())
}

// The agent holds the chosen key, so it signs and the passphrase is never asked for (Linux ADR 0020).
#[tokio::test]
#[ignore = "requires docker"]
async fn a_key_file_the_agent_holds_asks_for_no_passphrase() -> TestResult {
    let agent = SshAgent::start().await?;
    let key = SshKeyPair::generate_with(SshKeyType::Ed25519, Some(PASSPHRASE), "tablepro-in-process").await?;
    agent.add(&key).await?;
    let server = Server::start(
        SshAuthVariant::PublicKey(key),
        OpenSshOptions::selected()?,
        Some(&agent),
    )
    .await?;
    let auth = SshAuth::PrivateKey {
        path: Some(server.key()?.private_key().to_owned()),
        passphrase: None,
    };

    let session = server.connect(auth).await??;

    assert_tunnel_answers(&session).await
}

// More agent keys than MaxAuthTries would end the login before the chosen one; only the chosen key is offered.
#[tokio::test]
#[ignore = "requires docker"]
async fn a_chosen_key_file_is_the_only_key_offered() -> TestResult {
    let agent = SshAgent::start().await?;
    for index in 1..=4 {
        agent
            .add(&SshKeyPair::generate(&format!("tablepro-decoy-{index}")).await?)
            .await?;
    }
    let key = SshKeyPair::generate("tablepro-in-process").await?;
    let options = OpenSshOptions::selected()?.with_max_auth_tries(3);
    let server = Server::start(SshAuthVariant::PublicKey(key), options, Some(&agent)).await?;

    let session = server.connect(key_file(server.key()?)).await??;

    assert_tunnel_answers(&session).await
}

// The server ends the login itself, and its disconnect, not a refusal, is what the connect reports.
#[tokio::test]
#[ignore = "requires docker"]
async fn an_agent_with_more_keys_than_max_auth_tries_is_named() -> TestResult {
    let agent = SshAgent::start().await?;
    for index in 1..=4 {
        agent
            .add(&SshKeyPair::generate(&format!("tablepro-decoy-{index}")).await?)
            .await?;
    }
    let key = SshKeyPair::generate("tablepro-in-process").await?;
    agent.add(&key).await?;
    let options = OpenSshOptions::selected()?.with_max_auth_tries(3);
    let server = Server::start(SshAuthVariant::PublicKey(key), options, Some(&agent)).await?;

    let session = server.connect(SshAuth::Agent).await?;

    assert!(
        matches!(&session, Err(TransportError::Ssh(SshFailure::TooManyAuthenticationFailures { host })) if host == server.fixture.host()),
        "{session:?}"
    );
    Ok(())
}

// The server takes only certificates its authority signed, and the key's is beside the file.
async fn certified_key_signs_in(kind: SshKeyType, agent_holds_the_key: bool) -> TestResult {
    let agent = SshAgent::start().await?;
    let authority = SshKeyPair::generate("tablepro-user-ca").await?;
    let variant = SshAuthVariant::UserCertificateAuthority(authority);
    let server = Server::start(variant, OpenSshOptions::selected()?, Some(&agent)).await?;
    let SshAuthVariant::UserCertificateAuthority(authority) = server.fixture.variant() else {
        return Err("the server lost its certificate authority".into());
    };
    let key = SshKeyPair::generate_with(kind, None, "tablepro-in-process").await?;
    if agent_holds_the_key {
        agent.add(&key).await?;
    }
    let signed = std::process::Command::new("ssh-keygen")
        .args(["-q", "-s"])
        .arg(authority.private_key())
        .args(["-I", "tablepro-in-process", "-n"])
        .arg(server.fixture.password_credentials().username)
        .arg(key.public_key_file())
        .status()?;
    assert!(signed.success());

    let session = server.connect(key_file(&key)).await??;

    assert_tunnel_answers(&session).await
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_user_certificate_beside_the_key_file_signs_in() -> TestResult {
    certified_key_signs_in(SshKeyType::Ed25519, false).await
}

// russh's own certificate login names ssh-rsa-cert-v01, which OpenSSH 8.8 and later refuse.
#[tokio::test]
#[ignore = "requires docker"]
async fn a_user_certificate_beside_an_rsa_key_file_signs_in_with_rsa_sha2() -> TestResult {
    certified_key_signs_in(SshKeyType::Rsa, false).await
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_user_certificate_beside_a_key_the_agent_holds_signs_in_through_the_agent() -> TestResult {
    certified_key_signs_in(SshKeyType::Ed25519, true).await
}

// sshd reaches itself on its own port, so one server is the jump host and the destination behind it.
#[tokio::test]
#[ignore = "requires docker"]
async fn a_stored_passphrase_opens_the_key_once_for_every_hop() -> TestResult {
    let key = SshKeyPair::generate_with(SshKeyType::Ed25519, Some(PASSPHRASE), "tablepro-in-process").await?;
    let server = Server::start(SshAuthVariant::PublicKey(key), OpenSshOptions::selected()?, None).await?;
    let host_key = server.fixture.host_public_key().await?;
    let known_hosts = server.services.user_known_hosts.clone().ok_or("no known_hosts")?;
    let mut trusted = std::fs::read_to_string(&known_hosts)?;
    trusted.push_str(&format!("[127.0.0.1]:{} {host_key}\n", OpenSshFixture::CONTAINER_PORT));
    std::fs::write(&known_hosts, trusted)?;
    let user = server.fixture.password_credentials().username;
    let config = SshConfig {
        destination: SshDestination::new("127.0.0.1", Some(OpenSshFixture::CONTAINER_PORT), Some(user.clone()))?,
        jump_hosts: vec![SshDestination::new(
            server.fixture.host(),
            Some(server.fixture.port()),
            Some(user),
        )?],
        auth: key_file(server.key()?),
    };

    let session = InProcessSession::connect(
        &config,
        &server.services,
        &LivenessPolicy::DESKTOP,
        CredentialInteraction::Unattended,
        CancellationToken::new(),
    )
    .await?;

    assert_tunnel_answers(&session).await
}
