#![expect(
    clippy::print_stderr,
    reason = "a harness-free test binary reports its own failures on stderr"
)]

use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};

const CHILD_MARKER: &str = "TABLEPRO_I18N_CATALOG_CHILD";
const LOCALE: &str = "en_US.UTF-8";

fn main() -> ExitCode {
    if std::env::var_os(CHILD_MARKER).is_some() {
        return child();
    }
    parent()
}

/// glibc never loads a catalogue under the C locale, so the assertions
/// have to run in a process started with a real one. The parent compiles
/// the fixture and re-executes itself under `en_US.UTF-8`.
fn parent() -> ExitCode {
    let Ok(locale_dir) = compile_catalog() else {
        return ExitCode::FAILURE;
    };
    let output = Command::new(std::env::args_os().next().unwrap_or_default())
        .env(CHILD_MARKER, "1")
        .env("TABLEPRO_TEST_LOCALEDIR", &locale_dir)
        .env("LC_ALL", LOCALE)
        .env("LANG", LOCALE)
        .env_remove("LANGUAGE")
        .stdin(Stdio::null())
        .output();
    let output = match output {
        Ok(output) => output,
        Err(error) => {
            eprintln!("could not re-execute the catalogue test: {error}");
            return ExitCode::FAILURE;
        }
    };
    if !output.status.success() {
        eprintln!(
            "the catalogue child exited with {}:\n{}{}",
            output.status,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

fn compile_catalog() -> Result<PathBuf, ()> {
    let root = Path::new(env!("CARGO_TARGET_TMPDIR")).join("locale");
    let messages = root.join("en_US").join("LC_MESSAGES");
    std::fs::create_dir_all(&messages)
        .map_err(|error| eprintln!("could not create {}: {error}", messages.display()))?;
    let po = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("i18n")
        .join("en_US.po");
    let output = Command::new("msgfmt")
        .arg("--check")
        .arg("-o")
        .arg(messages.join("tablepro.mo"))
        .arg(&po)
        .output()
        .map_err(|error| eprintln!("could not run msgfmt: {error}"))?;
    if !output.status.success() {
        eprintln!("msgfmt failed: {}", String::from_utf8_lossy(&output.stderr));
        return Err(());
    }
    Ok(root)
}

fn child() -> ExitCode {
    let Some(locale_dir) = std::env::var_os("TABLEPRO_TEST_LOCALEDIR") else {
        eprintln!("the child was started without TABLEPRO_TEST_LOCALEDIR");
        return ExitCode::FAILURE;
    };

    // SAFETY: this process has spawned no threads yet.
    let selected = unsafe { gettextrs::setlocale(gettextrs::LocaleCategory::LcAll, LOCALE) };
    if selected.is_none() {
        eprintln!("{LOCALE} is not generated on this system; install it and re-run");
        return ExitCode::FAILURE;
    }
    if let Err(error) = gettextrs::bindtextdomain("tablepro", &locale_dir) {
        eprintln!("bindtextdomain failed: {error}");
        return ExitCode::FAILURE;
    }
    if let Err(error) = gettextrs::bind_textdomain_codeset("tablepro", "UTF-8") {
        eprintln!("bind_textdomain_codeset failed: {error}");
        return ExitCode::FAILURE;
    }
    if let Err(error) = gettextrs::textdomain("tablepro") {
        eprintln!("textdomain failed: {error}");
        return ExitCode::FAILURE;
    }

    let mut failures = Vec::new();
    let mut check = |what: &str, got: String, want: &str| {
        if got != want {
            failures.push(format!("{what}: got {got:?}, want {want:?}"));
        }
    };

    check(
        "gettext_f reorders placeholders",
        tablepro_app::i18n::gettext_f("{table} in {schema}", &[("table", "users"), ("schema", "public")]),
        "public owns users",
    );
    check(
        "ngettext_f singular",
        tablepro_app::i18n::ngettext_f("{n} row", "{n} rows", 1, &[("n", "1")]),
        "exactly 1 row",
    );
    check(
        "ngettext_f plural",
        tablepro_app::i18n::ngettext_f("{n} row", "{n} rows", 7, &[("n", "7")]),
        "all 7 rows",
    );
    check(
        "pgettext context",
        tablepro_app::i18n::pgettext("filter operator", "all"),
        "every rule",
    );
    check(
        "pgettext_f context with placeholders",
        tablepro_app::i18n::pgettext_f("filter operator", "{n} match", &[("n", "3")]),
        "3 hit",
    );
    check(
        "npgettext plural with context",
        tablepro_app::i18n::npgettext("filter operator", "{n} match", "{n} matches", 3),
        "{n} hits",
    );
    check(
        "an untranslated id falls through unchanged",
        tablepro_app::i18n::gettext("Not in the catalogue"),
        "Not in the catalogue",
    );

    if failures.is_empty() {
        return ExitCode::SUCCESS;
    }
    for failure in failures {
        eprintln!("{failure}");
    }
    ExitCode::FAILURE
}
