#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::process::Command;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use secrecy::SecretString;
use tablepro_ssh::openssh::{AskpassPrompt, PromptAnswer, Prompter};
use tablepro_ssh::{SshAuth, SshConfig, SshError, SshTunnel, UnknownHostKey};
use testcontainers::core::{IntoContainerPort, WaitFor};
use testcontainers::runners::AsyncRunner;
use testcontainers::{ContainerAsync, GenericImage, ImageExt};
use tokio::io::AsyncReadExt;

const SSHD_SCRIPT: &str = "apk add --no-cache openssh >/dev/null \
    && ssh-keygen -A >/dev/null \
    && adduser -D deploy && echo 'deploy:unused' | chpasswd \
    && mkdir -p /home/deploy/.ssh && printf '%s\\n' \"$AUTHORIZED_KEY\" > /home/deploy/.ssh/authorized_keys \
    && chown -R deploy /home/deploy/.ssh && chmod 700 /home/deploy/.ssh && chmod 600 /home/deploy/.ssh/authorized_keys \
    && exec /usr/sbin/sshd -D -e -p 2222 -o PasswordAuthentication=no -o AllowTcpForwarding=yes";

const PASSWORD_SSHD_SCRIPT: &str = "apk add --no-cache openssh >/dev/null \
    && ssh-keygen -A >/dev/null \
    && adduser -D deploy && echo 'deploy:s3cret' | chpasswd \
    && mkdir -p /home/deploy/.ssh && printf '%s\\n' \"$AUTHORIZED_KEY\" > /home/deploy/.ssh/authorized_keys \
    && chown -R deploy /home/deploy/.ssh && chmod 700 /home/deploy/.ssh && chmod 600 /home/deploy/.ssh/authorized_keys \
    && exec /usr/sbin/sshd -D -e -p 2222 -o PasswordAuthentication=yes -o AllowTcpForwarding=yes";

fn isolate_known_hosts(dir: &std::path::Path) {
    // SAFETY: each test that calls this runs alone under --test-threads=1
    // (scripts/test-ssh.sh), so nothing else reads the environment while it changes.
    unsafe {
        std::env::set_var("XDG_CONFIG_HOME", dir);
    }
}

fn password_config(host: &str, port: u16, password: &str) -> SshConfig {
    SshConfig {
        host: host.to_string(),
        port,
        username: "deploy".into(),
        auth: SshAuth::Password {
            password: SecretString::new(password.to_string().into()),
        },
    }
}

async fn start_password_sshd(authorized_key: &str) -> (ContainerAsync<GenericImage>, String, u16) {
    let container = GenericImage::new("alpine", "3.22")
        .with_exposed_port(2222.tcp())
        .with_wait_for(WaitFor::message_on_stderr("Server listening on"))
        .with_env_var("AUTHORIZED_KEY", authorized_key)
        .with_cmd(["sh", "-c", PASSWORD_SSHD_SCRIPT])
        .start()
        .await
        .unwrap();
    let host = container.get_host().await.unwrap().to_string();
    let port = container.get_host_port_ipv4(2222).await.unwrap();
    (container, host, port)
}

fn unique_suffix() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_nanos())
        .unwrap_or_default()
}

struct Agent {
    pid: String,
}

impl Drop for Agent {
    fn drop(&mut self) {
        let _ = Command::new("kill").arg(&self.pid).status();
    }
}

fn start_agent(socket: &std::path::Path) -> Agent {
    let output = Command::new("ssh-agent")
        .arg("-a")
        .arg(socket)
        .arg("-s")
        .output()
        .unwrap();
    let text = String::from_utf8(output.stdout).unwrap();
    let pid = text
        .split(';')
        .find_map(|part| part.trim().strip_prefix("SSH_AGENT_PID="))
        .expect("ssh-agent printed its pid")
        .to_string();
    Agent { pid }
}

fn config(host: &str, port: u16) -> SshConfig {
    SshConfig {
        host: host.to_string(),
        port,
        username: "deploy".into(),
        auth: SshAuth::Agent,
    }
}

struct AnswerHostKeys {
    accept: bool,
    calls: AtomicUsize,
}

