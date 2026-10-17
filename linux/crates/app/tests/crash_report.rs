//! A panic in a GTK callback cannot unwind through C, so it ends the
//! process. The hook has to leave a report behind that the next launch
//! finds, and the default output on stderr has to stay.
//!
//! A panic hook is process-wide and the crash ends the process, so each
//! case runs in a child of its own.

#![expect(
    clippy::print_stderr,
    reason = "a harness-free test binary reports its own failures on stderr"
)]

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Output, Stdio};

const CHILD_DIR: &str = "TABLEPRO_CRASH_REPORT_DIR";
const CHILD_OFF_THREAD: &str = "TABLEPRO_CRASH_REPORT_OFF_THREAD";
const PROBE: &str = "the crash report probe";

fn main() -> ExitCode {
    match std::env::var_os(CHILD_DIR) {
        Some(dir) => child(PathBuf::from(dir)),
        None => parent(),
    }
}

#[expect(clippy::panic, reason = "the panic is what the case is about")]
fn child(dir: PathBuf) -> ExitCode {
    tablepro_app::crash_report::install(dir);
    if std::env::var_os(CHILD_OFF_THREAD).is_some() {
        // A runtime thread's panic is caught where it happens and ends
        // a task, not the app.
        let worker = std::thread::Builder::new()
            .name("tokio-runtime-worker".to_owned())
            .spawn(|| panic!("{PROBE}"));
        if let Ok(worker) = worker {
            let _ = worker.join();
        }
        return ExitCode::SUCCESS;
    }
    glib::idle_add_local_once(|| panic!("{PROBE}"));
    glib::MainLoop::new(None, false).run();
    ExitCode::SUCCESS
}

fn parent() -> ExitCode {
    let Ok(root) = tempfile::tempdir() else {
        eprintln!("no temporary directory");
        return ExitCode::FAILURE;
    };
    let crashes = root.path().join("crashes");
    match crash_leaves_one_private_report(root.path(), &crashes) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}

fn crash_leaves_one_private_report(root: &Path, crashes: &Path) -> Result<(), String> {
    let caught = run_child(root, crashes, true)?;
    if !caught.status.success() || crashes.exists() {
        return Err(format!(
            "a panic off the GTK thread was taken for a crash ({}):\n{}",
            caught.status,
            String::from_utf8_lossy(&caught.stderr)
        ));
    }

    let crashed = run_child(root, crashes, false)?;
    let stderr = String::from_utf8_lossy(&crashed.stderr);
    if crashed.status.success() {
        return Err(format!("a panic in a GTK callback did not end the process:\n{stderr}"));
    }
    if !stderr.contains(PROBE) {
        return Err(format!(
            "the default hook no longer writes the panic to stderr:\n{stderr}"
        ));
    }

    let reports = reports_in(crashes)?;
    let [report] = reports.as_slice() else {
        return Err(format!("expected one report, found {reports:?}"));
    };
    let mode = |path: &Path| std::fs::metadata(path).map(|metadata| metadata.permissions().mode() & 0o777);
    if mode(crashes).ok() != Some(0o700) || mode(report).ok() != Some(0o600) {
        return Err(format!(
            "the report is not private: directory {:?}, file {:?}",
            mode(crashes).ok(),
            mode(report).ok()
        ));
    }
    let text = std::fs::read_to_string(report).map_err(|error| format!("could not read the report: {error}"))?;
    for needle in [
        format!("TablePro {}", tablepro_app::config::VERSION),
        format!("Profile: {}", tablepro_app::config::PROFILE),
        PROBE.to_owned(),
        "Backtrace:\n".to_owned(),
    ] {
        if !text.contains(&needle) {
            return Err(format!("the report is missing {needle:?}:\n{text}"));
        }
    }

    let announced = tablepro_app::crash_report::take_unannounced(crashes).map_err(|error| error.to_string())?;
    if announced.as_ref() != Some(report) {
        return Err(format!("the next launch found {announced:?}, not {}", report.display()));
    }
    let again = tablepro_app::crash_report::take_unannounced(crashes).map_err(|error| error.to_string())?;
    if again.is_some() {
        return Err("the same crash was announced twice".to_owned());
    }
    Ok(())
}

fn run_child(root: &Path, crashes: &Path, off_thread: bool) -> Result<Output, String> {
    let mut command = Command::new(std::env::args_os().next().unwrap_or_default());
    command
        .env(CHILD_DIR, crashes)
        .env_remove("RUST_BACKTRACE")
        // An abort can leave a core file in the working directory.
        .current_dir(root)
        .stdin(Stdio::null());
    if off_thread {
        command.env(CHILD_OFF_THREAD, "1");
    }
    command
        .output()
        .map_err(|error| format!("could not run the child: {error}"))
}

fn reports_in(dir: &Path) -> Result<Vec<PathBuf>, String> {
    let entries = std::fs::read_dir(dir).map_err(|error| format!("no crash directory: {error}"))?;
    Ok(entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .is_some_and(|name| name.to_string_lossy().starts_with("crash-"))
        })
        .collect())
}
