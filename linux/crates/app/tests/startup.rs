#![expect(
    clippy::print_stderr,
    reason = "a harness-free test binary reports its own failures on stderr"
)]

use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitCode, Output, Stdio};
use std::time::{Duration, Instant};

/// A run that has not finished by now is a run that never will: every
/// case here exits on its own within milliseconds. Without this, a
/// case that wrongly opens a window waits for a user who is not
/// there, and the suite hangs instead of failing.
const RUN_LIMIT: Duration = Duration::from_secs(30);

fn main() -> ExitCode {
    let (Ok(schemas), Ok(empty)) = (compiled_schema_dir(), empty_dir()) else {
        return ExitCode::FAILURE;
    };
    if help_lists_the_gapplication_options(&schemas, &empty).is_err() {
        return ExitCode::FAILURE;
    }
    if a_missing_schema_is_reported(&empty).is_err() {
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

fn target_tmp(name: &str) -> PathBuf {
    Path::new(env!("CARGO_TARGET_TMPDIR")).join(name)
}

/// The binary opens its settings during startup, so every case needs the
/// schema somewhere GIO can find it. Meson installs it; here the test
/// compiles it next to the test binary.
fn compiled_schema_dir() -> Result<PathBuf, ()> {
    let dir = target_tmp("schemas");
    let source = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../data")
        .join("app.tablepro.TablePro.gschema.xml");
    std::fs::create_dir_all(&dir)
        .and_then(|()| std::fs::copy(&source, dir.join("app.tablepro.TablePro.gschema.xml")).map(|_| ()))
        .map_err(|error| eprintln!("could not stage the schema in {}: {error}", dir.display()))?;
    let output = Command::new("glib-compile-schemas")
        .arg(&dir)
        .output()
        .map_err(|error| eprintln!("could not run glib-compile-schemas: {error}"))?;
    if !output.status.success() {
        eprintln!(
            "glib-compile-schemas failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        return Err(());
    }
    Ok(dir)
}

/// The binary under an environment that carries nothing in from the
/// machine running the test.
///
/// GLib looks for a schema in `GSETTINGS_SCHEMA_DIR`, then in
/// `XDG_DATA_HOME`, then across `XDG_DATA_DIRS`. A developer who
/// installed the schema into their own data directory, which is how
/// the app runs without meson, would otherwise have it found through
/// the second of those, and the case that asks what happens when no
/// schema is installed would be answered by their machine instead of
/// by the code.
fn tablepro(empty: &Path) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_tablepro"));
    command
        .env("LC_ALL", "C.UTF-8")
        .env("GSETTINGS_BACKEND", "memory")
        .env("XDG_DATA_HOME", empty)
        .env("XDG_DATA_DIRS", empty)
        .env_remove("LANGUAGE")
        .stdin(Stdio::null());
    command
}

/// A directory that exists and stays empty, so a lookup through it
/// finds nothing rather than failing for want of the directory.
fn empty_dir() -> Result<PathBuf, ()> {
    let dir = target_tmp("no-schemas");
    std::fs::create_dir_all(&dir).map_err(|error| eprintln!("could not create {}: {error}", dir.display()))?;
    Ok(dir)
}

fn run(command: &mut Command, what: &str) -> Result<Output, ()> {
    let child = command
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| eprintln!("could not run tablepro for {what}: {error}"))?;
    wait_with_limit(child, what)
}

fn wait_with_limit(mut child: Child, what: &str) -> Result<Output, ()> {
    let deadline = Instant::now() + RUN_LIMIT;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) => {}
            Err(error) => {
                eprintln!("could not wait for tablepro during {what}: {error}");
                return Err(());
            }
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            eprintln!("tablepro did not exit within {RUN_LIMIT:?} during {what}");
            return Err(());
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    child
        .wait_with_output()
        .map_err(|error| eprintln!("could not read tablepro output for {what}: {error}"))
}

fn combined(output: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

/// `--help-gapplication` appears only once GApplication has parsed the
/// command line, which happens after `run()` registered the embedded
/// GResource. A missing or malformed gresource aborts before that.
fn help_lists_the_gapplication_options(schemas: &Path, empty: &Path) -> Result<(), ()> {
    let output = run(
        tablepro(empty).arg("--help").env("GSETTINGS_SCHEMA_DIR", schemas),
        "--help",
    )?;

    if !output.status.success() {
        eprintln!("tablepro --help exited with {}:\n{}", output.status, combined(&output));
        return Err(());
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    if !stdout.contains("--help-gapplication") {
        eprintln!("tablepro --help did not list the GApplication options:\n{stdout}");
        return Err(());
    }
    Ok(())
}

/// Without the schema installed the app must name what is missing and
/// exit, not abort inside GIO with nothing to go on.
fn a_missing_schema_is_reported(empty: &Path) -> Result<(), ()> {
    let output = run(tablepro(empty).env("GSETTINGS_SCHEMA_DIR", empty), "a missing schema")?;

    if output.status.success() {
        eprintln!("tablepro started with no settings schema installed");
        return Err(());
    }
    let reported = combined(&output);
    if !reported.contains("app.tablepro.TablePro") {
        eprintln!("the startup failure did not name the schema:\n{reported}");
        return Err(());
    }
    Ok(())
}