struct AcceptFirstAndWaitOnSecondHostKey {
    calls: AtomicUsize,
    second_prompt: tokio::sync::Notify,
}

#[async_trait::async_trait]
impl Prompter for AcceptFirstAndWaitOnSecondHostKey {
    async fn answer(&self, prompt: &AskpassPrompt) -> PromptAnswer {
        assert!(matches!(prompt, AskpassPrompt::HostKeyConfirmation { .. }));
        if self.calls.fetch_add(1, Ordering::SeqCst) == 0 {
            PromptAnswer::Accept
        } else {
            self.second_prompt.notify_one();
            std::future::pending().await
        }
    }
}

#[async_trait::async_trait]
impl Prompter for AnswerHostKeys {
    async fn answer(&self, prompt: &AskpassPrompt) -> PromptAnswer {
        assert!(matches!(prompt, AskpassPrompt::HostKeyConfirmation { .. }));
        self.calls.fetch_add(1, Ordering::SeqCst);
        if self.accept {
            PromptAnswer::Accept
        } else {
            PromptAnswer::Decline
        }
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn the_built_in_client_authenticates_with_a_key_held_by_ssh_agent() {
    let temp = tempfile::tempdir().unwrap();
    let key = temp.path().join("id_ed25519");
    let generated = Command::new("ssh-keygen")
        .args(["-q", "-t", "ed25519", "-N", "", "-f"])
        .arg(&key)
        .status()
        .unwrap();
    assert!(generated.success());
    let public = std::fs::read_to_string(key.with_extension("pub")).unwrap();

    let container = GenericImage::new("alpine", "3.22")
        .with_exposed_port(2222.tcp())
        .with_wait_for(WaitFor::message_on_stderr("Server listening on"))
        .with_env_var("AUTHORIZED_KEY", public.trim())
        .with_cmd(["sh", "-c", SSHD_SCRIPT])
        .start()
        .await
        .unwrap();
    let host = container.get_host().await.unwrap().to_string();
    let port = container.get_host_port_ipv4(2222).await.unwrap();

    let socket = temp.path().join("agent.sock");
    let _agent = start_agent(&socket);
    // SAFETY: this binary holds a single test, so nothing else reads the
    // environment while it changes. russh finds the agent through
    // SSH_AUTH_SOCK, and known_hosts is resolved from XDG_CONFIG_HOME.
    unsafe {
        std::env::set_var("SSH_AUTH_SOCK", &socket);
        std::env::set_var("XDG_CONFIG_HOME", temp.path());
    }

    let empty = SshTunnel::open(config(&host, port), "127.0.0.1".into(), 2222, UnknownHostKey::Learn).await;
    assert!(
        matches!(&empty, Err(SshError::Agent(message)) if message.contains("no keys")),
        "{:?}",
        empty.as_ref().err()
    );

    let added = Command::new("ssh-add")
        .arg(&key)
        .env("SSH_AUTH_SOCK", &socket)
        .status()
        .unwrap();
    assert!(added.success());
    let tunnel = SshTunnel::open(config(&host, port), "127.0.0.1".into(), 2222, UnknownHostKey::Learn).await;
    assert!(tunnel.is_ok(), "{:?}", tunnel.err());
}

#[tokio::test]
#[ignore = "requires docker, and waits out the keepalive window"]
async fn a_paused_bastion_is_reported_closed_through_keepalive_instead_of_hanging_forever() {
    let temp = tempfile::tempdir().unwrap();
    let key = temp.path().join("id_ed25519");
    let generated = Command::new("ssh-keygen")
        .args(["-q", "-t", "ed25519", "-N", "", "-f"])
        .arg(&key)
        .status()
        .unwrap();
    assert!(generated.success());
    let public = std::fs::read_to_string(key.with_extension("pub")).unwrap();

    let container = GenericImage::new("alpine", "3.22")
        .with_exposed_port(2222.tcp())
        .with_wait_for(WaitFor::message_on_stderr("Server listening on"))
        .with_env_var("AUTHORIZED_KEY", public.trim())
        .with_cmd(["sh", "-c", SSHD_SCRIPT])
        .start()
        .await
        .unwrap();
    let host = container.get_host().await.unwrap().to_string();
    let port = container.get_host_port_ipv4(2222).await.unwrap();

    let socket = temp.path().join("agent.sock");
    let _agent = start_agent(&socket);
    // SAFETY: this binary holds a single test, so nothing else reads the
    // environment while it changes. russh finds the agent through
    // SSH_AUTH_SOCK, and known_hosts is resolved from XDG_CONFIG_HOME.
    unsafe {
        std::env::set_var("SSH_AUTH_SOCK", &socket);
        std::env::set_var("XDG_CONFIG_HOME", temp.path());
    }
    let added = Command::new("ssh-add")
        .arg(&key)
        .env("SSH_AUTH_SOCK", &socket)
        .status()
        .unwrap();
    assert!(added.success());

    let tunnel = SshTunnel::open(config(&host, port), "127.0.0.1".into(), 2222, UnknownHostKey::Learn)
        .await
        .unwrap();
    assert!(!tunnel.is_closed(), "a freshly opened tunnel must not report closed");

    container.pause().await.unwrap();

    let detected = tokio::time::timeout(std::time::Duration::from_secs(90), async {
        while !tunnel.is_closed() {
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        }
    })
    .await;
    assert!(
        detected.is_ok(),
        "a paused (unresponsive) bastion must be detected as closed within the keepalive window \
         instead of leaving the tunnel looking alive until a database driver times out"
    );

    container.unpause().await.unwrap();
}

#[tokio::test]
#[ignore = "requires docker"]
async fn password_authentication_succeeds_with_the_correct_password() {
    let temp = tempfile::tempdir().unwrap();
    isolate_known_hosts(temp.path());
    let (_container, host, port) = start_password_sshd("").await;

    let tunnel = SshTunnel::open(
        password_config(&host, port, "s3cret"),
        "127.0.0.1".into(),
        2222,
        UnknownHostKey::Learn,
    )
    .await;
    assert!(tunnel.is_ok(), "{:?}", tunnel.err());
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_wrong_password_is_refused() {
    let temp = tempfile::tempdir().unwrap();
    isolate_known_hosts(temp.path());
    let (_container, host, port) = start_password_sshd("").await;

    let result = SshTunnel::open(
        password_config(&host, port, "not-the-password"),
        "127.0.0.1".into(),
        2222,
        UnknownHostKey::Learn,
    )
    .await;
    assert!(matches!(result, Err(SshError::Auth)), "{:?}", result.err());
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_key_not_in_authorized_keys_is_rejected() {
    let temp = tempfile::tempdir().unwrap();
    isolate_known_hosts(temp.path());
    let (_container, host, port) = start_password_sshd("").await;

    let key_path = temp.path().join("id_ed25519");
    let generated = Command::new("ssh-keygen")
        .args(["-q", "-t", "ed25519", "-N", "", "-f"])
        .arg(&key_path)
        .status()
        .unwrap();
    assert!(generated.success());

    let cfg = SshConfig {
        host,
        port,
        username: "deploy".into(),
        auth: SshAuth::PrivateKey {
            path: key_path,
            passphrase: None,
        },
    };
    let result = SshTunnel::open(cfg, "127.0.0.1".into(), 2222, UnknownHostKey::Learn).await;
    assert!(matches!(result, Err(SshError::Auth)), "{:?}", result.err());
}

#[tokio::test]
#[ignore = "requires docker"]
async fn an_encrypted_private_key_authenticates_with_its_passphrase() {
    let temp = tempfile::tempdir().unwrap();
    isolate_known_hosts(temp.path());

    let key_path = temp.path().join("id_ed25519");
    let generated = Command::new("ssh-keygen")
        .args(["-q", "-t", "ed25519", "-N", "correct horse battery staple", "-f"])
        .arg(&key_path)
        .status()
        .unwrap();
    assert!(generated.success());
    let public = std::fs::read_to_string(key_path.with_extension("pub")).unwrap();

    let (_container, host, port) = start_password_sshd(public.trim()).await;

    let cfg = SshConfig {
        host,
        port,
        username: "deploy".into(),
        auth: SshAuth::PrivateKey {
            path: key_path,
            passphrase: Some(SecretString::new("correct horse battery staple".to_string().into())),
        },
    };
    let tunnel = SshTunnel::open(cfg, "127.0.0.1".into(), 2222, UnknownHostKey::Learn).await;
    assert!(tunnel.is_ok(), "{:?}", tunnel.err());
}

async fn start_named_password_sshd(name: &str, network: &str) -> ContainerAsync<GenericImage> {
    GenericImage::new("alpine", "3.22")
        .with_wait_for(WaitFor::message_on_stderr("Server listening on"))
        .with_startup_timeout(std::time::Duration::from_secs(180))
        .with_env_var("AUTHORIZED_KEY", "")
        .with_cmd(["sh", "-c", PASSWORD_SSHD_SCRIPT])
        .with_network(network)
        .with_container_name(name)
        .start()
        .await
        .unwrap()
}

async fn start_first_hop_sshd(name: &str, network: &str) -> (ContainerAsync<GenericImage>, String, u16) {
    let container = GenericImage::new("alpine", "3.22")
        .with_exposed_port(2222.tcp())
        .with_wait_for(WaitFor::message_on_stderr("Server listening on"))
        .with_startup_timeout(std::time::Duration::from_secs(180))
        .with_env_var("AUTHORIZED_KEY", "")
        .with_cmd(["sh", "-c", PASSWORD_SSHD_SCRIPT])
        .with_network(network)
        .with_container_name(name)
        .start()
        .await
        .unwrap();
    let host = container.get_host().await.unwrap().to_string();
    let port = container.get_host_port_ipv4(2222).await.unwrap();
    (container, host, port)
}

#[tokio::test]
#[ignore = "requires docker"]
async fn declining_a_built_in_host_key_does_not_learn_it() {
    let temp = tempfile::tempdir().unwrap();
    isolate_known_hosts(temp.path());
    let key_path = temp.path().join("id_ed25519");
    let generated = Command::new("ssh-keygen")
        .args(["-q", "-t", "ed25519", "-N", "", "-f"])
        .arg(&key_path)
        .status()
        .unwrap();
    assert!(generated.success());
    let public = std::fs::read_to_string(key_path.with_extension("pub")).unwrap();
    let (_container, host, port) = start_password_sshd(public.trim()).await;
    let config = SshConfig {
        host,
        port,
        username: "deploy".into(),
        auth: SshAuth::PrivateKey {
            path: key_path,
            passphrase: None,
        },
    };
    let prompter = Arc::new(AnswerHostKeys {
        accept: false,
        calls: AtomicUsize::new(0),
    });
    let hops = [config];

    let result = SshTunnel::open_chain_prompted(
        &hops,
        "127.0.0.1".into(),
        2222,
        UnknownHostKey::Refuse,
        prompter.clone(),
    )
    .await;

    assert!(matches!(result, Err(SshError::UnknownHostKey { .. })));
    assert_eq!(prompter.calls.load(Ordering::SeqCst), 1);
    assert!(
        !tablepro_ssh::default_known_hosts_path().unwrap().exists(),
        "declining must leave the known_hosts file untouched"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_two_hop_chain_reaches_the_final_host() {
    let temp = tempfile::tempdir().unwrap();
    isolate_known_hosts(temp.path());
    let unique = unique_suffix();
    let network = format!("tablepro-ssh-chain-{unique}");
    let hop0_name = format!("tablepro-ssh-hop0-{unique}");
    let hop1_name = format!("tablepro-ssh-hop1-{unique}");

    let (_hop0, hop0_host, hop0_port) = start_first_hop_sshd(&hop0_name, &network).await;
    let hop1 = start_named_password_sshd(&hop1_name, &network).await;

    let hops = vec![
        password_config(&hop0_host, hop0_port, "s3cret"),
        password_config(&hop1_name, 2222, "s3cret"),
    ];

    let prompter = Arc::new(AnswerHostKeys {
        accept: true,
        calls: AtomicUsize::new(0),
    });
    let tunnel = SshTunnel::open_chain_prompted(
        &hops,
        "127.0.0.1".into(),
        2222,
        UnknownHostKey::Refuse,
        prompter.clone(),
    )
    .await
    .unwrap();
    assert_eq!(
        prompter.calls.load(Ordering::SeqCst),
        2,
        "each unknown hop needs explicit trust"
    );

    let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", tunnel.local_port()))
        .await
        .unwrap();
    let mut buf = [0u8; 4];
    stream.read_exact(&mut buf).await.unwrap();
    assert_eq!(
        &buf, b"SSH-",
        "the final hop's own sshd banner must arrive through both hops"
    );

    drop(hop1);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn cancelling_while_trusting_the_second_hop_does_not_learn_its_host_key() {
    let temp = tempfile::tempdir().unwrap();
    isolate_known_hosts(temp.path());
    let unique = unique_suffix();
    let network = format!("tablepro-ssh-chain-cancel-{unique}");
    let hop0_name = format!("tablepro-ssh-hop0-cancel-{unique}");
    let hop1_name = format!("tablepro-ssh-hop1-cancel-{unique}");

    let (_hop0, hop0_host, hop0_port) = start_first_hop_sshd(&hop0_name, &network).await;
    let _hop1 = start_named_password_sshd(&hop1_name, &network).await;
    let hops = vec![
        password_config(&hop0_host, hop0_port, "s3cret"),
        password_config(&hop1_name, 2222, "s3cret"),
    ];
    let prompter = Arc::new(AcceptFirstAndWaitOnSecondHostKey {
        calls: AtomicUsize::new(0),
        second_prompt: tokio::sync::Notify::new(),
    });
    let second_prompt = prompter.second_prompt.notified();
    tokio::pin!(second_prompt);
    let prompt_wait = tokio::time::timeout(std::time::Duration::from_secs(10), second_prompt.as_mut());
    let task_prompter = prompter.clone();
    let cancellation = tokio_util::sync::CancellationToken::new();
    let task_cancellation = cancellation.clone();
    let attempt = tokio::spawn(async move {
        tokio::select! {
            () = task_cancellation.cancelled() => false,
            result = SshTunnel::open_chain_prompted(
                &hops,
                "127.0.0.1".into(),
                2222,
                UnknownHostKey::Refuse,
                task_prompter,
            ) => result.is_ok(),
        }
    });

    prompt_wait.await.unwrap();
    cancellation.cancel();
    assert!(!attempt.await.unwrap(), "the cancelled chain must not connect");

    let known_hosts = tablepro_ssh::default_known_hosts_path().unwrap();
    let learned = std::fs::read_to_string(known_hosts).unwrap();
    assert_eq!(
        learned.lines().filter(|line| !line.trim().is_empty()).count(),
        1,
        "only the explicitly accepted first hop is trusted: {learned}"
    );
    assert!(learned.contains(&format!("[{hop0_host}]:{hop0_port}")));
    assert!(
        !learned.contains(&hop1_name),
        "cancelling the prompt must not trust hop two"
    );
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_changed_key_on_the_second_hop_is_reported_as_a_host_key_mismatch() {
    let temp = tempfile::tempdir().unwrap();
    isolate_known_hosts(temp.path());
    let unique = unique_suffix();
    let network = format!("tablepro-ssh-chain-mismatch-{unique}");
    let hop0_name = format!("tablepro-ssh-hop0-mismatch-{unique}");
    let hop1_name = format!("tablepro-ssh-hop1-mismatch-{unique}");

    let (_hop0, hop0_host, hop0_port) = start_first_hop_sshd(&hop0_name, &network).await;
    let hop1 = start_named_password_sshd(&hop1_name, &network).await;

    let hops = vec![
        password_config(&hop0_host, hop0_port, "s3cret"),
        password_config(&hop1_name, 2222, "s3cret"),
    ];

    let first = SshTunnel::open_chain(&hops, "127.0.0.1".into(), 2222, UnknownHostKey::Learn).await;
    assert!(first.is_ok(), "{:?}", first.err());
    drop(first);

    hop1.rm().await.unwrap();
    let _hop1_replacement = start_named_password_sshd(&hop1_name, &network).await;

    let second = SshTunnel::open_chain(&hops, "127.0.0.1".into(), 2222, UnknownHostKey::Learn).await;
    assert!(
        matches!(second, Err(SshError::HostKeyMismatch { .. })),
        "expected HostKeyMismatch for the replaced second hop, got {:?}",
        second.err()
    );
}
