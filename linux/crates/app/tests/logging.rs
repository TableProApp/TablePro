#![expect(
    clippy::print_stderr,
    reason = "a harness-free test binary reports its own failures on stderr"
)]

use std::process::{Command, ExitCode, Stdio};

const CHILD_MARKER: &str = "TABLEPRO_LOGGING_CHILD";
const TRACE_PROBE: &str = "probe-at-trace";
const DEBUG_PROBE: &str = "probe-at-debug";
const INFO_PROBE: &str = "probe-at-info";

fn main() -> ExitCode {
    if std::env::var_os(CHILD_MARKER).is_some() {
        return child();
    }
    parent()
}

/// A subscriber installs once per process, so each case runs in its own
/// child with its own `RUST_LOG`.
fn parent() -> ExitCode {
    let cases = [
        ("trace", "trace", "", vec![TRACE_PROBE, DEBUG_PROBE, INFO_PROBE], vec![]),
        (
            "an unparsable filter",
            "this is not a filter=??",
            "",
            vec![INFO_PROBE, "RUST_LOG could not be parsed"],
            vec![DEBUG_PROBE],
        ),
        (
            "a format naming nothing known",
            "info",
            "yaml",
            vec![INFO_PROBE, "TABLEPRO_LOG_FORMAT names no known format"],
            // The fallback is text, so the line is not an object.
            vec!["\"fields\""],
        ),
    ];

    for (what, filter, format, expected, forbidden) in cases {
        let Ok(stderr) = run_child(filter, format, what) else {
            return ExitCode::FAILURE;
        };
        for needle in expected {
            if !stderr.contains(needle) {
                eprintln!("with RUST_LOG={what}, stderr is missing {needle:?}:\n{stderr}");
                return ExitCode::FAILURE;
            }
        }
        for needle in forbidden {
            if stderr.contains(needle) {
                eprintln!("with RUST_LOG={what}, stderr should not contain {needle:?}:\n{stderr}");
                return ExitCode::FAILURE;
            }
        }
    }
    json_lines_are_objects()
}

/// Every line a shipper reads has to parse on its own, so the case
/// checks the shape rather than a substring: one object per line, the
/// message in a field.
fn json_lines_are_objects() -> ExitCode {
    let Ok(stderr) = run_child("info", "json", "json") else {
        return ExitCode::FAILURE;
    };
    let mut saw_probe = false;
    for line in stderr.lines().filter(|line| !line.trim().is_empty()) {
        if !(line.starts_with('{') && line.ends_with('}')) {
            eprintln!("a json line is not an object:\n{line}");
            return ExitCode::FAILURE;
        }
        for key in ["\"timestamp\"", "\"level\"", "\"fields\""] {
            if !line.contains(key) {
                eprintln!("a json line is missing {key}:\n{line}");
                return ExitCode::FAILURE;
            }
        }
        saw_probe |= line.contains(INFO_PROBE);
    }
    if !saw_probe {
        eprintln!("the json output never carried {INFO_PROBE}:\n{stderr}");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

fn run_child(filter: &str, format: &str, what: &str) -> Result<String, ()> {
    let output = Command::new(std::env::args_os().next().unwrap_or_default())
        .env(CHILD_MARKER, "1")
        .env("RUST_LOG", filter)
        .env("TABLEPRO_LOG_FORMAT", format)
        .stdin(Stdio::null())
        .output()
        .map_err(|error| eprintln!("could not run the {what} case: {error}"))?;
    if !output.status.success() {
        eprintln!(
            "the {what} case exited with {}:\n{}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        );
        return Err(());
    }
    // Nothing may reach stdout: the journal reads stderr.
    let stdout = String::from_utf8_lossy(&output.stdout);
    if !stdout.trim().is_empty() {
        eprintln!("the {what} case wrote to stdout:\n{stdout}");
        return Err(());
    }
    Ok(String::from_utf8_lossy(&output.stderr).into_owned())
}

fn child() -> ExitCode {
    if let Err(error) = tablepro_app::logging::init(tablepro_app::config::Profile::Default) {
        eprintln!("logging::init failed: {error}");
        return ExitCode::FAILURE;
    }
    tracing::trace!("{TRACE_PROBE}");
    tracing::debug!("{DEBUG_PROBE}");
    tracing::info!("{INFO_PROBE}");
    ExitCode::SUCCESS
}
