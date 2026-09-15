#![expect(
    clippy::print_stderr,
    reason = "a harness-free test binary reports its own failures on stderr"
)]

use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Output, Stdio};

fn main() -> ExitCode {
    let Ok(schemas) = compiled_schema_dir() else {
        return ExitCode::FAILURE;
    };
    if help_lists_the_gapplication_options(&schemas).is_err() {
        return ExitCode::FAILURE;
    }
    if a_missing_schema_is_reported().is_err() {
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

fn tablepro() -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_tablepro"));
    command
        .env("LC_ALL", "C.UTF-8")
        .env("GSETTINGS_BACKEND", "memory")
        .env_remove("LANGUAGE")
        .stdin(Stdio::null());
    command
}

fn run(command: &mut Command, what: &str) -> Result<Output, ()> {
    command
        .output()
        .map_err(|error| eprintln!("could not run tablepro for {what}: {error}"))
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
fn help_lists_the_gapplication_options(schemas: &Path) -> Result<(), ()> {
    let output = run(tablepro().arg("--help").env("GSETTINGS_SCHEMA_DIR", schemas), "--help")?;

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
fn a_missing_schema_is_reported() -> Result<(), ()> {
    let empty = target_tmp("no-schemas");
    std::fs::create_dir_all(&empty).map_err(|error| eprintln!("could not create {}: {error}", empty.display()))?;

    let output = run(
        tablepro()
            .env("GSETTINGS_SCHEMA_DIR", &empty)
            .env("XDG_DATA_DIRS", &empty),
        "a missing schema",
    )?;

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
