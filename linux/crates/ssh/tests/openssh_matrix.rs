use std::error::Error;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use secrecy::SecretString;
use tablepro_core::credentials::CredentialInteraction;
use tablepro_core::{LivenessPolicy, NetworkEndpoint, SshAlgorithmKind, SshFailure, TransportError};
use tablepro_ssh::{SshAuth, SshConfig, SshDestination, SshRuntimeCell, SshServices, SshSession};
use tablepro_test_fixtures::{OpenSshFixture, OpenSshOptions, SshAgent, SshAuthVariant, SshKeyPair, SshKeyType};
use tablepro_test_support::FakePrompter;
use tokio::io::AsyncReadExt;
use tokio_util::sync::CancellationToken;

type TestResult<T = ()> = Result<T, Box<dyn Error>>;

const PASSPHRASE: &str = "correct horse battery";
const NO_AGENT: &str = "  IdentityAgent none\n";

struct Server {
    fixture: OpenSshFixture,
    services: SshServices,
    _dir: tempfile::TempDir,
}

impl Server {
    // The client reads `client_config` after a known_hosts that already trusts the server, and nothing else.
    async fn start(key: SshKeyPair, options: OpenSshOptions, client_config: &str) -> TestResult<Self> {
        let fixture = OpenSshFixture::start_with(SshAuthVariant::PublicKey(key), options, None).await?;
        let dir = tempfile::tempdir()?;
        let known_hosts = dir.path().join("known_hosts");
        let host_key = fixture.host_public_key().await?;
        std::fs::write(
            &known_hosts,
            format!("[{}]:{} {host_key}\n", fixture.host(), fixture.port()),
        )?;
        let config = dir.path().join("ssh_config");
        std::fs::write(
            &config,
            format!(
                "Host *\n  UserKnownHostsFile {}\n  GlobalKnownHostsFile /dev/null\n{client_config}",
                known_hosts.display()
            ),
        )?;
        let wrapper = dir.path().join("ssh");
        tablepro_test_support::write_executable(
            &wrapper,
            format!("#!/bin/sh\nexec ssh -F '{}' \"$@\"\n", config.display()).as_bytes(),
            0o755,
        )?;
        let xdg_runtime = dir.path().join("runtime");
        std::fs::create_dir(&xdg_runtime)?;
        let services = SshServices {
            runtime: Arc::new(SshRuntimeCell::new(
                xdg_runtime.join("app").join("app.tablepro.TablePro"),
            )),
            ssh_program: wrapper,
            ssh_keygen_program: PathBuf::from("ssh-keygen"),
            askpass_program: PathBuf::from(env!("CARGO_BIN_EXE_tablepro-askpass")),
            config_file: None,
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

    // Every secret a case needs is stored, so ssh asking the user anything is a failure.
    async fn connect(&self, auth: SshAuth) -> TestResult<Result<Arc<SshSession>, TransportError>> {
        let config = SshConfig {
            destination: SshDestination::new(
                self.fixture.host(),
                Some(self.fixture.port()),
                Some(self.fixture.password_credentials().username),
            )?,
            jump_hosts: Vec::new(),
            auth,
        };
        let prompter = Arc::new(FakePrompter::new(Vec::new()));
        let session = SshSession::connect(
            &config,
            &self.services,
            &LivenessPolicy::DESKTOP,
            CredentialInteraction::Attended(prompter.clone()),
            CancellationToken::new(),
        )
        .await;
        assert!(prompter.requests().is_empty(), "{:?}", prompter.requests());
        Ok(session)
    }

    // ssh names the peer by the address it connected to, which for a fixture on `localhost` is not the host name.
    async fn is_named(&self, host: &str) -> TestResult<bool> {
        if host == self.fixture.host() {
            return Ok(true);
        }
        let mut addresses = tokio::net::lookup_host((self.fixture.host(), self.fixture.port())).await?;
        Ok(addresses.any(|address| address.ip().to_string() == host))
    }
}

fn key_file(key: &SshKeyPair) -> SshAuth {
    SshAuth::PrivateKey {
        path: Some(key.private_key().to_owned()),
        passphrase: key.passphrase().map(SecretString::from),
    }
}

async fn agent_holding_decoys(count: usize) -> TestResult<SshAgent> {
    let agent = SshAgent::start().await?;
    for index in 1..=count {
        let decoy = SshKeyPair::generate(&format!("tablepro-decoy-{index}")).await?;
        agent.add(&decoy).await?;
    }
    Ok(agent)
}

fn agent_config(agent: &SshAgent) -> String {
    format!("  IdentityAgent {}\n", agent.socket().display())
}

// A forward to the server's own sshd answers with its banner, so a tunnel that carries bytes is proven without a database.
async fn assert_tunnel_answers(session: &Arc<SshSession>) -> TestResult {
    let target = NetworkEndpoint::new("127.0.0.1", OpenSshFixture::CONTAINER_PORT)?;
    let transport = session.forward(target, &LivenessPolicy::DESKTOP).await?;
    let mut stream = transport.open().await?;
    let mut banner = [0_u8; 8];
    stream.read_exact(&mut banner).await?;
    assert_eq!(&banner, b"SSH-2.0-");
    drop(stream);
    drop(transport);
    session.shutdown(Duration::from_secs(5)).await;
    Ok(())
}

async fn key_signs_in(kind: SshKeyType, passphrase: Option<&str>, options: OpenSshOptions) -> TestResult {
    let key = SshKeyPair::generate_with(kind, passphrase, "tablepro-matrix").await?;
    let server = Server::start(key, options, NO_AGENT).await?;

    let session = server.connect(key_file(server.key()?)).await??;

    assert_tunnel_answers(&session).await
}

async fn rsa_signs_in_with(signature: &str, passphrase: Option<&str>) -> TestResult {
    let options = OpenSshOptions::selected()?.with_pubkey_accepted_algorithms(signature);
    key_signs_in(SshKeyType::Rsa, passphrase, options).await
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
    rsa_signs_in_with("rsa-sha2-256", None).await
}

#[tokio::test]
#[ignore = "requires docker"]
async fn rsa_key_signs_in_with_rsa_sha2_512() -> TestResult {
    rsa_signs_in_with("rsa-sha2-512", None).await
}

#[tokio::test]
#[ignore = "requires docker"]
async fn rsa_key_with_a_passphrase_signs_in_with_rsa_sha2_256() -> TestResult {
    rsa_signs_in_with("rsa-sha2-256", Some(PASSPHRASE)).await
}

#[tokio::test]
#[ignore = "requires docker"]
async fn rsa_key_with_a_passphrase_signs_in_with_rsa_sha2_512() -> TestResult {
    rsa_signs_in_with("rsa-sha2-512", Some(PASSPHRASE)).await
}

#[tokio::test]
#[ignore = "requires docker"]
async fn ecdsa_p256_key_signs_in() -> TestResult {
    key_signs_in(SshKeyType::EcdsaP256, None, OpenSshOptions::selected()?).await
}

#[tokio::test]
#[ignore = "requires docker"]
async fn ecdsa_p256_key_with_a_passphrase_signs_in() -> TestResult {
    key_signs_in(SshKeyType::EcdsaP256, Some(PASSPHRASE), OpenSshOptions::selected()?).await
}

#[tokio::test]
#[ignore = "requires docker"]
async fn an_agent_with_more_keys_than_max_auth_tries_signs_in_with_the_configured_identity() -> TestResult {
    let agent = agent_holding_decoys(4).await?;
    let key = SshKeyPair::generate("tablepro-matrix").await?;
    agent.add(&key).await?;
    assert_eq!(agent.identities().await?.last(), Some(&key.public_key().to_owned()));
    let client_config = format!(
        "{}  IdentityFile {}\n  IdentitiesOnly yes\n",
        agent_config(&agent),
        key.public_key_file().display()
    );
    let server = Server::start(key, OpenSshOptions::selected()?.with_max_auth_tries(3), &client_config).await?;

    let session = server.connect(SshAuth::Agent).await??;

    assert_tunnel_answers(&session).await
}

#[tokio::test]
#[ignore = "requires docker"]
async fn an_agent_with_more_keys_than_max_auth_tries_is_named() -> TestResult {
    let agent = agent_holding_decoys(4).await?;
    let key = SshKeyPair::generate("tablepro-matrix").await?;
    agent.add(&key).await?;
    assert_eq!(agent.identities().await?.last(), Some(&key.public_key().to_owned()));
    let options = OpenSshOptions::selected()?.with_max_auth_tries(3);
    let server = Server::start(key, options, &agent_config(&agent)).await?;

    let session = server.connect(SshAuth::Agent).await?;

    let Err(TransportError::Ssh(SshFailure::TooManyAuthenticationFailures { host })) = &session else {
        return Err(format!("expected too many authentication failures, got {session:?}").into());
    };
    assert!(server.is_named(host).await?, "{host}");
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_chosen_key_file_is_offered_before_the_agents_keys() -> TestResult {
    let agent = agent_holding_decoys(4).await?;
    let key = SshKeyPair::generate("tablepro-matrix").await?;
    let options = OpenSshOptions::selected()?.with_max_auth_tries(3);
    let server = Server::start(key, options, &agent_config(&agent)).await?;

    let session = server.connect(key_file(server.key()?)).await??;

    assert_tunnel_answers(&session).await
}

async fn client_key_exchanges() -> TestResult<Vec<String>> {
    let output = tokio::process::Command::new("ssh").args(["-Q", "kex"]).output().await?;
    Ok(String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(str::to_owned)
        .collect())
}

fn is_post_quantum_offer(session: &Result<Arc<SshSession>, TransportError>) -> bool {
    matches!(
        session,
        Err(TransportError::Ssh(SshFailure::NoCommonAlgorithm {
            kind: SshAlgorithmKind::KeyExchange,
            server_offer,
            ..
        })) if *server_offer == ["mlkem768x25519-sha256", "sntrup761x25519-sha512"]
    )
}

// OpenSSH 9.9 added both names, so a 9.6 client such as Ubuntu 24.04's has neither.
#[tokio::test]
#[ignore = "requires docker"]
async fn a_post_quantum_only_server_connects_or_names_the_key_exchange() -> TestResult {
    let supported = client_key_exchanges().await?;
    let options = OpenSshOptions::selected()?.with_kex_algorithms(OpenSshOptions::POST_QUANTUM_KEX);
    let key = SshKeyPair::generate("tablepro-matrix").await?;
    let server = Server::start(key, options, NO_AGENT).await?;

    let session = server.connect(key_file(server.key()?)).await?;

    let shared = OpenSshOptions::POST_QUANTUM_KEX
        .split(',')
        .any(|name| supported.iter().any(|offered| offered == name));
    if shared {
        return assert_tunnel_answers(&session?).await;
    }
    assert!(is_post_quantum_offer(&session), "{session:?}");
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_key_exchange_the_client_does_not_offer_is_named() -> TestResult {
    let options = OpenSshOptions::selected()?.with_kex_algorithms(OpenSshOptions::POST_QUANTUM_KEX);
    let key = SshKeyPair::generate("tablepro-matrix").await?;
    let client_config = format!("{NO_AGENT}  KexAlgorithms curve25519-sha256\n");
    let server = Server::start(key, options, &client_config).await?;

    let session = server.connect(key_file(server.key()?)).await?;

    assert!(is_post_quantum_offer(&session), "{session:?}");
    let Err(TransportError::Ssh(SshFailure::NoCommonAlgorithm { host, .. })) = &session else {
        return Err("the failure has no host".into());
    };
    assert!(server.is_named(host).await?, "{host}");
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_killed_master_is_not_explained_by_the_post_quantum_warning() -> TestResult {
    let options = OpenSshOptions::selected()?.with_kex_algorithms("curve25519-sha256");
    let key = SshKeyPair::generate("tablepro-matrix").await?;
    let server = Server::start(key, options, NO_AGENT).await?;
    let session = server.connect(key_file(server.key()?)).await??;
    let pid = session.master_pid().ok_or("the master has no pid")?;

    let killed = tokio::process::Command::new("kill")
        .arg(pid.to_string())
        .status()
        .await?;
    assert!(killed.success());
    tokio::time::timeout(Duration::from_secs(10), session.closed()).await?;
    let target = NetworkEndpoint::new("127.0.0.1", OpenSshFixture::CONTAINER_PORT)?;
    let ended = session.forward(target, &LivenessPolicy::DESKTOP).await.err();

    assert!(
        matches!(
            &ended,
            Some(TransportError::Ssh(SshFailure::MasterExited { detail, .. })) if !detail.starts_with("** ")
        ),
        "{ended:?}"
    );
    Ok(())
}
