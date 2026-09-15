#![expect(
    clippy::print_stderr,
    reason = "a harness-free test binary reports its own failures on stderr"
)]

use std::process::{Command, ExitCode, Stdio};

/// `--help-gapplication` appears only once GApplication has parsed the
/// command line, which happens after `run()` registered the embedded
/// GResource. A missing or malformed gresource aborts before that.
fn main() -> ExitCode {
    let output = Command::new(env!("CARGO_BIN_EXE_tablepro"))
        .arg("--help")
        .env("LC_ALL", "C.UTF-8")
        .env_remove("LANGUAGE")
        .stdin(Stdio::null())
        .output();

    let output = match output {
        Ok(output) => output,
        Err(error) => {
            eprintln!("could not run the tablepro binary: {error}");
            return ExitCode::FAILURE;
        }
    };

    let stdout = String::from_utf8_lossy(&output.stdout);
    if !output.status.success() {
        eprintln!(
            "tablepro --help exited with {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        );
        return ExitCode::FAILURE;
    }
    if !stdout.contains("--help-gapplication") {
        eprintln!("tablepro --help did not list the GApplication options:\n{stdout}");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}
