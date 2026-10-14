#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::process::Command;

const CHILD_PROCESS: &str = "TABLEPRO_PANIC_HOOK_TEST_CHILD";
const PANIC_SENTINEL: &str = "panic-payload-secret-sentinel";

#[test]
fn debug_panic_hook_withholds_payload_and_keeps_diagnostics() {
    if std::env::var_os(CHILD_PROCESS).is_some() {
        tracing_subscriber::fmt()
            .with_writer(std::io::stderr)
            .try_init()
            .expect("install the test log subscriber");
        tablepro_policy::withhold_panic_messages();
        panic!("{PANIC_SENTINEL}");
    }

    assert_diagnostics(run_child(true, false));
    assert_diagnostics(run_child(false, true));
}

fn run_child(debug_panics: bool, rust_backtrace: bool) -> std::process::Output {
    let mut command = Command::new(std::env::current_exe().expect("test executable path"));
    command
        .args([
            "--exact",
            "debug_panic_hook_withholds_payload_and_keeps_diagnostics",
            "--nocapture",
        ])
        .env(CHILD_PROCESS, "1");
    if debug_panics {
        command.env("TABLEPRO_DEBUG_PANICS", "1");
    } else {
        command.env_remove("TABLEPRO_DEBUG_PANICS");
    }
    if rust_backtrace {
        command.env("RUST_BACKTRACE", "1");
    } else {
        command.env_remove("RUST_BACKTRACE");
    }
    command.output().expect("run the isolated panic hook process")
}

fn assert_diagnostics(output: std::process::Output) {
    let stderr = String::from_utf8_lossy(&output.stderr);

    assert!(!output.status.success(), "the child panic must fail its test");
    assert!(
        !stderr.contains(PANIC_SENTINEL),
        "panic payload leaked to stderr: {stderr}"
    );
    assert!(
        stderr.contains("a panic occurred at"),
        "panic location missing: {stderr}"
    );
    assert!(stderr.contains("backtrace"), "backtrace missing: {stderr}");
}
