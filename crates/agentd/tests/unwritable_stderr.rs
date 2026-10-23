#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

#[test]
fn a_closed_stderr_does_not_turn_a_logged_startup_error_into_a_crash() {
    let (reader, writer) = std::io::pipe().unwrap();
    drop(reader);
    let missing_policy = tempfile::TempDir::new().unwrap().path().join("missing-policy.toml");

    let status = std::process::Command::new(env!("CARGO_BIN_EXE_tablepro-agentd"))
        .arg("--policy")
        .arg(&missing_policy)
        .env("RUST_LOG", "info")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::from(writer))
        .status()
        .unwrap();

    assert_eq!(status.code(), Some(2), "agentd ended with {status}");
}
