//! The tunnel against the OpenSSH release `TABLEPRO_TEST_OPENSSH` picks, across client keys, agents, key exchange
//! and a server that goes away (#3662).

use std::collections::HashSet;
use std::error::Error;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use secrecy::SecretString;
use tablepro_core::credentials::CredentialInteraction;
use tablepro_core::{LivenessPolicy, NetworkEndpoint, SshAlgorithmKind, SshFailure, TransportError};
use tablepro_ssh::{SshAuth, SshConfig, SshDestination, SshRuntimeCell, SshServices, SshSession};
use tablepro_test_fixtures::{OpenSshFixture, SshAgent, SshAuthVariant, SshKeyPair, SshKeyType};
use tablepro_test_support::FakePrompter;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
use tokio_util::sync::CancellationToken;

type TestResult<T = ()> = Result<T, Box<dyn Error>>;

const PASSPHRASE: &str = "correct horse battery";
const WAIT: Duration = Duration::from_secs(15);
const POST_QUANTUM_KEX: [&str; 2] = ["mlkem768x25519-sha256", "sntrup761x25519-sha512"];
/// sshd's default, set on the server so the decoy count follows from it.
const MAX_AUTH_TRIES: usize = 6;

/// The system ssh under a private ssh_config whose known_hosts already
/// trusts the server, so a test that sees a prompt has found a bug.
struct Client {
    _dir: tempfile::TempDir,
    services: SshServices,
}

impl Client {
    async fn new(server: &OpenSshFixture) -> TestResult<Self> {
        Self::with(server, &["IdentityAgent none".to_owned()]).await
    }

    async fn with_agent(server: &OpenSshFixture, agent: &SshAgent) -> TestResult<Self> {
        Self::with(server, &[format!("IdentityAgent {}", agent.socket().display())]).await
    }

    /// `options` go under `Host *` after the known_hosts lines.
    async fn with(server: &OpenSshFixture, options: &[String]) -> TestResult<Self> {
        let dir = tempfile::tempdir()?;
        let known_hosts = dir.path().join("known_hosts");
        let host_key = server.host_public_key().await?;
        std::fs::write(
            &known_hosts,
            format!("[{}]:{} {host_key}\n", server.host(), server.port()),
        )?;
        let mut config = format!(
            "Host *\n  UserKnownHostsFile {}\n  GlobalKnownHostsFile /dev/null\n",
            known_hosts.display()
        );
        for option in options {
            config.push_str(&format!("  {option}\n"));
        }
        let config_file = dir.path().join("ssh_config");
        std::fs::write(&config_file, config)?;
        let wrapper = dir.path().join("ssh");
        tablepro_test_support::write_executable(
            &wrapper,
            format!("#!/bin/sh\nexec ssh -F '{}' \"$@\"\n", config_file.display()).as_bytes(),
            0o755,
        )?;
        let runtime = dir.path().join("runtime").join("app").join("app.tablepro.TablePro");
        let services = SshServices {
            runtime: Arc::new(SshRuntimeCell::new(runtime)),
            ssh_program: wrapper,
            ssh_keygen_program: PathBuf::from("ssh-keygen"),
            askpass_program: PathBuf::from(env!("CARGO_BIN_EXE_tablepro-askpass")),
            config_file: None,
        };
        Ok(Self { _dir: dir, services })
    }

