#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
//! A refused port fails instantly and proves nothing about timeouts. These
//! tests use a listener that completes the TCP handshake and then never sends
//! the SSH banner, which is what a black-holed host or a hung bastion looks
//! like from the client side.

use std::path::PathBuf;
use std::time::Duration;

use tablepro_ssh::{SshAuth, SshConfig, SshError, SshTunnel};
use tokio::net::TcpListener;

async fn silent_listener() -> (u16, tokio::task::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind a silent listener");
    let port = listener.local_addr().expect("listener address").port();
    let accepting = tokio::spawn(async move {
        let mut held = Vec::new();
        while let Ok((stream, _)) = listener.accept().await {
            // Hold the connection open and never write a banner.
            held.push(stream);
        }
    });
    (port, accepting)
}

fn config(port: u16) -> SshConfig {
    SshConfig {
        host: "127.0.0.1".into(),
        port,
        username: "tunnel".into(),
        auth: SshAuth::PrivateKey {
            path: PathBuf::from("/nonexistent/id_ed25519"),
            passphrase: None,
        },
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_host_that_accepts_and_never_answers_times_out() {
    let config_dir = tempfile::TempDir::new().expect("temporary config directory");
    // SAFETY: the ssh crate resolves known_hosts from this variable and the
    // test process owns it for the lifetime of this test binary.
    unsafe { std::env::set_var("XDG_CONFIG_HOME", config_dir.path()) };

    let (port, accepting) = silent_listener().await;
    let started = std::time::Instant::now();
    let error = match SshTunnel::open(
        config(port),
        "db.example".into(),
        5432,
        tablepro_ssh::UnknownHostKey::Learn,
    )
    .await
    {
        Ok(_) => panic!("a silent server must not produce a usable tunnel"),
        Err(error) => error,
    };
    let elapsed = started.elapsed();
    accepting.abort();

    assert!(
        matches!(
            error,
            SshError::Timeout {
                stage: "ssh handshake",
                ..
            }
        ),
        "expected a handshake timeout, got {error}"
    );
    assert!(
        elapsed < Duration::from_secs(30),
        "the client waited {elapsed:?}, which is longer than the bounded handshake"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_timeout_names_the_host_it_could_not_reach() {
    let config_dir = tempfile::TempDir::new().expect("temporary config directory");
    // SAFETY: as above.
    unsafe { std::env::set_var("XDG_CONFIG_HOME", config_dir.path()) };

    let (port, accepting) = silent_listener().await;
    let error = match SshTunnel::open(
        config(port),
        "db.example".into(),
        5432,
        tablepro_ssh::UnknownHostKey::Learn,
    )
    .await
    {
        Ok(_) => panic!("a silent server must fail"),
        Err(error) => error,
    };
    accepting.abort();

    let text = error.to_string();
    assert!(text.contains("127.0.0.1"), "the error must name the host: {text}");
    assert!(text.contains(&port.to_string()), "the error must name the port: {text}");
}