    /// A session to `server` that may not ask the user anything.
    async fn connect(&self, server: &OpenSshFixture, auth: SshAuth) -> Result<Arc<SshSession>, TransportError> {
        let destination = SshDestination::new(
            server.host(),
            Some(server.port()),
            Some(server.password_credentials().username),
        )
        .map_err(|problem| TransportError::Ssh(problem.into()))?;
        let config = SshConfig {
            destination,
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
        let prompts = prompter.requests();
        assert!(prompts.is_empty(), "ssh asked the user: {prompts:?}");
        session
    }
}

fn key_file(key: &SshKeyPair, passphrase: Option<&str>) -> SshAuth {
    SshAuth::PrivateKey {
        path: Some(key.private_key().to_owned()),
        passphrase: passphrase.map(SecretString::from),
    }
}

/// The server's identification line, read through a forward to sshd's
/// own port, so it proves the tunnel carries data to the release under
/// test.
async fn banner_through(session: &Arc<SshSession>) -> TestResult<String> {
    let target = NetworkEndpoint::new("127.0.0.1", OpenSshFixture::CONTAINER_PORT)?;
    let transport = session.forward(target, &LivenessPolicy::DESKTOP).await?;
    let stream = transport.open().await?;
    let mut banner = String::new();
    tokio::time::timeout(WAIT, BufReader::new(stream).read_line(&mut banner)).await??;
    Ok(banner.trim_end().to_owned())
}

/// Connect, read the banner through the tunnel and close, as one cell of
/// the matrix.
async fn tunnel(client: &Client, server: &OpenSshFixture, auth: SshAuth) -> TestResult {
    let session = client.connect(server, auth).await?;
    let banner = banner_through(&session).await?;
    let expected = server.version().banner_prefix();
    if !banner.starts_with(&expected) {
        return Err(format!("the tunnel reached {banner:?}, not {expected}").into());
    }
    session.shutdown(Duration::from_secs(5)).await;
    Ok(())
}

async fn decoys() -> TestResult<Vec<SshKeyPair>> {
    let mut keys = Vec::new();
    for index in 0..MAX_AUTH_TRIES {
        keys.push(SshKeyPair::generate(&format!("tablepro-decoy-{index}")).await?);
    }
    Ok(keys)
}

fn process_alive(pid: u32) -> bool {
    Path::new(&format!("/proc/{pid}")).exists()
}

#[tokio::test]
#[ignore = "requires docker"]
async fn every_client_key_type_opens_the_tunnel() -> TestResult {
    let mut keys = Vec::new();
    for key_type in SshKeyType::ALL {
        for passphrase in [None, Some(PASSPHRASE)] {
            keys.push(SshKeyPair::generate_with(key_type, passphrase, "tablepro-matrix").await?);
        }
    }
    let server = OpenSshFixture::start(SshAuthVariant::PublicKeys(keys)).await?;
    let SshAuthVariant::PublicKeys(keys) = server.variant() else {
        return Err("the fixture lost its keys".into());
    };
    let client = Client::new(&server).await?;

    let mut failures = Vec::new();
    for key in keys {
        if let Err(error) = tunnel(&client, &server, key_file(key, key.passphrase())).await {
            failures.push(format!(
                "{:?}, passphrase {}: {error}",
                key.key_type(),
                key.passphrase().is_some()
            ));
        }
    }

    assert!(failures.is_empty(), "{failures:#?}");
    Ok(())
}

/// sshd sends only the algorithms it accepts as server-sig-algs, and the
/// client signs with the one it names.
#[tokio::test]
#[ignore = "requires docker"]
async fn an_rsa_key_signs_with_the_sha2_algorithm_the_server_accepts() -> TestResult {
    for algorithm in ["rsa-sha2-256", "rsa-sha2-512"] {
        let key = SshKeyPair::generate_with(SshKeyType::Rsa, None, "tablepro-rsa").await?;
        let private_key = key.private_key().to_owned();
        let accepted = format!("PubkeyAcceptedAlgorithms {algorithm}");
        let server = OpenSshFixture::start_configured(SshAuthVariant::PublicKey(key), &[&accepted]).await?;
        let client = Client::new(&server).await?;
        let auth = SshAuth::PrivateKey {
            path: Some(private_key),
            passphrase: None,
        };

        tunnel(&client, &server, auth)
            .await
            .map_err(|error| format!("{algorithm}: {error}"))?;
    }
    Ok(())
}

#[tokio::test]
#[ignore = "requires docker"]
async fn an_agent_key_opens_the_tunnel() -> TestResult {
    let agent = SshAgent::start().await?;
    let key = SshKeyPair::generate_with(SshKeyType::EcdsaP256, None, "tablepro-agent").await?;
    agent.add(&key).await?;
    let server = OpenSshFixture::start(SshAuthVariant::PublicKey(key)).await?;
    let client = Client::with_agent(&server, &agent).await?;

    tunnel(&client, &server, SshAuth::Agent).await
}

/// A key file whose key the agent holds signs through the agent, so a
/// passphrase-protected file never asks for its passphrase (#2583).
#[tokio::test]
#[ignore = "requires docker"]
async fn a_key_file_the_agent_holds_asks_for_no_passphrase() -> TestResult {
    let agent = SshAgent::start().await?;
    let key = SshKeyPair::generate_with(SshKeyType::Ed25519, Some(PASSPHRASE), "tablepro-agent").await?;
    agent.add(&key).await?;
    let private_key = key.private_key().to_owned();
    let server = OpenSshFixture::start(SshAuthVariant::PublicKey(key)).await?;
    let client = Client::with_agent(&server, &agent).await?;
    let auth = SshAuth::PrivateKey {
        path: Some(private_key),
        passphrase: None,
    };

    tunnel(&client, &server, auth).await
}

/// An encrypted PEM file with no `.pub` hides its public half, so ssh
/// cannot match it to the agent's copy. The agent still signs, rather
/// than the file asking for its passphrase.
#[tokio::test]
#[ignore = "requires docker"]
async fn an_encrypted_pem_key_the_agent_holds_asks_for_no_passphrase() -> TestResult {
    let agent = SshAgent::start().await?;
    let key = SshKeyPair::generate_with(SshKeyType::Rsa, Some(PASSPHRASE), "tablepro-pem").await?;
    agent.add(&key).await?;
    let private_key = key.private_key().to_owned();
    let rewritten = std::process::Command::new("ssh-keygen")
        .args(["-q", "-p", "-m", "PEM", "-P", PASSPHRASE, "-N", PASSPHRASE, "-f"])
        .arg(&private_key)
        .status()?;
    assert!(rewritten.success());
    std::fs::remove_file(private_key.with_extension("pub"))?;
    let server = OpenSshFixture::start(SshAuthVariant::PublicKey(key)).await?;
    let client = Client::with_agent(&server, &agent).await?;
    let auth = SshAuth::PrivateKey {
        path: Some(private_key),
        passphrase: None,
    };

    tunnel(&client, &server, auth).await
}

/// The agent holds the chosen key and a certificate for it that is on
/// no disk, and the server takes only the certificate. ssh offers a key
/// file the agent holds first anyway, so the certificate stays in play.
#[tokio::test]
#[ignore = "requires docker"]
async fn an_agent_certificate_for_the_chosen_key_file_is_still_offered() -> TestResult {
    let authority = SshKeyPair::generate("tablepro-user-ca").await?;
    let server = OpenSshFixture::start(SshAuthVariant::UserCertificateAuthority(authority)).await?;
    let SshAuthVariant::UserCertificateAuthority(authority) = server.variant() else {
        return Err("the fixture lost its authority".into());
    };
    let key = SshKeyPair::generate("tablepro-certified").await?;
    let signed = std::process::Command::new("ssh-keygen")
        .args(["-q", "-s"])
        .arg(authority.private_key())
        .args(["-I", "tablepro-certified", "-n"])
        .arg(server.password_credentials().username)
        .arg(key.private_key().with_extension("pub"))
        .status()?;
    assert!(signed.success());
    let agent = SshAgent::start().await?;
    agent.add(&key).await?;
    std::fs::remove_file(format!("{}-cert.pub", key.private_key().display()))?;
    assert_eq!(
        agent.identities().await?.len(),
        2,
        "the agent holds the key and its certificate"
    );
    let client = Client::with_agent(&server, &agent).await?;

    tunnel(&client, &server, key_file(&key, None)).await
}

/// The #2601 case: an agent holding more keys than the server's
/// MaxAuthTries, none of them the one the connection names.
#[tokio::test]
#[ignore = "requires docker"]
async fn a_chosen_key_file_is_offered_before_an_agent_full_of_other_keys() -> TestResult {
    let agent = SshAgent::start().await?;
    for decoy in decoys().await? {
        agent.add(&decoy).await?;
    }
    let key = SshKeyPair::generate("tablepro-chosen").await?;
    let private_key = key.private_key().to_owned();
    let max_auth_tries = format!("MaxAuthTries {MAX_AUTH_TRIES}");
    let server = OpenSshFixture::start_configured(SshAuthVariant::PublicKey(key), &[&max_auth_tries]).await?;
    let client = Client::with_agent(&server, &agent).await?;
    let auth = SshAuth::PrivateKey {
        path: Some(private_key),
        passphrase: None,
    };

    tunnel(&client, &server, auth).await
}

/// In agent mode the agent's order is ssh's, so a key behind
/// MaxAuthTries others is never reached; the error says why.
#[tokio::test]
#[ignore = "requires docker"]
async fn an_agent_with_more_keys_than_max_auth_tries_names_the_cause() -> TestResult {
    let agent = SshAgent::start().await?;
    for decoy in decoys().await? {
        agent.add(&decoy).await?;
    }
    let key = SshKeyPair::generate("tablepro-last").await?;
    agent.add(&key).await?;
    let max_auth_tries = format!("MaxAuthTries {MAX_AUTH_TRIES}");
    let server = OpenSshFixture::start_configured(SshAuthVariant::PublicKey(key), &[&max_auth_tries]).await?;
    let client = Client::with_agent(&server, &agent).await?;

    let session = client.connect(&server, SshAuth::Agent).await;

    assert!(
        matches!(
            session,
            Err(TransportError::Ssh(SshFailure::AuthenticationAttemptsExceeded { .. }))
        ),
        "{session:?}"
    );
    Ok(())
}

/// A server limited to the post-quantum key exchanges. A client that has
/// one connects; one that has neither, as OpenSSH before 9.9 and a client
/// configured without them, gets an error that names the key exchange.
#[tokio::test]
#[ignore = "requires docker"]
async fn a_post_quantum_only_server_connects_or_names_the_key_exchange() -> TestResult {
    let key = SshKeyPair::generate("tablepro-kex").await?;
    let private_key = key.private_key().to_owned();
    let kex = format!("KexAlgorithms {}", POST_QUANTUM_KEX.join(","));
    let server = OpenSshFixture::start_configured(SshAuthVariant::PublicKey(key), &[&kex]).await?;
    let auth = || SshAuth::PrivateKey {
        path: Some(private_key.clone()),
        passphrase: None,
    };
    let named = |session: &Result<Arc<SshSession>, TransportError>| {
        matches!(
            session,
            Err(TransportError::Ssh(SshFailure::NoCommonAlgorithm {
                kind: SshAlgorithmKind::KeyExchange,
                server_offer,
                ..
            })) if server_offer == &POST_QUANTUM_KEX
        )
    };
    let listed = tokio::process::Command::new("ssh").args(["-Q", "kex"]).output().await?;
    let client_kex: HashSet<String> = String::from_utf8_lossy(&listed.stdout)
        .lines()
        .map(str::to_owned)
        .collect();

    let client = Client::new(&server).await?;
    if POST_QUANTUM_KEX.iter().any(|name| client_kex.contains(*name)) {
        tunnel(&client, &server, auth()).await?;
    } else {
        let session = client.connect(&server, auth()).await;
        assert!(named(&session), "{session:?}");
    }
    let classical = Client::with(
        &server,
        &[
            "IdentityAgent none".to_owned(),
            "KexAlgorithms curve25519-sha256".to_owned(),
        ],
    )
    .await?;
    let session = classical.connect(&server, auth()).await;
    assert!(named(&session), "{session:?}");
    Ok(())
}

/// sshd stops under an open forward (#1769): the session reports closed,
/// the master exits rather than spinning, and the stream ends.
#[tokio::test]
#[ignore = "requires docker"]
async fn stopping_sshd_under_an_open_forward_closes_the_tunnel() -> TestResult {
    let key = SshKeyPair::generate("tablepro-loss").await?;
    let private_key = key.private_key().to_owned();
    let server = OpenSshFixture::start(SshAuthVariant::PublicKey(key)).await?;
    let client = Client::new(&server).await?;
    let session = client
        .connect(
            &server,
            SshAuth::PrivateKey {
                path: Some(private_key),
                passphrase: None,
            },
        )
        .await?;
    let master = session.master_pid().ok_or("no ssh master")?;
    let target = NetworkEndpoint::new("127.0.0.1", OpenSshFixture::CONTAINER_PORT)?;
    let transport = session.forward(target, &LivenessPolicy::DESKTOP).await?;
    let mut stream = BufReader::new(transport.open().await?);
    let mut banner = String::new();
    tokio::time::timeout(WAIT, stream.read_line(&mut banner)).await??;
    assert!(banner.starts_with(&server.version().banner_prefix()), "{banner:?}");

    // Every sshd process, the listener and this session's, as when the
    // service stops.
    let stopped = server.exec(&["pkill", "sshd"]).await?;
    assert!(stopped.succeeded(), "{}", stopped.stderr_text());

    tokio::time::timeout(WAIT, session.closed()).await?;
    assert!(session.is_closed());
    let deadline = tokio::time::Instant::now() + WAIT;
    while process_alive(master) && tokio::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(!process_alive(master), "the ssh master outlived its connection");
    // An end of stream and a reset both end it; a read that never returns would be the bug.
    let mut rest = Vec::new();
    let _ended = tokio::time::timeout(WAIT, stream.read_to_end(&mut rest)).await?;
    let again = session
        .forward(
            NetworkEndpoint::new("127.0.0.1", OpenSshFixture::CONTAINER_PORT)?,
            &LivenessPolicy::DESKTOP,
        )
        .await;
    assert!(
        matches!(again, Err(TransportError::Ssh(SshFailure::MasterExited { .. }))),
        "{again:?}"
    );
    Ok(())
}
